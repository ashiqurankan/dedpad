import Foundation

/// A file or folder in Google Drive (only the fields dedpad asks for).
struct DriveFile: Decodable {
    var id: String
    var name: String
    var mimeType: String?
    var modifiedTime: String?
    var size: String?
    var appProperties: [String: String]?

    var modified: Date? {
        guard let modifiedTime else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: modifiedTime) ?? ISO8601DateFormatter().date(from: modifiedTime)
    }
}

/// Google Drive v3 over REST. With the drive.file scope it only ever sees files dedpad created.
struct DriveClient {
    static let folderType = "application/vnd.google-apps.folder"
    private static let api = "https://www.googleapis.com/drive/v3"
    private static let upload = "https://www.googleapis.com/upload/drive/v3"
    private static let fields = "id,name,mimeType,modifiedTime,size,appProperties"

    /// Supplies an access token; `true` asks for a fresh one after a 401.
    let token: (Bool) async throws -> String

    // MARK: Queries

    func list(query: String) async throws -> [DriveFile] {
        var out: [DriveFile] = []
        var pageToken: String?
        repeat {
            var c = URLComponents(string: "\(Self.api)/files")!
            c.queryItems = [
                .init(name: "q", value: query),
                .init(name: "fields", value: "nextPageToken,files(\(Self.fields))"),
                .init(name: "pageSize", value: "1000"),
                .init(name: "spaces", value: "drive"),
            ]
            if let pageToken { c.queryItems?.append(.init(name: "pageToken", value: pageToken)) }
            let (data, _) = try await send { var r = URLRequest(url: c.url!); r.httpMethod = "GET"; return r }
            struct Page: Decodable { var files: [DriveFile]; var nextPageToken: String? }
            let page = try JSONDecoder().decode(Page.self, from: data)
            out += page.files
            pageToken = page.nextPageToken
        } while pageToken != nil
        return out
    }

    func children(of folder: String, foldersOnly: Bool = false) async throws -> [DriveFile] {
        var q = "'\(folder)' in parents and trashed = false"
        if foldersOnly { q += " and mimeType = '\(Self.folderType)'" }
        return try await list(query: q)
    }

    func file(_ id: String) async throws -> DriveFile? {
        var c = URLComponents(string: "\(Self.api)/files/\(id)")!
        c.queryItems = [.init(name: "fields", value: Self.fields + ",trashed")]
        do {
            let (data, _) = try await send { URLRequest(url: c.url!) }
            struct F: Decodable { var trashed: Bool? }
            if (try? JSONDecoder().decode(F.self, from: data))?.trashed == true { return nil }
            return try JSONDecoder().decode(DriveFile.self, from: data)
        } catch BackupError.http(404, _) {
            return nil
        }
    }

    // MARK: Changes

    func createFolder(name: String, parent: String?, appProperties: [String: String] = [:]) async throws -> DriveFile {
        var meta: [String: Any] = ["name": name, "mimeType": Self.folderType, "appProperties": appProperties]
        if let parent { meta["parents"] = [parent] }
        let body = try JSONSerialization.data(withJSONObject: meta)
        let (data, _) = try await send {
            var r = URLRequest(url: URL(string: "\(Self.api)/files?fields=\(Self.fields)")!)
            r.httpMethod = "POST"
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.httpBody = body
            return r
        }
        return try JSONDecoder().decode(DriveFile.self, from: data)
    }

    func updateMetadata(_ id: String, name: String? = nil, appProperties: [String: String]? = nil) async throws {
        var meta: [String: Any] = [:]
        if let name { meta["name"] = name }
        if let appProperties { meta["appProperties"] = appProperties }
        let body = try JSONSerialization.data(withJSONObject: meta)
        _ = try await send {
            var r = URLRequest(url: URL(string: "\(Self.api)/files/\(id)?fields=id")!)
            r.httpMethod = "PATCH"
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.httpBody = body
            return r
        }
    }

