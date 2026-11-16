import SwiftUI
import UIKit
import PDFKit
import UniformTypeIdentifiers
import DedpadCore

/// App-wide preferences (Settings → Default notebook preferences, drawing, appearance).
enum AppPrefs {
    static let appearance = "appearance"              // system | light | dark
    static let drawingPolicy = "drawingPolicy"        // system | pencil | any
    static let showToolPicker = "showToolPicker"
    static let defaultStyle = "defaultPaperStyle"
    static let defaultPaperColor = "defaultPaperColor"
    static let defaultPageSize = "defaultPageSize"
    static let defaultOrientation = "defaultOrientation"
    static let defaultMode = "defaultPageMode"
    static let defaultPageNumbers = "defaultPageNumbers"
    static let sort = "librarySort"
    static let sortAscending = "librarySortAscending"

    static func newNotebookSettings() -> NotebookSettings {
        let d = UserDefaults.standard
        let style = PaperStyle(rawValue: d.string(forKey: defaultStyle) ?? "") ?? .ruled
        var paper = PaperSpec(style: style)
        if let hex = d.string(forKey: defaultPaperColor), let c = RGBA(hex: hex) {
            paper.background = c
            if c.isDark { paper.lineColor = RGBA(0x3E443A) }
        }
        return NotebookSettings(
            pageSize: PageSizePreset(rawValue: d.string(forKey: defaultPageSize) ?? "") ?? .a4,
            orientation: PageOrientation(rawValue: d.string(forKey: defaultOrientation) ?? "") ?? .portrait,
            mode: PageMode(rawValue: d.string(forKey: defaultMode) ?? "") ?? .fixed,
            paper: paper,
            pageNumbers: PageNumberPosition(rawValue: d.string(forKey: defaultPageNumbers) ?? "") ?? .bottomCenter
        )
    }
}

@MainActor
final class LibraryModel: ObservableObject {
    @Published private(set) var notebooks: [Notebook] = []
    @Published private(set) var index = LibraryIndex()
    @Published var alert: AlertMessage?
    @Published private(set) var isLoading = true

    let store: LibraryStore
    /// The notebook open in the editor (restore leaves it alone while it's being edited).
    var openNotebookID: UUID?
    /// Called whenever a notebook changes locally (triggers a Google Drive backup).
    var onLocalChange: ((UUID) -> Void)?
    /// Called after the library has loaded from disk.
    var onLoaded: (() -> Void)?

