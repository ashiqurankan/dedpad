import SwiftUI
import AuthenticationServices
import CryptoKit
import Security

/// Google OAuth settings. The iOS client ID comes from the bundled `google.json`
/// (written by `scripts/configure-google.sh`, never committed) or from Settings.
struct GoogleConfig: Codable, Equatable {
    /// OAuth client ID of type "iOS" from Google Cloud Console (…apps.googleusercontent.com).
    var iosClientId: String = ""

    var isComplete: Bool { iosClientId.hasSuffix(".apps.googleusercontent.com") }

    /// Custom URL scheme Google redirects to (the reversed client ID).
    var redirectScheme: String {
        iosClientId.split(separator: ".").reversed().joined(separator: ".")
    }

    private static let overrideKey = "googleConfig.override"

    static func load() -> GoogleConfig {
        if let data = UserDefaults.standard.data(forKey: overrideKey),
           let c = try? JSONDecoder().decode(GoogleConfig.self, from: data), c.isComplete {
            return c
        }
        if let url = Bundle.main.url(forResource: "google", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let c = try? JSONDecoder().decode(GoogleConfig.self, from: data) {
            return c
        }
        return GoogleConfig()
    }

    func saveOverride() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: Self.overrideKey) }
    }
}

struct GoogleAccount: Codable, Equatable {
    var email: String
    var name: String
}

enum BackupError: LocalizedError {
    case notConfigured
    case signedOut
    case http(Int, String)
    case badResponse(String)
    case offline

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "Google Drive backup isn't set up in this build."
        case .signedOut: return "Sign in with Google to back up."
        case let .http(code, msg): return "Google Drive said \(code): \(msg)"
        case let .badResponse(m): return "Unexpected reply from Google (\(m))."
        case .offline: return "Waiting for a connection."
        }
    }
}

/// Google sign-in with PKCE (no SDK), asking only for access to files dedpad creates in Drive.
/// The refresh token is kept in the Keychain on this device.
@MainActor
final class GoogleAuth: NSObject, ObservableObject, ASWebAuthenticationPresentationContextProviding {
    @Published private(set) var account: GoogleAccount?
    @Published private(set) var config = GoogleConfig.load()

    /// Only files dedpad creates — it can never see anything else in the user's Drive.
    static let scopes = "openid email profile https://www.googleapis.com/auth/drive.file"

    private var accessToken: String?
    private var expiry = Date.distantPast
    private var session: ASWebAuthenticationSession?
    private var refreshing: Task<String, Error>?

    private static let keychainService = "dedpad.google"
    private static let accountKey = "google.account"

    override init() {
        super.init()
        if let data = UserDefaults.standard.data(forKey: Self.accountKey),
           let a = try? JSONDecoder().decode(GoogleAccount.self, from: data),
           Keychain.read(service: Self.keychainService, account: "refreshToken") != nil {
            account = a
        }
    }

    func updateConfig(_ c: GoogleConfig) {
        c.saveOverride()
        config = c
    }

    // MARK: Sign in

