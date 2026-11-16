import Foundation

/// Offline-first storage. Everything lives in plain files the user owns:
///
///     <root>/library.json                       folders, saved page templates
///     <root>/Notebooks/<id>/notebook.json       notebook + page metadata
///     <root>/Notebooks/<id>/drawings/<page>.drawing   PencilKit data per page
///     <root>/Notebooks/<id>/assets/…            imported PDFs, images, cover photo
///
/// On iPad `root` is the app's Documents folder, so it shows up in the Files app.
public final class LibraryStore: @unchecked Sendable {
    public let root: URL
    private let fm = FileManager.default

    public init(root: URL) {
        self.root = root
        try? fm.createDirectory(at: notebooksDirectory, withIntermediateDirectories: true)
    }

    public var notebooksDirectory: URL { root.appendingPathComponent("Notebooks", isDirectory: true) }
    public var libraryFile: URL { root.appendingPathComponent("library.json") }

    public func directory(for id: UUID) -> URL {
        notebooksDirectory.appendingPathComponent(id.uuidString, isDirectory: true)
    }
    public func notebookFile(for id: UUID) -> URL { directory(for: id).appendingPathComponent("notebook.json") }
    public func drawingsDirectory(for id: UUID) -> URL { directory(for: id).appendingPathComponent("drawings", isDirectory: true) }
    public func assetsDirectory(for id: UUID) -> URL { directory(for: id).appendingPathComponent("assets", isDirectory: true) }
    public func drawingURL(notebook: UUID, page: Page) -> URL {
        drawingsDirectory(for: notebook).appendingPathComponent(page.drawingFileName)
    }
    public func assetURL(notebook: UUID, file: String) -> URL {
        assetsDirectory(for: notebook).appendingPathComponent(file)
    }

    // MARK: JSON