    struct AlertMessage: Identifiable {
        let id = UUID()
        var title: String
        var message: String
    }

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        store = LibraryStore(root: docs)
        Task { await reload() }
    }

    /// Loads the library off the main thread, recovers damaged files and empties old trash.
    func reload() async {
        isLoading = true
        let store = self.store
        let (report, index) = await Task.detached(priority: .userInitiated) {
            (store.loadNotebooksReport(), store.loadIndex())
        }.value
        notebooks = report.notebooks
        self.index = index
        isLoading = false

        for nb in LibraryQuery.expiredTrash(notebooks) { deletePermanently(nb.id) }
        if notebooks.isEmpty && !UserDefaults.standard.bool(forKey: "didSeedWelcome") {
            UserDefaults.standard.set(true, forKey: "didSeedWelcome")
            createWelcomeNotebook()
        }
        if !report.recovered.isEmpty {
            show("Notebook recovered",
                 "\(report.recovered.count) notebook file(s) were damaged and have been restored from their last good copy.")
        }
        if !report.failures.isEmpty {
            show("Some notebooks could not be opened",
                 "\(report.failures.count) notebook file(s) are damaged or from a newer version of dedpad. They were left untouched on disk.")
        }
        onLoaded?()
    }

    func noteEdited(_ id: UUID) { onLocalChange?(id) }

    func show(_ title: String, _ message: String) { alert = AlertMessage(title: title, message: message) }

    func notebook(_ id: UUID) -> Notebook? { notebooks.first { $0.id == id } }

    // MARK: Notebooks

    func save(_ nb: Notebook) {
        if let i = notebooks.firstIndex(where: { $0.id == nb.id }) {
            notebooks[i] = nb
        } else {
            notebooks.append(nb)
        }
        do { try store.save(nb) } catch { show("Couldn't save", error.localizedDescription) }
        onLocalChange?(nb.id)
    }

    @discardableResult
    func create(_ nb: Notebook) -> Notebook {
        save(nb)
        return nb
    }

    func update(_ id: UUID, _ change: (inout Notebook) -> Void) {
        guard var nb = notebook(id) else { return }
        change(&nb)
        nb.touch()
        save(nb)
    }

    /// Metadata-only change that should not bump "modified".
    func updateQuietly(_ id: UUID, _ change: (inout Notebook) -> Void) {
        guard var nb = notebook(id) else { return }
        change(&nb)
        save(nb)
    }

    func duplicate(_ id: UUID) {
        guard let nb = notebook(id) else { return }
        do {
            let copy = try store.duplicate(nb)
            notebooks.append(copy)
            onLocalChange?(copy.id)
        } catch { show("Couldn't duplicate", error.localizedDescription) }
    }

    /// Moves a notebook to Recently Deleted (kept for 30 days).
    func delete(_ id: UUID) {
        updateQuietly(id) { $0.deletedAt = Date() }
    }

    func restoreFromTrash(_ id: UUID) {
        updateQuietly(id) { $0.deletedAt = nil }
    }

    /// Removes a notebook and its files for good.
    func deletePermanently(_ id: UUID) {
        do {
            try store.delete(id: id)
            notebooks.removeAll { $0.id == id }
            onLocalChange?(id)
        } catch { show("Couldn't delete", error.localizedDescription) }
    }

    func emptyTrash() {
        for nb in notebooks where nb.isDeleted { deletePermanently(nb.id) }
    }

    /// Restores a saved version as a new notebook.
    @discardableResult
    func restoreVersion(of id: UUID, snapshot: String) -> Notebook? {
        do {
            let nb = try store.restoreSnapshot(notebook: id, name: snapshot)
            notebooks.append(nb)
            onLocalChange?(nb.id)
            return nb
        } catch {
            show("Couldn't restore that version", error.localizedDescription)
            return nil
        }
    }

    func setArchived(_ id: UUID, _ archived: Bool) { updateQuietly(id) { $0.isArchived = archived } }
    func toggleFavorite(_ id: UUID) { updateQuietly(id) { $0.isFavorite.toggle() } }
    func move(_ id: UUID, to folder: UUID?) { updateQuietly(id) { $0.folderID = folder } }
    func rename(_ id: UUID, to title: String) { update(id) { $0.title = title } }
    func markOpened(_ id: UUID) { updateQuietly(id) { $0.markOpened() } }

    // MARK: Folders

    /// Folders and templates merged in from a backup.
    func replaceIndex(_ new: LibraryIndex) {
        index = new
        saveIndex()
    }

    func saveIndex() {
        do { try store.saveIndex(index) } catch { show("Couldn't save the library", error.localizedDescription) }
    }

    @discardableResult
    func addFolder(_ name: String) -> Folder {
        let f = Folder(name: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "New folder" : name)
        index.folders.append(f)
        saveIndex()
        return f
    }

    func renameFolder(_ id: UUID, _ name: String) {
        guard let i = index.folders.firstIndex(where: { $0.id == id }) else { return }
        index.folders[i].name = name
        saveIndex()
    }

    /// Deleting a folder never deletes notebooks: they move to "Unfiled".
    func deleteFolder(_ id: UUID) {
        index.folders.removeAll { $0.id == id }
        saveIndex()
        for nb in notebooks where nb.folderID == id { move(nb.id, to: nil) }
    }

    func moveFolders(from: IndexSet, to: Int) {
        index.folders.move(fromOffsets: from, toOffset: to)
        saveIndex()
    }

    func folderName(_ id: UUID?) -> String? {
        guard let id else { return nil }
        return index.folders.first { $0.id == id }?.name
    }

    // MARK: Saved page templates

    func savePaper(_ paper: PaperSpec, name: String) {
        index.savedPapers.append(SavedPaper(name: name.isEmpty ? paper.style.name : name, paper: paper))
        saveIndex()
    }

    func deleteSavedPaper(_ id: UUID) {
        index.savedPapers.removeAll { $0.id == id }
        saveIndex()
    }

    // MARK: Cover images

    func coverImage(for nb: Notebook) -> UIImage? {
        guard let file = nb.cover.imageFile else { return nil }
        return ImageCache.shared.image(at: store.assetURL(notebook: nb.id, file: file))
    }

    /// Stores a cover photo for a notebook (not yet saved in its metadata).
    func storeCoverImage(_ image: UIImage, notebookID: UUID) -> String? {
        let scaled = image.downscaled(maxSide: 1600)
        guard let data = scaled.jpegData(compressionQuality: 0.86) else { return nil }
        do {
            let name = try store.addAsset(data, notebook: notebookID, preferredName: "cover", ext: "jpg")
            return name
        } catch {
            show("Couldn't add the image", error.localizedDescription)
            return nil
        }
    }

    // MARK: Import

    /// Imports files picked in the Files app. Returns the notebooks that were created.
    @discardableResult
    func importFiles(_ urls: [URL], folder: UUID? = nil) -> [Notebook] {
        var created: [Notebook] = []
        var imageURLs: [URL] = []
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let type = UTType(filenameExtension: url.pathExtension.lowercased())
            do {
                if type?.conforms(to: .pdf) == true {
                    created.append(try importPDF(url, folder: folder))
                } else if type?.conforms(to: .zip) == true || url.pathExtension.lowercased() == "dedpad" {
                    var nb = try Portability.importArchive(try Data(contentsOf: url), into: store, inflate: Inflate.raw)
                    nb.folderID = folder ?? nb.folderID
                    save(nb)
                    created.append(nb)
                } else if type?.conforms(to: .json) == true {
                    var nb = try Portability.importJSONBackup(try Data(contentsOf: url), into: store)
                    nb.folderID = folder ?? nb.folderID
                    save(nb)
                    created.append(nb)
                } else if type?.conforms(to: .image) == true {
                    // Copy now: the security scope ends with this loop iteration.
                    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "." + url.pathExtension)
                    try FileManager.default.copyItem(at: url, to: tmp)
                    imageURLs.append(tmp)
                } else {
                    show("Can't import \(url.lastPathComponent)", "dedpad imports PDFs, images, notebook archives (.zip) and JSON backups.")
                }
            } catch {
                show("Couldn't import \(url.lastPathComponent)", error.localizedDescription)
            }
        }
        if !imageURLs.isEmpty {
            let images = imageURLs.compactMap { UIImage(contentsOfFile: $0.path) }
            if let nb = importImages(images, title: imageURLs.count == 1 ? imageURLs[0].deletingPathExtension().lastPathComponent : "Imported images", folder: folder) {
                created.append(nb)
            }
            for u in imageURLs { try? FileManager.default.removeItem(at: u) }
        }
        return created
    }

    func importPDF(_ url: URL, folder: UUID?) throws -> Notebook {
        let data = try Data(contentsOf: url)
        guard let doc = PDFDocument(data: data), doc.pageCount > 0 else {
            throw DedpadError.invalidArchive("the PDF is empty, damaged or password-protected")
        }
        let title = url.deletingPathExtension().lastPathComponent
        var nb = Notebook(title: title, folderID: folder, cover: CoverPresets.preset(id: "aca-ledger")?.design ?? CoverDesign(),
                          settings: AppPrefs.newNotebookSettings())
        let file = try store.addAsset(data, notebook: nb.id, preferredName: LibraryStore.safeFileName(title), ext: "pdf")
        nb.pages = PDFImport.pages(for: doc, file: file)
        save(nb)
        return nb
    }

    func importImages(_ images: [UIImage], title: String, folder: UUID?) -> Notebook? {
        guard !images.isEmpty else { return nil }
        var nb = Notebook(title: title, folderID: folder, cover: CoverPresets.random(), settings: AppPrefs.newNotebookSettings())
        var pages: [Page] = []
        for image in images {
            if let page = ImageImport.page(for: image, notebook: nb, store: store) { pages.append(page) }
        }
        guard !pages.isEmpty else { return nil }
        nb.pages = pages
        save(nb)
        return nb
    }

    // MARK: Whole-library backup

    func libraryBackupFile() throws -> URL {
        let data = try Portability.libraryBackup(notebooks, index: index, store: store)
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        let url = ExportFiles.newDirectory().appendingPathComponent("dedpad-library-\(f.string(from: Date())).zip")
        try data.write(to: url)
        return url
    }

    func restoreLibrary(from url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let r = try Portability.restoreLibrary(try Data(contentsOf: url), into: store, existing: notebooks, inflate: Inflate.raw)
            Task { await reload() }
            show("Backup restored", "\(r.added) notebook(s) added, \(r.updated) updated, \(r.skipped) already up to date. \(r.foldersAdded) folder(s) added.")
        } catch {
            show("Couldn't restore", error.localizedDescription)
        }
    }

    // MARK: Welcome

    private func createWelcomeNotebook() {
        var settings = AppPrefs.newNotebookSettings()
        settings.paper = PaperSpec(style: .dotted, background: DedPalette.warmPaper)
        var nb = Notebook(
            title: "Welcome to dedpad",
            details: "Your notebooks. Your pages. Your way.",
            cover: CoverPresets.preset(id: "ded-sage")?.design ?? CoverDesign(),
            settings: settings
        )
        nb.pages[0].typedNotes = """
        Write with Apple Pencil (or your finger, if you turn it on in the toolbar).
        Pick pens, highlighters, the eraser and the lasso from the floating tool palette.
        Use + to add pages, the paper icon to change a page's template, and the share icon to export.
        """
        var cornell = Page(size: settings.pageDimensions, paper: PaperSpec(style: .cornell, background: DedPalette.warmPaper))
        cornell.typedNotes = "A Cornell notes page."
        nb.pages.append(cornell)
        nb.pages.append(Page(size: settings.pageDimensions, paper: PaperSpec(style: .weeklyPlanner, background: DedPalette.warmPaper)))
        save(nb)
    }
}

