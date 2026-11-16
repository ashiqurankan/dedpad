import SwiftUI
import Network
import DedpadCore

/// Backs the library up to a "dedpad" folder in the user's own Google Drive, and restores from it.
///
/// Drive layout (only files dedpad created are visible to it):
///
///     dedpad/library.json                 folders and saved page templates
///     dedpad/<notebook title>/…           one folder per notebook: notebook.json, drawings, assets
///
/// Only files that changed since the last backup are uploaded (compared by size and modification
/// time), so after the first backup a run usually sends just the pages that were written on.
@MainActor
final class DriveBackup: ObservableObject {
    enum Status: Equatable {
        case off
        case idle
        case working(String)
        case waiting(String)
        case error(String)
    }

    @Published private(set) var status: Status = .off
    @Published private(set) var lastBackup: Date?
    @Published var automatic: Bool {
        didSet { UserDefaults.standard.set(automatic, forKey: Keys.automatic) }
    }
    @Published var wifiOnly: Bool {
        didSet { UserDefaults.standard.set(wifiOnly, forKey: Keys.wifiOnly) }
    }

    private enum Keys {
        static let automatic = "backup.automatic"
        static let wifiOnly = "backup.wifiOnly"
    }

    private let library: LibraryModel
    let auth: GoogleAuth
    private var state: BackupState
    private var running = false
    private var rerun = false
    private var dirty = true
    private var scheduled: Task<Void, Never>?
    private let monitor = NWPathMonitor()
    private var online = true
    private var expensive = false