    /// Uploads a local file, creating it in `parent` or replacing the contents of `existing`.
    /// Resumable upload streamed from disk, so large PDFs never sit in memory.
    func upload(file url: URL, name: String, parent: String, existing: String?,
                appProperties: [String: String]) async throws -> DriveFile {
        var meta: [String: Any] = ["name": name, "appProperties": appProperties]
        if existing == nil { meta["parents"] = [parent] }
        let body = try JSONSerialization.data(withJSONObject: meta)
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0

        // 1. Start a session.
        let start: URL
        if let existing {
            start = URL(string: "\(Self.upload)/files/\(existing)?uploadType=resumable&fields=\(Self.fields)")!
        } else {
            start = URL(string: "\(Self.upload)/files?uploadType=resumable&fields=\(Self.fields)")!
        }
        let (_, resp) = try await send {
            var r = URLRequest(url: start)
            r.httpMethod = existing == nil ? "POST" : "PATCH"
            r.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
            r.setValue("application/octet-stream", forHTTPHeaderField: "X-Upload-Content-Type")
            r.setValue(String(size), forHTTPHeaderField: "X-Upload-Content-Length")
            r.httpBody = body
            return r
        }
        guard let location = resp.value(forHTTPHeaderField: "Location"), let session = URL(string: location) else {
            throw BackupError.badResponse("no upload session")
        }

        // 2. Send the bytes.
        var put = URLRequest(url: session)
        put.httpMethod = "PUT"
        put.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        put.timeoutInterval = 600
        let (data, r2) = try await URLSession.shared.upload(for: put, fromFile: url)
        let code = (r2 as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw Self.error(code, data) }
        return try JSONDecoder().decode(DriveFile.self, from: data)
    }

    /// Downloads a file's contents to `destination` (replacing it).
    func download(_ id: String, to destination: URL) async throws {
        let (tmp, resp) = try await sendDownload {
            URLRequest(url: URL(string: "\(Self.api)/files/\(id)?alt=media")!)
        }
        _ = resp
        let fm = FileManager.default
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        try fm.moveItem(at: tmp, to: destination)
    }

    /// Moves a file or folder to the Drive trash (recoverable there for 30 days).
    func trash(_ id: String) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["trashed": true])
        do {
            _ = try await send {
                var r = URLRequest(url: URL(string: "\(Self.api)/files/\(id)?fields=id")!)
                r.httpMethod = "PATCH"
                r.setValue("application/json", forHTTPHeaderField: "Content-Type")
                r.httpBody = body
                return r
            }
        } catch BackupError.http(404, _) {
            // Already gone.
        }
    }

    // MARK: Transport

    private func authorised(_ make: () -> URLRequest, fresh: Bool) async throws -> URLRequest {
        var r = make()
        r.setValue("Bearer \(try await token(fresh))", forHTTPHeaderField: "Authorization")
        return r
    }

    private func send(_ make: () -> URLRequest) async throws -> (Data, HTTPURLResponse) {
        var attempt = 0
        while true {
            let req = try await authorised(make, fresh: attempt > 0)
            let (data, resp) = try await URLSession.shared.data(for: req)
            let http = resp as? HTTPURLResponse
            let code = http?.statusCode ?? 0
            if (200..<300).contains(code), let http { return (data, http) }
            if code == 401 && attempt == 0 { attempt += 1; continue }
            if (code == 429 || code >= 500) && attempt < 3 {
                attempt += 1
                try await Task.sleep(nanoseconds: UInt64(attempt) * 1_500_000_000)
                continue
            }
            throw Self.error(code, data)
        }
    }

    private func sendDownload(_ make: () -> URLRequest) async throws -> (URL, HTTPURLResponse) {
        var attempt = 0
        while true {
            let req = try await authorised(make, fresh: attempt > 0)
            let (url, resp) = try await URLSession.shared.download(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if (200..<300).contains(code), let http = resp as? HTTPURLResponse {
                // Keep the file past this call (URLSession deletes its temp file).
                let keep = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                try FileManager.default.moveItem(at: url, to: keep)
                return (keep, http)
            }
            let data = (try? Data(contentsOf: url)) ?? Data()
            if code == 401 && attempt == 0 { attempt += 1; continue }
            if (code == 429 || code >= 500) && attempt < 3 {
                attempt += 1
                try await Task.sleep(nanoseconds: UInt64(attempt) * 1_500_000_000)
                continue
            }
            throw Self.error(code, data)
        }
    }

    private static func error(_ code: Int, _ data: Data) -> BackupError {
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let msg = ((json?["error"] as? [String: Any])?["message"] as? String) ?? "error"
        return .http(code, msg)
    }
}