    func signIn() async throws {
        guard config.isComplete else { throw BackupError.notConfigured }
        let verifier = Self.randomString(64)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URL
        let redirect = "\(config.redirectScheme):/oauth2redirect"
        var c = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        c.queryItems = [
            .init(name: "client_id", value: config.iosClientId),
            .init(name: "redirect_uri", value: redirect),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: Self.scopes),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "prompt", value: "select_account consent"),
        ]
        let callback = try await authenticate(url: c.url!, scheme: config.redirectScheme)
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        if let err = items.first(where: { $0.name == "error" })?.value { throw BackupError.badResponse(err) }
        guard let code = items.first(where: { $0.name == "code" })?.value else {
            throw BackupError.badResponse("no authorisation code")
        }

        let json = try await Self.postForm("https://oauth2.googleapis.com/token", [
            "code": code, "client_id": config.iosClientId, "redirect_uri": redirect,
            "grant_type": "authorization_code", "code_verifier": verifier,
        ])
        guard let token = json["access_token"] as? String else { throw BackupError.badResponse("no access token") }
        guard let refresh = json["refresh_token"] as? String else { throw BackupError.badResponse("no refresh token") }
        let granted = (json["scope"] as? String) ?? ""
        guard granted.contains("drive.file") else {
            throw BackupError.badResponse("Google Drive access wasn't allowed. Sign in again and tick the Drive box.")
        }
        accessToken = token
        expiry = Date().addingTimeInterval(Self.seconds(json["expires_in"]) - 120)
        Keychain.write(refresh, service: Self.keychainService, account: "refreshToken")

        let claims = (json["id_token"] as? String).flatMap(Self.jwtClaims) ?? [:]
        let a = GoogleAccount(email: claims["email"] as? String ?? "", name: claims["name"] as? String ?? "")
        account = a
        if let data = try? JSONEncoder().encode(a) { UserDefaults.standard.set(data, forKey: Self.accountKey) }
    }

    func signOut() {
        if let refresh = Keychain.read(service: Self.keychainService, account: "refreshToken") {
            Task { _ = try? await Self.postForm("https://oauth2.googleapis.com/revoke", ["token": refresh]) }
        }
        Keychain.delete(service: Self.keychainService, account: "refreshToken")
        UserDefaults.standard.removeObject(forKey: Self.accountKey)
        accessToken = nil
        account = nil
    }

    /// A valid access token, refreshed when needed.
    func token(forceRefresh: Bool = false) async throws -> String {
        if !forceRefresh, let accessToken, Date() < expiry { return accessToken }
        if let refreshing { return try await refreshing.value }
        let task = Task<String, Error> { @MainActor in
            defer { self.refreshing = nil }
            guard self.config.isComplete else { throw BackupError.notConfigured }
            guard let refresh = Keychain.read(service: Self.keychainService, account: "refreshToken") else {
                throw BackupError.signedOut
            }
            let json: [String: Any]
            do {
                json = try await Self.postForm("https://oauth2.googleapis.com/token", [
                    "grant_type": "refresh_token", "refresh_token": refresh, "client_id": self.config.iosClientId,
                ])
            } catch BackupError.http(400, _), BackupError.http(401, _) {
                // The grant was revoked or expired.
                self.signOut()
                throw BackupError.signedOut
            }
            guard let t = json["access_token"] as? String else { throw BackupError.signedOut }
            self.accessToken = t
            self.expiry = Date().addingTimeInterval(Self.seconds(json["expires_in"]) - 120)
            return t
        }
        refreshing = task
        return try await task.value
    }

    // MARK: Helpers

    private func authenticate(url: URL, scheme: String) async throws -> URL {
        try await withCheckedThrowingContinuation { cont in
            let s = ASWebAuthenticationSession(url: url, callbackURLScheme: scheme) { callback, error in
                if let callback { cont.resume(returning: callback) } else { cont.resume(throwing: error ?? BackupError.signedOut) }
            }
            s.presentationContextProvider = self
            s.prefersEphemeralWebBrowserSession = false
            session = s
            s.start()
        }
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first ?? ASPresentationAnchor()
        }
    }

    private static func seconds(_ v: Any?) -> Double {
        if let n = v as? Double { return n }
        if let n = v as? Int { return Double(n) }
        if let s = v as? String, let n = Double(s) { return n }
        return 3600
    }

    /// Reads the (unverified) claims of an ID token — only used to show who is signed in.
    private static func jwtClaims(_ jwt: String) -> [String: Any]? {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var s = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s += "=" }
        guard let data = Data(base64Encoded: s) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func randomString(_ n: Int) -> String {
        let chars = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        return String((0..<n).map { _ in chars.randomElement()! })
    }

    static func postForm(_ url: String, _ form: [String: String]) async throws -> [String: Any] {
        var req = URLRequest(url: URL(string: url)!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        req.httpBody = form.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }
            .joined(separator: "&").data(using: .utf8)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            let msg = (json["error_description"] as? String) ?? (json["error"] as? String) ?? "error"
            throw BackupError.http(code, msg)
        }
        return json
    }
}

extension Data {
    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// Minimal Keychain wrapper (generic passwords, this device only).
enum Keychain {
    static func write(_ value: String, service: String, account: String) {
        delete(service: service, account: account)
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        SecItemAdd(q as CFDictionary, nil)
    }

    static func read(service: String, account: String) -> String? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(service: String, account: String) {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(q as CFDictionary)
    }
}