    public static func makeEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }

    public static func makeDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            if let s = try? c.decode(String.self) {
                let f = ISO8601DateFormatter()
                if let date = f.date(from: s) { return date }
                f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                if let date = f.date(from: s) { return date }
                throw DecodingError.dataCorruptedError(in: c, debugDescription: "Bad date \(s)")
            }
            return Date(timeIntervalSinceReferenceDate: try c.decode(Double.self))
        }
        return d
    }

    // MARK: Library index

    public func loadIndex() -> LibraryIndex {
        guard let data = try? Data(contentsOf: libraryFile),
              let index = try? Self.makeDecoder().decode(LibraryIndex.self, from: data) else {
            return LibraryIndex()
        }
        return index
    }

    public func saveIndex(_ index: LibraryIndex) throws {
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try Self.makeEncoder().encode(index).write(to: libraryFile, options: .atomic)
    }

    // MARK: Notebooks

    /// Loads every notebook. Unreadable folders are skipped (and reported) rather than failing the library.
    public func loadNotebooks() -> (notebooks: [Notebook], failures: [URL]) {
        let r = loadNotebooksReport()
        return (r.notebooks, r.failures)
    }

    public struct LoadReport {
        public var notebooks: [Notebook] = []
        /// Files that could not be read at all.
        public var failures: [URL] = []
        /// Notebooks restored from their `.bak` copy because the main file was damaged.
        public var recovered: [UUID] = []
    }

    public func loadNotebooksReport() -> LoadReport {
        var report = LoadReport()
        let dirs = (try? fm.contentsOfDirectory(at: notebooksDirectory, includingPropertiesForKeys: nil)) ?? []
        let decoder = Self.makeDecoder()
        for dir in dirs {
            let file = dir.appendingPathComponent("notebook.json")
            let backup = dir.appendingPathComponent("notebook.json.bak")
            guard fm.fileExists(atPath: file.path) || fm.fileExists(atPath: backup.path) else { continue }
            var nb: Notebook?
            if let data = try? Data(contentsOf: file) { nb = try? decoder.decode(Notebook.self, from: data) }
            if nb == nil, let data = try? Data(contentsOf: backup), var restored = try? decoder.decode(Notebook.self, from: data) {
                if let id = UUID(uuidString: dir.lastPathComponent) { restored.id = id }
                // Put the good copy back in place.
                try? Self.makeEncoder().encode(restored).write(to: file, options: .atomic)
                nb = restored
                report.recovered.append(restored.id)
            }
            guard var loaded = nb else { report.failures.append(file); continue }
            // The folder name is the source of truth for the id.
            if let id = UUID(uuidString: dir.lastPathComponent), id != loaded.id { loaded.id = id }
            report.notebooks.append(loaded)
        }
        return report
    }

    public func loadNotebook(id: UUID) throws -> Notebook {
        let data = try Data(contentsOf: notebookFile(for: id))
        return try Self.makeDecoder().decode(Notebook.self, from: data)
    }

    /// Atomic write; the previous good version is kept as `notebook.json.bak`.
    public func save(_ notebook: Notebook) throws {
        try fm.createDirectory(at: drawingsDirectory(for: notebook.id), withIntermediateDirectories: true)
        try fm.createDirectory(at: assetsDirectory(for: notebook.id), withIntermediateDirectories: true)
        let file = notebookFile(for: notebook.id)
        let data = try Self.makeEncoder().encode(notebook)
        if let old = try? Data(contentsOf: file), old != data,
           (try? Self.makeDecoder().decode(Notebook.self, from: old)) != nil {
            try? old.write(to: file.appendingPathExtension("bak"), options: .atomic)
        }
        try data.write(to: file, options: .atomic)
    }

    public func delete(id: UUID) throws {
        let dir = directory(for: id)
        if fm.fileExists(atPath: dir.path) { try fm.removeItem(at: dir) }
    }

    /// Copies a notebook (drawings and assets included) under fresh ids.
    @discardableResult
    public func duplicate(_ source: Notebook, title: String? = nil, now: Date = Date()) throws -> Notebook {
        var copy = source
        copy.id = UUID()
        copy.title = title ?? "\(source.displayTitle) copy"
        copy.createdAt = now
        copy.modifiedAt = now
        copy.lastOpenedAt = nil
        copy.pages = source.pages.map { var p = $0; p.id = UUID(); return p }
        try save(copy)
        for (old, new) in zip(source.pages, copy.pages) {
            copyDrawing(fromNotebook: source.id, page: old, toNotebook: copy.id, page: new)
        }
        let assets = (try? fm.contentsOfDirectory(atPath: assetsDirectory(for: source.id).path)) ?? []
        for name in assets {
            try fm.copyItem(at: assetURL(notebook: source.id, file: name), to: assetURL(notebook: copy.id, file: name))
        }
        return copy
    }

    // MARK: Drawings

    public func readDrawing(notebook: UUID, page: Page) -> Data? {
        try? Data(contentsOf: drawingURL(notebook: notebook, page: page))
    }

    /// The previous version of a drawing, used when the current file turns out to be damaged.
    public func readDrawingBackup(notebook: UUID, page: Page) -> Data? {
        try? Data(contentsOf: drawingURL(notebook: notebook, page: page).appendingPathExtension("bak"))
    }

    /// Atomic write; the previous version is kept as `<page>.drawing.bak`.
    public func writeDrawing(_ data: Data, notebook: UUID, page: Page) throws {
        try fm.createDirectory(at: drawingsDirectory(for: notebook), withIntermediateDirectories: true)
        let url = drawingURL(notebook: notebook, page: page)
        if fm.fileExists(atPath: url.path) {
            let bak = url.appendingPathExtension("bak")
            try? fm.removeItem(at: bak)
            try? fm.copyItem(at: url, to: bak)
        }
        try data.write(to: url, options: .atomic)
    }

    public func inkURL(notebook: UUID, page: Page) -> URL {
        drawingsDirectory(for: notebook).appendingPathComponent(page.inkFileName)
    }

    public func readInk(notebook: UUID, page: Page) -> Data? {
        try? Data(contentsOf: inkURL(notebook: notebook, page: page))
    }

    public func writeInk(_ data: Data, notebook: UUID, page: Page) throws {
        try fm.createDirectory(at: drawingsDirectory(for: notebook), withIntermediateDirectories: true)
        try data.write(to: inkURL(notebook: notebook, page: page), options: .atomic)
    }

    public func deleteDrawing(notebook: UUID, page: Page) {
        let url = drawingURL(notebook: notebook, page: page)
        try? fm.removeItem(at: url)
        try? fm.removeItem(at: url.appendingPathExtension("bak"))
        try? fm.removeItem(at: inkURL(notebook: notebook, page: page))
    }

    public func copyDrawing(notebook: UUID, from: Page, to: Page) {
        copyDrawing(fromNotebook: notebook, page: from, toNotebook: notebook, page: to)
    }

    func copyDrawing(fromNotebook: UUID, page from: Page, toNotebook: UUID, page to: Page) {
        for (src, dst) in [
            (drawingURL(notebook: fromNotebook, page: from), drawingURL(notebook: toNotebook, page: to)),
            (inkURL(notebook: fromNotebook, page: from), inkURL(notebook: toNotebook, page: to)),
        ] where fm.fileExists(atPath: src.path) {
            try? fm.removeItem(at: dst)
            try? fm.copyItem(at: src, to: dst)
        }
    }

    // MARK: Assets

    /// Stores `data` in the notebook's assets folder and returns its file name.
    @discardableResult
    public func addAsset(_ data: Data, notebook: UUID, preferredName: String? = nil, ext: String) throws -> String {
        try fm.createDirectory(at: assetsDirectory(for: notebook), withIntermediateDirectories: true)
        let base = Self.safeFileName(preferredName ?? UUID().uuidString)
        var name = "\(base).\(ext)"
        var n = 2
        while fm.fileExists(atPath: assetURL(notebook: notebook, file: name).path) {
            name = "\(base)-\(n).\(ext)"
            n += 1
        }
        try data.write(to: assetURL(notebook: notebook, file: name), options: .atomic)
        return name
    }

    public func removeAsset(notebook: UUID, file: String) {
        try? fm.removeItem(at: assetURL(notebook: notebook, file: file))
    }

    /// Removes assets no page or cover refers to any more.
    public func pruneAssets(of notebook: Notebook) {
        // Keep assets that older versions in history still use.
        var used = Set(notebook.referencedAssets)
        let dec = Self.makeDecoder()
        for snap in snapshots(for: notebook.id) {
            let file = historyDirectory(for: notebook.id).appendingPathComponent(snap.name).appendingPathComponent("notebook.json")
            if let data = try? Data(contentsOf: file), let old = try? dec.decode(Notebook.self, from: data) {
                used.formUnion(old.referencedAssets)
            }
        }
        let names = (try? fm.contentsOfDirectory(atPath: assetsDirectory(for: notebook.id).path)) ?? []
        for name in names where !used.contains(name) {
            removeAsset(notebook: notebook.id, file: name)
        }
    }

    // MARK: Utilities

    /// Total bytes used by the library.
    public func diskUsage() -> Int64 {
        guard let e = fm.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in e {
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    /// Keeps letters, digits, spaces, dashes and underscores; never empty.
    public static func safeFileName(_ s: String, fallback: String = "dedpad") -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " -_()"))
        let cleaned = String(String.UnicodeScalarView(s.unicodeScalars.map { allowed.contains($0) ? $0 : "-" }))
            .trimmingCharacters(in: CharacterSet(charactersIn: " -."))
        let trimmed = String(cleaned.prefix(80))
        return trimmed.isEmpty ? fallback : trimmed
    }
}

