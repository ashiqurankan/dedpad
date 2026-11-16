import Foundation

/// Archives, backups and text export. Nothing here depends on PencilKit: drawings travel as
/// opaque `Data` (PencilKit's own data representation), which round-trips losslessly.
public enum Portability {

    // MARK: - Notebook archive (.zip)

    public static let archiveFormat = "dedpad-archive"
    public static let backupFormat = "dedpad-backup"
    public static let libraryBackupFormat = "dedpad-library"

    struct Manifest: Codable {
        var format: String
        var version: Int
        var exportedAt: Date
        var notebooks: Int
    }

    /// One notebook as a ZIP: `dedpad.json`, `notebook.json`, `drawings/…`, `assets/…`.
    public static func archive(_ notebook: Notebook, store: LibraryStore, date: Date = Date()) throws -> Data {
        try Zip.archive(entries(for: notebook, store: store, prefix: "", date: date, manifest: true), date: date)
    }

    static func entries(for notebook: Notebook, store: LibraryStore, prefix: String, date: Date, manifest: Bool) throws -> [Zip.Entry] {
        let enc = LibraryStore.makeEncoder()
        var out: [Zip.Entry] = []
        if manifest {
            out.append(Zip.Entry(path: "dedpad.json", data: try enc.encode(Manifest(format: archiveFormat, version: 1, exportedAt: date, notebooks: 1))))
        }
        out.append(Zip.Entry(path: prefix + "notebook.json", data: try enc.encode(notebook)))
        for page in notebook.pages {
            if let d = store.readDrawing(notebook: notebook.id, page: page) {
                out.append(Zip.Entry(path: prefix + "drawings/" + page.drawingFileName, data: d))
            }
            if let d = store.readInk(notebook: notebook.id, page: page) {
                out.append(Zip.Entry(path: prefix + "drawings/" + page.inkFileName, data: d))
            }
        }
        for name in assetNames(of: notebook) {
            if let d = try? Data(contentsOf: store.assetURL(notebook: notebook.id, file: name)) {
                out.append(Zip.Entry(path: prefix + "assets/" + name, data: d))
            }
        }
        return out
    }

    static func assetNames(of nb: Notebook) -> [String] { nb.referencedAssets }

    /// Restores a notebook archive into the library as a new notebook.
    @discardableResult
    public static func importArchive(_ data: Data, into store: LibraryStore, inflate: Zip.Inflater? = nil, now: Date = Date()) throws -> Notebook {
        let entries = try Zip.entries(in: data, inflate: inflate)
        guard let nbEntry = entries.first(where: { $0.path == "notebook.json" || $0.path.hasSuffix("/notebook.json") }) else {
            throw DedpadError.invalidArchive("there is no notebook.json inside")
        }
        let prefix = String(nbEntry.path.dropLast("notebook.json".count))
        let source = try LibraryStore.makeDecoder().decode(Notebook.self, from: nbEntry.data)
        var files: [String: Data] = [:]
        for e in entries where e.path.hasPrefix(prefix) {
            files[String(e.path.dropFirst(prefix.count))] = e.data
        }
        return try restore(source, files: files, into: store, now: now)
    }

    /// Writes a notebook plus its files (`drawings/<x>`, `assets/<x>`) under a fresh id.
    static func restore(_ source: Notebook, files: [String: Data], into store: LibraryStore, keepID: Bool = false, now: Date) throws -> Notebook {
        var nb = source
        if !keepID { nb.id = UUID() }
        nb.lastOpenedAt = nil
        try store.save(nb)
        for page in nb.pages {
            if let d = files["drawings/" + page.drawingFileName] {
                try store.writeDrawing(d, notebook: nb.id, page: page)
            }
            if let d = files["drawings/" + page.inkFileName] {
                try store.writeInk(d, notebook: nb.id, page: page)
            }
        }
        for name in assetNames(of: nb) {
            guard let d = files["assets/" + name] else { continue }
            let url = store.assetURL(notebook: nb.id, file: name)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try d.write(to: url, options: .atomic)
        }
        return nb
    }