// MARK: - Import helpers

enum PDFImport {
    static func pages(for doc: PDFDocument, file: String) -> [Page] {
        (0..<doc.pageCount).compactMap { i in
            guard let p = doc.page(at: i) else { return nil }
            var size = PDFCache.displaySize(of: p)
            if size.width < 10 || size.height < 10 { size = PageSizePreset.a4.dimensions }
            return Page(size: size, background: .pdf(file: file, pageIndex: i))
        }
    }
}

enum ImageImport {
    /// Stores the image and makes a page that fits it within the notebook's page width.
    static func page(for image: UIImage, notebook: Notebook, store: LibraryStore) -> Page? {
        let scaled = image.downscaled(maxSide: 2800)
        let hasAlpha: Bool = {
            guard let a = scaled.cgImage?.alphaInfo else { return false }
            return a == .first || a == .last || a == .premultipliedFirst || a == .premultipliedLast
        }()
        let data = hasAlpha ? scaled.pngData() : scaled.jpegData(compressionQuality: 0.88)
        guard let data, let file = try? store.addAsset(data, notebook: notebook.id, preferredName: "image", ext: hasAlpha ? "png" : "jpg") else {
            return nil
        }
        let base = notebook.settings.pageDimensions
        let aspect = Double(scaled.size.height / max(1, scaled.size.width))
        let width = aspect < 1 ? max(base.width, base.height) : min(base.width, base.height)
        return Page(size: PageDimensions(width: width, height: (width * aspect).rounded()), background: .image(file: file))
    }
}

/// Raw DEFLATE via Apple's Compression-backed `NSData` API (for ZIPs re-compressed by the Files app).
enum Inflate {
    static let raw: Zip.Inflater = { data, _ in
        try (data as NSData).decompressed(using: .zlib) as Data
    }
}

enum ExportFiles {
    /// A fresh folder in tmp for one export.
    static func newDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Export-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