// MARK: - Version history

public struct SnapshotInfo: Identifiable, Hashable, Sendable {
    public var id: String { name }
    /// Folder name inside `history/` (a sortable timestamp).
    public var name: String
    public var date: Date
    public var pageCount: Int
    public var title: String
}

public extension LibraryStore {
    /// How many automatic versions are kept per notebook.
    static let snapshotLimit = 15

    func historyDirectory(for id: UUID) -> URL {
        directory(for: id).appendingPathComponent("history", isDirectory: true)
    }

    private static let snapshotFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return f
    }()

    /// Copies `notebook.json` and the drawings into `history/<timestamp>/`, then prunes old versions.
    @discardableResult
    func makeSnapshot(of notebook: Notebook, date: Date = Date()) throws -> SnapshotInfo {
        let fm = FileManager.default
        let name = Self.snapshotFormatter.string(from: date)
        let dir = historyDirectory(for: notebook.id).appendingPathComponent(name, isDirectory: true)
        try? fm.removeItem(at: dir)
        try fm.createDirectory(at: dir.appendingPathComponent("drawings"), withIntermediateDirectories: true)
        try Self.makeEncoder().encode(notebook).write(to: dir.appendingPathComponent("notebook.json"), options: .atomic)
        for page in notebook.pages {
            for (src, file) in [(drawingURL(notebook: notebook.id, page: page), page.drawingFileName),
                                (inkURL(notebook: notebook.id, page: page), page.inkFileName)]
            where fm.fileExists(atPath: src.path) {
                try fm.copyItem(at: src, to: dir.appendingPathComponent("drawings").appendingPathComponent(file))
            }
        }
        let all = snapshots(for: notebook.id)
        for old in all.dropFirst(Self.snapshotLimit) {
            try? fm.removeItem(at: historyDirectory(for: notebook.id).appendingPathComponent(old.name))
        }
        return SnapshotInfo(name: name, date: date, pageCount: notebook.pages.count, title: notebook.displayTitle)
    }

    /// Saved versions, newest first.
    func snapshots(for id: UUID) -> [SnapshotInfo] {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: historyDirectory(for: id).path)) ?? []
        let dec = Self.makeDecoder()
        return names.compactMap { name -> SnapshotInfo? in
            guard let date = Self.snapshotFormatter.date(from: name) else { return nil }
            let file = historyDirectory(for: id).appendingPathComponent(name).appendingPathComponent("notebook.json")
            guard let data = try? Data(contentsOf: file), let nb = try? dec.decode(Notebook.self, from: data) else { return nil }
            return SnapshotInfo(name: name, date: date, pageCount: nb.pages.count, title: nb.displayTitle)
        }
        .sorted { $0.date > $1.date }
    }

    func latestSnapshotDate(for id: UUID) -> Date? { snapshots(for: id).first?.date }

    /// Restores a saved version as a new notebook (the current one is left untouched).
    func restoreSnapshot(notebook id: UUID, name: String, now: Date = Date()) throws -> Notebook {
        let fm = FileManager.default
        let dir = historyDirectory(for: id).appendingPathComponent(name)
        let data = try Data(contentsOf: dir.appendingPathComponent("notebook.json"))
        let old = try Self.makeDecoder().decode(Notebook.self, from: data)
        var copy = old
        copy.id = UUID()
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        copy.title = "\(old.displayTitle) (\(f.string(from: Self.snapshotFormatter.date(from: name) ?? now)))"
        copy.createdAt = now
        copy.modifiedAt = now
        copy.lastOpenedAt = nil
        copy.deletedAt = nil
        try save(copy)
        for page in copy.pages {
            for (file, dst) in [(page.drawingFileName, drawingURL(notebook: copy.id, page: page)),
                                (page.inkFileName, inkURL(notebook: copy.id, page: page))] {
                let src = dir.appendingPathComponent("drawings").appendingPathComponent(file)
                if fm.fileExists(atPath: src.path) { try fm.copyItem(at: src, to: dst) }
            }
        }
        // Assets are shared with the live notebook; copy the ones the version uses.
        for name in copy.referencedAssets {
            let src = assetURL(notebook: id, file: name)
            if fm.fileExists(atPath: src.path) { try? fm.copyItem(at: src, to: assetURL(notebook: copy.id, file: name)) }
        }
        return copy
    }
}