    // MARK: - JSON backup

    public struct NotebookBackup: Codable {
        public var format: String
        public var version: Int
        public var exportedAt: Date
        public var notebook: Notebook
        /// Page drawing data, keyed by page id.
        public var drawings: [String: Data]
        /// Asset files, keyed by file name.
        public var assets: [String: Data]
        /// Open ink JSON per page id (readable without PencilKit).
        public var ink: [String: Data]?
    }

    /// A single self-contained JSON file (drawings and assets are base64).
    public static func jsonBackup(_ notebook: Notebook, store: LibraryStore, date: Date = Date()) throws -> Data {
        var drawings: [String: Data] = [:]
        for page in notebook.pages {
            if let d = store.readDrawing(notebook: notebook.id, page: page) { drawings[page.id.uuidString] = d }
        }
        var assets: [String: Data] = [:]
        for name in assetNames(of: notebook) {
            if let d = try? Data(contentsOf: store.assetURL(notebook: notebook.id, file: name)) { assets[name] = d }
        }
        var ink: [String: Data] = [:]
        for page in notebook.pages {
            if let d = store.readInk(notebook: notebook.id, page: page) { ink[page.id.uuidString] = d }
        }
        let backup = NotebookBackup(format: backupFormat, version: 1, exportedAt: date, notebook: notebook, drawings: drawings, assets: assets, ink: ink)
        return try LibraryStore.makeEncoder().encode(backup)
    }

    @discardableResult
    public static func importJSONBackup(_ data: Data, into store: LibraryStore, now: Date = Date()) throws -> Notebook {
        let backup: NotebookBackup
        do {
            backup = try LibraryStore.makeDecoder().decode(NotebookBackup.self, from: data)
        } catch let e as DedpadError {
            throw e
        } catch {
            throw DedpadError.invalidBackup("it is not a dedpad notebook backup")
        }
        guard backup.format == backupFormat else { throw DedpadError.invalidBackup("unknown format \(backup.format)") }
        var files: [String: Data] = [:]
        for page in backup.notebook.pages {
            if let d = backup.drawings[page.id.uuidString] { files["drawings/" + page.drawingFileName] = d }
            if let d = backup.ink?[page.id.uuidString] { files["drawings/" + page.inkFileName] = d }
        }
        for (name, d) in backup.assets { files["assets/" + name] = d }
        return try restore(backup.notebook, files: files, into: store, now: now)
    }

    // MARK: - Whole-library backup (.zip)

    public static func libraryBackup(_ notebooks: [Notebook], index: LibraryIndex, store: LibraryStore, date: Date = Date()) throws -> Data {
        let enc = LibraryStore.makeEncoder()
        var entries: [Zip.Entry] = [
            Zip.Entry(path: "dedpad.json", data: try enc.encode(Manifest(format: libraryBackupFormat, version: 1, exportedAt: date, notebooks: notebooks.count))),
            Zip.Entry(path: "library.json", data: try enc.encode(index)),
        ]
        for nb in notebooks {
            entries += try Self.entries(for: nb, store: store, prefix: "Notebooks/\(nb.id.uuidString)/", date: date, manifest: false)
        }
        return Zip.archive(entries, date: date)
    }

    public struct RestoreReport: Equatable, Sendable {
        public var added = 0
        public var updated = 0
        public var skipped = 0
        public var foldersAdded = 0
    }