    init(library: LibraryModel, auth: GoogleAuth) {
        self.library = library
        self.auth = auth
        state = BackupState.load()
        lastBackup = state.lastBackup
        let d = UserDefaults.standard
        automatic = d.object(forKey: Keys.automatic) as? Bool ?? true
        wifiOnly = d.object(forKey: Keys.wifiOnly) as? Bool ?? false

        library.onLocalChange = { [weak self] _ in self?.changed() }
        library.onLoaded = { [weak self] in self?.schedule(after: 4) }
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                guard let self else { return }
                let wasOnline = self.online
                self.online = path.status == .satisfied
                self.expensive = path.isExpensive
                if self.online && !wasOnline && self.dirty { self.schedule(after: 3) }
            }
        }
        monitor.start(queue: DispatchQueue(label: "dedpad.network"))
        status = auth.account == nil ? .off : .idle
    }

    // MARK: Triggers

    private func changed() {
        dirty = true
        guard automatic, auth.account != nil, scheduled == nil else { return }
        // Collect a burst of edits into one backup, without waiting forever while writing.
        schedule(after: 90)
    }

    func schedule(after seconds: Double) {
        guard automatic, auth.account != nil else { return }
        scheduled?.cancel()
        scheduled = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.scheduled = nil
            await self.backupNow()
        }
    }

    /// The app is going to the background: back up what changed while there's time.
    func appWillResignActive() {
        guard automatic, auth.account != nil, dirty else { return }
        scheduled?.cancel()
        scheduled = nil
        Task { await backupNow() }
    }

    func signedIn() {
        if state.account != auth.account?.email { state = BackupState(account: auth.account?.email) }
        status = .idle
        dirty = true
        Task { await backupNow() }
    }

    func signOut() {
        auth.signOut()
        scheduled?.cancel()
        scheduled = nil
        status = .off
    }

    // MARK: Backup

    func backupNow() async {
        guard auth.account != nil else { status = .off; return }
        if running { rerun = true; return }
        guard online else { status = .waiting("Waiting for a connection"); return }
        if wifiOnly && expensive { status = .waiting("Waiting for Wi-Fi"); return }
        running = true
        let bg = UIApplication.shared.beginBackgroundTask(withName: "Google Drive backup")
        defer {
            running = false
            if bg != .invalid { UIApplication.shared.endBackgroundTask(bg) }
        }
        dirty = false
        do {
            try await performBackup()
            state.lastBackup = Date()
            lastBackup = state.lastBackup
            state.save()
            status = .idle
        } catch BackupError.signedOut {
            status = .off
        } catch is CancellationError {
            dirty = true
            status = .idle
        } catch {
            dirty = true
            status = .error(error.localizedDescription)
            dlog("backup failed: \(error.localizedDescription)")
        }
        if rerun {
            rerun = false
            schedule(after: 5)
        }
    }

    private var drive: DriveClient {
        DriveClient(token: { [auth] fresh in try await auth.token(forceRefresh: fresh) })
    }

    private func performBackup() async throws {
        let store = library.store
        await Task.detached(priority: .utility) { DiskWriter.shared.drain() }.value
        if state.account != auth.account?.email { state = BackupState(account: auth.account?.email) }
        let drive = self.drive
        let root = try await ensureRoot(drive)

        // Folders and templates.
        if let stamp = Self.stamp(store.libraryFile) {
            if state.library?.stamp != stamp {
                status = .working("Backing up your library")
                let f = try await uploadReplacing(drive, file: store.libraryFile, name: "library.json", parent: root,
                                                  existing: state.library?.id, properties: ["dedpad": "library"])
                state.library = RemoteFile(id: f.id, stamp: stamp)
                state.save()
            }
        }

        // Notebooks.
        let notebooks = library.notebooks
        for (n, nb) in notebooks.enumerated() {
            try Task.checkCancellation()
            try await backup(nb, root: root, drive: drive, position: (n + 1, notebooks.count))
        }

        // Notebooks deleted for good on this iPad: move their backup to the Drive trash.
        let ids = Set(notebooks.map { $0.id.uuidString })
        for (id, entry) in state.notebooks where !ids.contains(id) {
            if let folder = entry.folderID { try await drive.trash(folder) }
            state.notebooks[id] = nil
            state.save()
        }
    }

    private func ensureRoot(_ drive: DriveClient) async throws -> String {
        if let id = state.rootID, try await drive.file(id) != nil { return id }
        let q = "name = 'dedpad' and mimeType = '\(DriveClient.folderType)' and 'root' in parents and trashed = false"
        let id: String
        if let found = try await drive.list(query: q).first {
            id = found.id
        } else {
            id = try await drive.createFolder(name: "dedpad", parent: nil, appProperties: ["dedpad": "root"]).id
        }
        if id != state.rootID {
            // A different (or recreated) folder: everything is uploaded again.
            state = BackupState(account: state.account)
            state.rootID = id
            state.save()
        }
        return id
    }

    private func backup(_ nb: Notebook, root: String, drive: DriveClient, position: (Int, Int)) async throws {
        let id = nb.id.uuidString
        let dir = library.store.directory(for: nb.id)
        let local = await Task.detached(priority: .utility) { Self.scan(dir) }.value
        guard local["notebook.json"] != nil else { return }
        var entry = state.notebooks[id] ?? NotebookEntry()
        let name = Self.folderName(nb)
        let changed = local.filter { entry.files[$0.key]?.stamp != $0.value }
        let removed = entry.files.keys.filter { local[$0] == nil }
        if entry.folderID != nil && changed.isEmpty && removed.isEmpty && entry.title == name { return }

        status = .working("Backing up “\(nb.title.isEmpty ? "Untitled" : nb.title)” (\(position.0) of \(position.1))")
        let folderProps = ["notebookId": id, "title": nb.title, "backedUpAt": ISO8601DateFormatter().string(from: Date())]
        if let folder = entry.folderID, try await drive.file(folder) == nil {
            entry = NotebookEntry()       // the folder was deleted in Drive: start over
        }
        if entry.folderID == nil {
            entry.folderID = try await drive.createFolder(name: name, parent: root, appProperties: folderProps).id
            entry.files = [:]
        }
        guard let folder = entry.folderID else { return }
        state.notebooks[id] = entry

        // Pages and files first, notebook.json last, so a backup never points at missing files.
        let pending = local.filter { entry.files[$0.key]?.stamp != $0.value }
            .sorted { ($0.key == "notebook.json" ? 1 : 0, $0.key) < ($1.key == "notebook.json" ? 1 : 0, $1.key) }
        for (path, stamp) in pending {
            try Task.checkCancellation()
            let f = try await uploadReplacing(drive, file: dir.appendingPathComponent(path), name: Self.driveName(path),
                                              parent: folder, existing: entry.files[path]?.id, properties: ["path": path])
            entry.files[path] = RemoteFile(id: f.id, stamp: stamp)
            state.notebooks[id] = entry
            state.save()
        }
        for path in entry.files.keys where local[path] == nil {
            if let fid = entry.files[path]?.id { try await drive.trash(fid) }
            entry.files[path] = nil
        }
        try await drive.updateMetadata(folder, name: entry.title == name ? nil : name, appProperties: folderProps)
        entry.title = name
        state.notebooks[id] = entry
        state.save()
    }

    /// Replaces a file's contents, or creates it if it's gone from Drive.
    private func uploadReplacing(_ drive: DriveClient, file: URL, name: String, parent: String, existing: String?,
                                 properties: [String: String]) async throws -> DriveFile {
        do {
            return try await drive.upload(file: file, name: name, parent: parent, existing: existing, appProperties: properties)
        } catch BackupError.http(404, _) where existing != nil {
            return try await drive.upload(file: file, name: name, parent: parent, existing: nil, appProperties: properties)
        }
    }

    // MARK: Restore

    struct RemoteNotebook: Identifiable, Hashable {
        let id: UUID
        let folderID: String
        let title: String
        let backedUpAt: Date?
        let onThisIPad: Bool
    }

    /// Notebooks in the Drive backup.
    func remoteNotebooks() async throws -> [RemoteNotebook] {
        let drive = self.drive
        let rootID: String?
        if let id = state.rootID, try await drive.file(id) != nil {
            rootID = id
        } else {
            let q = "name = 'dedpad' and mimeType = '\(DriveClient.folderType)' and 'root' in parents and trashed = false"
            rootID = try await drive.list(query: q).first?.id
        }
        guard let rootID else { return [] }
        let local = Set(library.notebooks.map(\.id))
        let iso = ISO8601DateFormatter()
        return try await drive.children(of: rootID, foldersOnly: true).compactMap { f in
            guard let s = f.appProperties?["notebookId"], let id = UUID(uuidString: s) else { return nil }
            return RemoteNotebook(id: id, folderID: f.id, title: f.appProperties?["title"] ?? f.name,
                                  backedUpAt: f.appProperties?["backedUpAt"].flatMap { iso.date(from: $0) },
                                  onThisIPad: local.contains(id))
        }
        .sorted { ($0.backedUpAt ?? .distantPast) > ($1.backedUpAt ?? .distantPast) }
    }

    /// Downloads notebooks from the backup, replacing the copies on this iPad.
    func restore(_ items: [RemoteNotebook]) async {
        guard !running else { library.show("Backup in progress", "Try again when the backup has finished."); return }
        running = true
        defer { running = false }
        let drive = self.drive
        let store = library.store
        var restored = 0
        var failed: [String] = []
        for (n, item) in items.enumerated() {
            if library.openNotebookID == item.id { failed.append("\(item.title) (open in the editor)"); continue }
            status = .working("Restoring “\(item.title)” (\(n + 1) of \(items.count))")
            do {
                try await restore(item, drive: drive, store: store)
                restored += 1
            } catch {
                failed.append(item.title)
                dlog("restore failed for \(item.title): \(error.localizedDescription)")
            }
        }
        if let rootID = state.rootID { await restoreLibraryIndex(rootID: rootID, drive: drive, store: store) }
        await library.reload()
        status = auth.account == nil ? .off : .idle
        var msg = "\(restored) notebook\(restored == 1 ? "" : "s") restored from Google Drive."
        if !failed.isEmpty { msg += " Couldn't restore: \(failed.joined(separator: ", "))." }
        library.show("Restore finished", msg)
    }

    private func restore(_ item: RemoteNotebook, drive: DriveClient, store: LibraryStore) async throws {
        let files = try await drive.children(of: item.folderID)
        guard files.contains(where: { ($0.appProperties?["path"] ?? $0.name) == "notebook.json" }) else {
            throw BackupError.badResponse("the backup has no notebook.json")
        }
        let fm = FileManager.default
        let temp = store.notebooksDirectory.appendingPathComponent(".restore-\(item.id.uuidString)", isDirectory: true)
        try? fm.removeItem(at: temp)
        try fm.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: temp) }

        var ids: [String: String] = [:]
        for f in files where f.mimeType != DriveClient.folderType {
            let path = f.appProperties?["path"] ?? f.name
            guard !path.contains(".."), !path.hasPrefix("/") else { continue }
            try await drive.download(f.id, to: temp.appendingPathComponent(path))
            ids[path] = f.id
        }
        // Make sure the notebook reads before replacing anything.
        let data = try Data(contentsOf: temp.appendingPathComponent("notebook.json"))
        _ = try LibraryStore.makeDecoder().decode(Notebook.self, from: data)

        let dest = store.directory(for: item.id)
        let old = store.notebooksDirectory.appendingPathComponent(".replaced-\(item.id.uuidString)", isDirectory: true)
        try? fm.removeItem(at: old)
        if fm.fileExists(atPath: dest.path) {
            // Keep the version history that lives only on this iPad.
            let history = dest.appendingPathComponent("history", isDirectory: true)
            if fm.fileExists(atPath: history.path) { try? fm.moveItem(at: history, to: temp.appendingPathComponent("history")) }
            try fm.moveItem(at: dest, to: old)
        }
        do {
            try fm.moveItem(at: temp, to: dest)
            try? fm.removeItem(at: old)
        } catch {
            if fm.fileExists(atPath: old.path) { try? fm.moveItem(at: old, to: dest) }
            throw error
        }

        // What's on disk now matches the backup: nothing to upload.
        var entry = NotebookEntry()
        entry.folderID = item.folderID
        entry.title = item.title.isEmpty ? "Untitled" : item.title
        for (path, stamp) in Self.scan(dest) {
            if let fid = ids[path] { entry.files[path] = RemoteFile(id: fid, stamp: stamp) }
        }
        state.notebooks[item.id.uuidString] = entry
        state.save()
    }

    /// Adds folders and saved templates from the backup that this iPad doesn't have.
    private func restoreLibraryIndex(rootID: String, drive: DriveClient, store: LibraryStore) async {
        guard let file = try? await drive.children(of: rootID).first(where: { $0.appProperties?["dedpad"] == "library" }) else { return }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("library-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }
        guard (try? await drive.download(file.id, to: tmp)) != nil,
              let data = try? Data(contentsOf: tmp),
              let remote = try? LibraryStore.makeDecoder().decode(LibraryIndex.self, from: data) else { return }
        var merged = library.index
        let folderIDs = Set(merged.folders.map(\.id))
        merged.folders += remote.folders.filter { !folderIDs.contains($0.id) }
        let paperIDs = Set(merged.savedPapers.map(\.id))
        merged.savedPapers += remote.savedPapers.filter { !paperIDs.contains($0.id) }
        if merged != library.index { library.replaceIndex(merged) }
    }

    // MARK: Files

    /// Every file of a notebook worth backing up, by relative path (no backups of backups, no history).
    nonisolated static func scan(_ dir: URL) -> [String: Stamp] {
        var out: [String: Stamp] = [:]
        let fm = FileManager.default
        let base = dir.standardizedFileURL.path
        guard let e = fm.enumerator(at: dir, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey],
                                    options: [.skipsHiddenFiles]) else { return out }
        for case let url as URL in e {
            let v = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
            if v?.isDirectory == true {
                if url.lastPathComponent == "history" { e.skipDescendants() }
                continue
            }
            if url.pathExtension == "bak" { continue }
            var path = url.standardizedFileURL.path
            guard path.hasPrefix(base) else { continue }
            path.removeFirst(base.count)
            while path.hasPrefix("/") { path.removeFirst() }
            out[path] = Stamp(size: v?.fileSize ?? 0,
                              modified: ((v?.contentModificationDate?.timeIntervalSince1970 ?? 0) * 1000).rounded())
        }
        return out
    }

    nonisolated static func stamp(_ url: URL) -> Stamp? {
        guard let v = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]), let size = v.fileSize else { return nil }
        return Stamp(size: size, modified: ((v.contentModificationDate?.timeIntervalSince1970 ?? 0) * 1000).rounded())
    }

    private static func folderName(_ nb: Notebook) -> String {
        let t = nb.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? "Untitled" : t
    }

    /// Readable names in Drive ("drawings › 3F2A….drawing"); the real path is in appProperties.
    private static func driveName(_ path: String) -> String {
        path.replacingOccurrences(of: "/", with: " › ")
    }
}

// MARK: - Saved state

struct Stamp: Codable, Equatable {
    var size: Int
    var modified: Double
}

struct RemoteFile: Codable, Equatable {
    var id: String
    var stamp: Stamp
}

struct NotebookEntry: Codable, Equatable {
    var folderID: String?
    var title = ""
    var files: [String: RemoteFile] = [:]
}

/// What has been uploaded, so a backup only sends what changed. Kept out of Documents.
struct BackupState: Codable {
    var account: String?
    var rootID: String?
    var library: RemoteFile?
    var notebooks: [String: NotebookEntry] = [:]
    var lastBackup: Date?

    init(account: String? = nil) { self.account = account }

    private static var url: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("drive-backup.json")
    }

    static func load() -> BackupState {
        guard let data = try? Data(contentsOf: url), let s = try? JSONDecoder().decode(BackupState.self, from: data) else {
            return BackupState()
        }
        return s
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) { try? data.write(to: Self.url, options: .atomic) }
    }
}