    /// Restores a library backup. Notebooks that already exist are replaced only if the backup copy is newer.
    public static func restoreLibrary(
        _ data: Data, into store: LibraryStore, existing: [Notebook], inflate: Zip.Inflater? = nil, now: Date = Date()
    ) throws -> RestoreReport {
        let entries = try Zip.entries(in: data, inflate: inflate)
        var report = RestoreReport()
        let dec = LibraryStore.makeDecoder()

        if let libEntry = entries.first(where: { $0.path == "library.json" }),
           let incoming = try? dec.decode(LibraryIndex.self, from: libEntry.data) {
            var index = store.loadIndex()
            let known = Set(index.folders.map(\.id))
            for f in incoming.folders where !known.contains(f.id) { index.folders.append(f); report.foldersAdded += 1 }
            let knownPapers = Set(index.savedPapers.map(\.id))
            index.savedPapers += incoming.savedPapers.filter { !knownPapers.contains($0.id) }
            try store.saveIndex(index)
        }

        var groups: [String: [String: Data]] = [:]
        for e in entries where e.path.hasPrefix("Notebooks/") {
            let rest = e.path.dropFirst("Notebooks/".count)
            guard let slash = rest.firstIndex(of: "/") else { continue }
            groups[String(rest[..<slash]), default: [:]][String(rest[rest.index(after: slash)...])] = e.data
        }
        if groups.isEmpty, entries.contains(where: { $0.path == "notebook.json" }) {
            throw DedpadError.invalidArchive("this is a single-notebook archive; import it from the library instead")
        }
        let byID = Dictionary(existing.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for (_, files) in groups.sorted(by: { $0.key < $1.key }) {
            guard let json = files["notebook.json"], let nb = try? dec.decode(Notebook.self, from: json) else { continue }
            if let current = byID[nb.id] {
                if nb.modifiedAt > current.modifiedAt {
                    try store.delete(id: nb.id)
                    _ = try restore(nb, files: files, into: store, keepID: true, now: now)
                    report.updated += 1
                } else {
                    report.skipped += 1
                }
            } else {
                _ = try restore(nb, files: files, into: store, keepID: true, now: now)
                report.added += 1
            }
        }
        return report
    }

    // MARK: - Text

    public static func plainText(_ nb: Notebook) -> String {
        var lines: [String] = [nb.displayTitle, String(repeating: "=", count: max(3, nb.displayTitle.count))]
        if !nb.details.isEmpty { lines += ["", nb.details] }
        lines += ["", metadataLine(nb)]
        for (i, page) in nb.pages.enumerated() {
            lines += ["", "Page \(i + 1)\(pageSuffix(page))", String(repeating: "-", count: 8)]
            let t = page.typedNotes.trimmingCharacters(in: .whitespacesAndNewlines)
            lines.append(t.isEmpty ? "(handwriting only)" : t)
        }
        lines += ["", "Exported from dedpad. Handwriting is not included in text exports; use PDF, PNG or SVG for that."]
        return lines.joined(separator: "\n") + "\n"
    }

    public static func markdown(_ nb: Notebook) -> String {
        var lines: [String] = ["# \(escapeMD(nb.displayTitle))", ""]
        if !nb.details.isEmpty { lines += ["> " + nb.details.replacingOccurrences(of: "\n", with: "\n> "), ""] }
        lines += ["*\(metadataLine(nb))*"]
        if !nb.categories.isEmpty { lines += ["", nb.categories.map { "`\($0)`" }.joined(separator: " ")] }
        for (i, page) in nb.pages.enumerated() {
            lines += ["", "## Page \(i + 1)\(pageSuffix(page))", ""]
            let t = page.typedNotes.trimmingCharacters(in: .whitespacesAndNewlines)
            lines.append(t.isEmpty ? "_Handwriting only._" : t)
        }
        lines += ["", "---", "", "_Exported from dedpad. Handwritten strokes are not part of Markdown exports._"]
        return lines.joined(separator: "\n") + "\n"
    }

    private static func metadataLine(_ nb: Notebook) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        f.locale = Locale(identifier: "en_US_POSIX")
        return "\(nb.pages.count) page\(nb.pages.count == 1 ? "" : "s") · created \(f.string(from: nb.createdAt)) · edited \(f.string(from: nb.modifiedAt))"
    }

    private static func pageSuffix(_ page: Page) -> String {
        switch page.background {
        case .paper: return ""
        case let .pdf(file, index): return " (PDF \(file), page \(index + 1))"
        case let .image(file): return " (image \(file))"
        }
    }

    private static func escapeMD(_ s: String) -> String {
        s.replacingOccurrences(of: "#", with: "\\#")
    }
}
