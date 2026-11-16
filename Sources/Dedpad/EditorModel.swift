import SwiftUI
import UIKit
import PencilKit
import PDFKit
import Observation
import DedpadCore

/// Editor state. Uses Observation, so each view refreshes only for the values it reads
/// (tapping a pen size redraws the tool bar, not the whole editor).
@Observable
@MainActor
final class EditorModel {
    /// The notebook. Views track `revision`, which changes on edits that affect what they show
    /// (not on every background save).
    var notebook: Notebook { _ = revision; return nb_ }
    @ObservationIgnored private var nb_: Notebook
    private(set) var revision = 0
    private(set) var currentIndex: Int = 0
    private(set) var thumbnails: [UUID: UIImage] = [:]
    private(set) var saveState: SaveState = .saved
    private(set) var zoomPercent: Int = 100
    private(set) var tool: EditorTool = .pen
    private(set) var toolSettings = ToolSettings.load()
    private(set) var rulerActive = false
    private(set) var hasTextSelection = false
    var deletedPage: DeletedPage?
    private(set) var indexingHandwriting = false

    enum SaveState { case saved, pending, failed }

    struct DeletedPage: Identifiable {
        let id = UUID()
        let page: Page
        let index: Int
        let drawing: PKDrawing
    }

    @ObservationIgnored let library: LibraryModel
    @ObservationIgnored let canvas = NotebookCanvasController()
    private var store: LibraryStore { library.store }

    // Drawings in page coordinates. Edited ones stay until saved; others are evicted (LRU).
    @ObservationIgnored private var drawings: [UUID: PKDrawing] = [:]
    @ObservationIgnored private var recentlyUsed: [UUID] = []
    @ObservationIgnored private let drawingCacheLimit = 24
    @ObservationIgnored private var dirtyDrawings = Set<UUID>()
    @ObservationIgnored private var metadataDirty = false
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var pendingThumbs = Set<UUID>()
    @ObservationIgnored private var thumbTask: Task<Void, Never>?
    @ObservationIgnored private var recognizeQueue: [UUID] = []
    @ObservationIgnored private var recognizeTask: Task<Void, Never>?
    @ObservationIgnored private var lastSnapshot: Date?
    @ObservationIgnored private var changedSinceSnapshot = false
    @ObservationIgnored private var toastTask: Task<Void, Never>?

    init(notebook: Notebook, library: LibraryModel) {
        var opened = notebook
        opened.markOpened()
        self.nb_ = opened
        self.library = library

        canvas.pageLookup = { [weak self] id in self?.nb_.pages.first { $0.id == id } }
        canvas.drawingForPage = { [weak self] id in
            guard let self, let p = self.nb_.pages.first(where: { $0.id == id }) else { return PKDrawing() }
            return self.drawing(for: p)
        }
        canvas.onDrawingChanged = { [weak self] id, d in self?.drawingChanged(id, d) }
        canvas.onPageChanged = { [weak self] id in self?.pageChanged(id) }
        canvas.onZoomChanged = { [weak self] in self?.zoomChanged() }
        canvas.onSelectionChanged = { [weak self] has in self?.hasTextSelection = has }
        canvas.onElementChanged = { [weak self] pid, e in self?.updateElement(e, page: pid) }
        canvas.onElementDeleted = { [weak self] pid, eid in self?.deleteElement(eid, page: pid) }
        canvas.onAddTextBox = { [weak self] pid, p in self?.addTextBox(page: pid, at: p) }
        canvas.darkPaper = { [weak self] id in
            guard let self, let p = self.nb_.pages.first(where: { $0.id == id }) else { return false }
            return self.isDarkPaper(p)
        }
        canvas.assetImage = { [weak self] file in
            guard let self else { return nil }
            return ImageCache.shared.image(at: self.store.assetURL(notebook: self.nb_.id, file: file))
        }
        canvas.setDrawingPolicy(UserDefaults.standard.string(forKey: AppPrefs.drawingPolicy) ?? "system")
        canvas.apply(tool: tool, settings: toolSettings)
        canvas.load(notebook: self.nb_, store: library.store, keepPosition: false)

        let id = nb_.id
        let store = library.store
        Task { [weak self] in
            let date = await Task.detached(priority: .background) { store.latestSnapshotDate(for: id) }.value
            self?.lastSnapshot = date
        }
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            self?.indexUnrecognisedPages()
        }
    }

    var currentPage: Page { nb_.pages[min(currentIndex, nb_.pages.count - 1)] }
    var pageCount: Int { nb_.pages.count }
    var hasPDFPages: Bool { nb_.pages.contains { if case .pdf = $0.background { return true } else { return false } } }

    func didAppear() {
        library.save(nb_)
        library.openNotebookID = nb_.id
    }

    // MARK: Drawings

    func drawing(for page: Page) -> PKDrawing {
        touchCache(page.id)
        if let d = drawings[page.id] { return d }
        let d = DrawingLoader.load(store: store, notebook: nb_.id, page: page)
        drawings[page.id] = d
        evictIfNeeded()
        return d
    }

    private func touchCache(_ id: UUID) {
        recentlyUsed.removeAll { $0 == id }
        recentlyUsed.append(id)
    }

    private func evictIfNeeded() {
        guard drawings.count > drawingCacheLimit else { return }
        let keep = currentPage.id
        for id in recentlyUsed where drawings.count > drawingCacheLimit {
            if !dirtyDrawings.contains(id) && id != keep {
                drawings[id] = nil
                recentlyUsed.removeAll { $0 == id }
            }
        }
    }

    private func isDarkPaper(_ page: Page) -> Bool {
        if case .paper = page.background { return nb_.paper(for: page).background.isDark }
        return false
    }

    private func drawingChanged(_ pageID: UUID, _ d: PKDrawing) {
        drawings[pageID] = d
        touchCache(pageID)
        dirtyDrawings.insert(pageID)
        changedSinceSnapshot = true
        if nb_.settings.mode == .continuous, !d.strokes.isEmpty,
           let i = nb_.pages.firstIndex(where: { $0.id == pageID }),
           nb_.growPageIfNeeded(at: i, contentBottom: Double(d.bounds.maxY)) {
            metadataDirty = true
            revision &+= 1
            reloadDocument(focus: pageID, keepPosition: true)
        }
        scheduleSave(delay: 1.5)
    }

    private func pageChanged(_ id: UUID) {
        if let i = nb_.pages.firstIndex(where: { $0.id == id }), i != currentIndex {
            currentIndex = i
        }
    }

    func zoomChanged() {
        let z = canvas.zoomPercent
        if z != zoomPercent { zoomPercent = z }
    }

    // MARK: Saving

    func scheduleSave(delay: Double = 0.8) {
        if saveState != .pending { saveState = .pending }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        saveTask?.cancel()
        let now = Date()
        let nbID = nb_.id
        let store = self.store
        var writes: [(Page, PKDrawing)] = []
        for id in dirtyDrawings {
            guard let i = nb_.pages.firstIndex(where: { $0.id == id }), let d = drawings[id] else { continue }
            nb_.pages[i].modifiedAt = now
            writes.append((nb_.pages[i], d))
        }
        let changed = dirtyDrawings
        dirtyDrawings.removeAll()
        if metadataDirty || !changed.isEmpty {
            nb_.touch(now)
            library.save(nb_)
            metadataDirty = false
        }
        if !writes.isEmpty {
            DiskWriter.shared.async { [weak self] in
                var failed = false
                for (page, d) in writes {
                    do {
                        try store.writeDrawing(d.dataRepresentation(), notebook: nbID, page: page)
                        let ink = InkConverter.inkPage(from: d, size: page.size)
                        try store.writeInk(try ink.encoded(), notebook: nbID, page: page)
                    } catch {
                        failed = true
                    }
                }
                Task { @MainActor in
                    let new: SaveState = failed ? .failed : .saved
                    if self?.saveState != new { self?.saveState = new }
                }
            }
        } else if saveState != .saved {
            saveState = .saved
        }
        for id in changed {
            requestThumbnail(id, force: true)
            queueRecognition(id)
        }
        snapshotIfDue()
    }

    /// Records a metadata change and saves soon.
    private func commit(_ change: (inout Notebook) -> Void) {
        change(&nb_)
        nb_.touch()
        revision &+= 1
        metadataDirty = true
        changedSinceSnapshot = true
        scheduleSave(delay: 0.3)
    }

    /// Automatic version every 20 minutes of editing.
    private func snapshotIfDue(force: Bool = false) {
        guard changedSinceSnapshot else { return }
        if !force, let last = lastSnapshot, Date().timeIntervalSince(last) < 20 * 60 { return }
        let nb = nb_
        let store = self.store
        lastSnapshot = Date()
        changedSinceSnapshot = false
        DiskWriter.shared.async { _ = try? store.makeSnapshot(of: nb) }
    }

    private func reloadDocument(focus: UUID? = nil, keepPosition: Bool = true) {
        canvas.load(notebook: nb_, store: store, keepPosition: keepPosition, focus: focus)
    }

    // MARK: Navigation

    func go(to index: Int) {
        guard nb_.pages.indices.contains(index) else { return }
        currentIndex = index
        canvas.go(to: nb_.pages[index].id)
    }

    func next() { go(to: currentIndex + 1) }
    func previous() { go(to: currentIndex - 1) }

    func fitWidth() { canvas.fitWidth(); zoomPercent = 100 }
    func fitPage() { canvas.fitPage(); zoomPercent = canvas.zoomPercent }

    // MARK: Tools

    func setTool(_ t: EditorTool) {
        guard t != tool else { return }
        tool = t
        canvas.apply(tool: t, settings: toolSettings)
        if t != .selectText { hasTextSelection = false }
    }

    func updateTools(_ change: (inout ToolSettings) -> Void) {
        change(&toolSettings)
        toolSettings.save()
        canvas.apply(tool: tool, settings: toolSettings)
    }

    func applyPreset(_ p: ToolPreset) {
        updateTools { s in
            s.setColor(p.color, for: p.tool)
            s.setWidth(p.width, for: p.tool)
            if p.tool == .pen { s.penInk = p.ink }
            if p.tool == .pencil { s.pencilInk = p.ink }
        }
        setTool(p.tool)
    }

    func saveCurrentPreset(name: String) {
        guard tool.isInking else { return }
        let ink = tool == .pen ? toolSettings.penInk : (tool == .pencil ? toolSettings.pencilInk : "marker")
        let p = ToolPreset(name: name.isEmpty ? tool.name : name, tool: tool, ink: ink,
                           color: toolSettings.color(for: tool), width: toolSettings.width(for: tool))
        updateTools { $0.presets.append(p) }
    }

    func toggleRuler() {
        rulerActive.toggle()
        canvas.setRuler(rulerActive)
    }

    func setDrawingPolicy(_ v: String) { canvas.setDrawingPolicy(v) }

    /// Erase all ink on the current page (undo brings it back).
    func clearCurrentPage() {
        let id = currentPage.id
        if !canvas.clearPage(id) {
            drawings[id] = PKDrawing()
            dirtyDrawings.insert(id)
            canvas.reloadDrawing(pageID: id)
            scheduleSave()
        }
    }
    func undo() { canvas.undo() }
    func redo() { canvas.redo() }

    // MARK: Page management

    func addPage(afterCurrent: Bool = true) {
        canvas.flushAll()
        var at = 0
        let after = afterCurrent ? currentIndex : nb_.pages.count - 1
        commit { at = $0.insertPage(after: after) }
        currentIndex = at
        reloadDocument(focus: nb_.pages[at].id, keepPosition: false)
    }

    func insertPage(after index: Int) {
        canvas.flushAll()
        var at = 0
        commit { at = $0.insertPage(after: index) }
        currentIndex = at
        reloadDocument(focus: nb_.pages[at].id, keepPosition: false)
    }

    func duplicatePage(at index: Int) {
        canvas.flushAll()
        saveNow()
        DiskWriter.shared.drain()
        var pair: (Page, Page)?
        commit { pair = $0.duplicatePage(at: index) }
        guard let pair else { return }
        let (old, new) = pair
        store.copyDrawing(notebook: nb_.id, from: old, to: new)
        drawings[new.id] = drawing(for: old)
        currentIndex = index + 1
        reloadDocument(focus: new.id, keepPosition: false)
    }

    func deletePage(at index: Int) {
        guard nb_.pages.indices.contains(index) else { return }
        canvas.flushAll()
        saveNow()
        DiskWriter.shared.drain()
        let page = nb_.pages[index]
        let ink = drawing(for: page)
        var removed: Page?
        commit { removed = $0.deletePage(at: index) }
        if let removed {
            store.deleteDrawing(notebook: nb_.id, page: removed)
            drawings[removed.id] = nil
            thumbnails[removed.id] = nil
        }
        if currentIndex > index { currentIndex -= 1 }
        currentIndex = max(0, min(currentIndex, nb_.pages.count - 1))
        reloadDocument(focus: nb_.pages[currentIndex].id, keepPosition: false)
        refreshAllThumbnails()
        showDeletedToast(DeletedPage(page: page, index: index, drawing: ink))
    }

    private func showDeletedToast(_ d: DeletedPage) {
        deletedPage = d
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard !Task.isCancelled else { return }
            self?.deletedPage = nil
        }
    }

    func undoDeletePage() {
        guard let d = deletedPage else { return }
        deletedPage = nil
        toastTask?.cancel()
        // A nb_ always keeps one page; drop the blank stand-in if that's all that's left.
        var dropBlank = false
        if nb_.pages.count == 1, let only = nb_.pages.first, only.id != d.page.id,
           drawing(for: only).strokes.isEmpty, only.elements.isEmpty, case .paper = only.background {
            dropBlank = true
        }
        commit { nb in
            if dropBlank { nb.pages.removeAll() }
            nb.pages.insert(d.page, at: min(d.index, nb.pages.count))
        }
        drawings[d.page.id] = d.drawing
        dirtyDrawings.insert(d.page.id)
        currentIndex = nb_.pages.firstIndex { $0.id == d.page.id } ?? 0
        saveNow()
        reloadDocument(focus: d.page.id, keepPosition: false)
        refreshAllThumbnails()
    }

    func movePage(from: Int, to: Int) {
        guard from != to, nb_.pages.indices.contains(from), nb_.pages.indices.contains(to) else { return }
        canvas.flushAll()
        let currentID = currentPage.id
        commit { $0.movePage(from: from, to: to) }
        currentIndex = nb_.pages.firstIndex { $0.id == currentID } ?? 0
        reloadDocument(focus: currentID, keepPosition: true)
        refreshAllThumbnails()
    }

    func movePage(id: UUID, before target: UUID) {
        guard let from = nb_.pages.firstIndex(where: { $0.id == id }),
              let to = nb_.pages.firstIndex(where: { $0.id == target }) else { return }
        movePage(from: from, to: to)
    }

    enum PaperScope: String, CaseIterable, Identifiable {
        case page, all, notebookDefault
        var id: String { rawValue }
        var name: String {
            switch self {
            case .page: return "This page"
            case .all: return "All pages"
            case .notebookDefault: return "New pages"
            }
        }
    }

    func applyPaper(_ paper: PaperSpec, scope: PaperScope) {
        canvas.flushAll()
        let id = currentPage.id
        switch scope {
        case .page:
            commit { $0.setPaper(paper, pages: [id]) }
        case .all:
            commit {
                $0.settings.paper = paper
                $0.setPaper(nil, pages: Set($0.pages.map(\.id)))
            }
        case .notebookDefault:
            commit { $0.settings.paper = paper }
            return
        }
        reloadDocument(focus: id, keepPosition: true)
        refreshAllThumbnails()
    }

    func setOrientation(_ o: PageOrientation, allPages: Bool) {
        canvas.flushAll()
        let id = currentPage.id
        commit { nb in nb.setOrientation(o, pages: allPages ? Set(nb.pages.map(\.id)) : [id]) }
        reloadDocument(focus: id, keepPosition: false)
        refreshAllThumbnails()
    }

    func setTypedNotes(_ text: String) {
        guard currentPage.typedNotes != text else { return }
        let i = currentIndex
        commit { $0.pages[i].typedNotes = text }
    }

    func toggleBookmark() {
        let i = currentIndex
        commit { $0.pages[i].isBookmarked.toggle() }
    }

    /// Changes from the customisation studio.
    func replaceNotebookSettings(with updated: Notebook) {
        canvas.flushAll()
        saveNow()
        nb_.title = updated.title
        nb_.details = updated.details
        nb_.categories = updated.categories
        nb_.folderID = updated.folderID
        nb_.cover = updated.cover
        let modeChanged = nb_.settings.mode != updated.settings.mode
        nb_.settings = updated.settings
        if modeChanged && updated.settings.mode == .fixed {
            for i in nb_.pages.indices {
                if case .paper = nb_.pages[i].background,
                   nb_.pages[i].size.height > updated.settings.pageDimensions.height {
                    let bottom = Double(drawing(for: nb_.pages[i]).bounds.maxY)
                    if bottom <= updated.settings.pageDimensions.height {
                        nb_.pages[i].size = updated.settings.pageDimensions
                    }
                }
            }
        }
        commit { _ in }
        reloadDocument(focus: currentPage.id, keepPosition: true)
        refreshAllThumbnails()
    }

    // MARK: Elements (text boxes, images, stickers)

    func addTextBox(page pageID: UUID, at p: CGPoint) {
        guard let i = nb_.pages.firstIndex(where: { $0.id == pageID }) else { return }
        let size = toolSettings.textSize
        let width = min(280, nb_.pages[i].size.width - Double(p.x) - 10)
        let e = PageElement(kind: .text, frame: PageRect(x: Double(p.x), y: Double(p.y) - size * 0.8, w: max(80, width), h: size * 1.5 + 12),
                            fontSize: size, color: toolSettings.textColor)
        commit { $0.pages[i].elements.append(e) }
        canvas.elementsChanged(pageID: pageID)
        canvas.beginEditing(element: e.id, pageID: pageID)
    }

    func updateElement(_ e: PageElement, page pageID: UUID) {
        guard let i = nb_.pages.firstIndex(where: { $0.id == pageID }),
              let j = nb_.pages[i].elements.firstIndex(where: { $0.id == e.id }) else { return }
        guard nb_.pages[i].elements[j] != e else { return }
        commit { $0.pages[i].elements[j] = e }
        requestThumbnail(pageID, force: true)
    }

    func deleteElement(_ id: UUID, page pageID: UUID) {
        guard let i = nb_.pages.firstIndex(where: { $0.id == pageID }) else { return }
        commit { $0.pages[i].elements.removeAll { $0.id == id } }
        canvas.elementsChanged(pageID: pageID)
        requestThumbnail(pageID, force: true)
    }

    /// Places an image or sticker in the middle of the current page.
    func insertElementImage(_ image: UIImage, sticker: Bool) {
        let scaled = image.downscaled(maxSide: sticker ? 512 : 2000)
        guard let data = scaled.pngData(),
              let file = try? store.addAsset(data, notebook: nb_.id, preferredName: sticker ? "sticker" : "image", ext: "png") else {
            library.show("Couldn't add the image", "The image could not be stored.")
            return
        }
        let i = currentIndex
        let page = nb_.pages[i]
        let w = sticker ? min(90, page.size.width * 0.18) : page.size.width * 0.5
        let aspect = Double(scaled.size.height / max(1, scaled.size.width))
        let h = w * aspect
        let e = PageElement(kind: sticker ? .sticker : .image,
                            frame: PageRect(x: (page.size.width - w) / 2, y: (page.size.height - h) / 3, w: w, h: h),
                            imageFile: file)
        commit { $0.pages[i].elements.append(e) }
        if tool != .text { setTool(.text) }
        canvas.elementsChanged(pageID: page.id)
        requestThumbnail(page.id, force: true)
    }

    // MARK: Highlights

    func highlightSelection(color: RGBA) {
        let parts = canvas.selectionRects()
        guard !parts.isEmpty else { return }
        for (pid, rects, text) in parts {
            guard let i = nb_.pages.firstIndex(where: { $0.id == pid }) else { continue }
            commit { $0.pages[i].highlights.append(PageHighlight(rects: rects, color: color, text: text)) }
            canvas.setHighlights(nb_.pages[i].highlights, pageID: pid, size: nb_.pages[i].size)
            requestThumbnail(pid, force: true)
        }
        canvas.clearSelection()
        hasTextSelection = false
    }

    func removeHighlightsInSelection() {
        for (pid, rects, _) in canvas.selectionRects() {
            guard let i = nb_.pages.firstIndex(where: { $0.id == pid }) else { continue }
            let sel = rects.map { CGRect(x: $0.x, y: $0.y, width: $0.w, height: $0.h) }
            commit { nb in
                nb.pages[i].highlights.removeAll { h in
                    h.rects.contains { r in sel.contains { $0.intersects(CGRect(x: r.x, y: r.y, width: r.w, height: r.h)) } }
                }
            }
            canvas.setHighlights(nb_.pages[i].highlights, pageID: pid, size: nb_.pages[i].size)
            requestThumbnail(pid, force: true)
        }
        canvas.clearSelection()
        hasTextSelection = false
    }

    // MARK: Inserting pages

    func insertPDF(from url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            guard let doc = PDFDocument(data: data), doc.pageCount > 0 else {
                library.show("Couldn't import", "The PDF is empty, damaged or password-protected.")
                return
            }
            canvas.flushAll()
            let file = try store.addAsset(data, notebook: nb_.id, preferredName: LibraryStore.safeFileName(url.deletingPathExtension().lastPathComponent), ext: "pdf")
            let pages = PDFImport.pages(for: doc, file: file)
            let at = min(currentIndex + 1, nb_.pages.count)
            commit { $0.pages.insert(contentsOf: pages, at: at) }
            currentIndex = at
            reloadDocument(focus: nb_.pages[at].id, keepPosition: false)
            refreshAllThumbnails()
        } catch {
            library.show("Couldn't import", error.localizedDescription)
        }
    }

    func insertImagePage(_ image: UIImage) {
        guard let page = ImageImport.page(for: image, notebook: nb_, store: store) else {
            library.show("Couldn't import", "The image could not be read.")
            return
        }
        canvas.flushAll()
        let at = min(currentIndex + 1, nb_.pages.count)
        commit { $0.pages.insert(page, at: at) }
        currentIndex = at
        reloadDocument(focus: page.id, keepPosition: false)
        refreshAllThumbnails()
    }

    func imageFromFile(_ url: URL) -> UIImage? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return UIImage(data: data)
    }

    // MARK: Thumbnails (rendered off the main thread)

    func requestThumbnail(_ id: UUID, force: Bool = false) {
        if !force, thumbnails[id] != nil { return }
        pendingThumbs.insert(id)
        guard thumbTask == nil else { return }
        thumbTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 80_000_000)
            while let self, let next = self.pendingThumbs.popFirst() {
                await self.renderThumbnail(next)
            }
            self?.thumbTask = nil
        }
    }

    private func renderThumbnail(_ id: UUID) async {
        guard let i = nb_.pages.firstIndex(where: { $0.id == id }) else { return }
        let page = nb_.pages[i]
        let nb = nb_
        let ink = drawing(for: page)
        let store = self.store
        let scale = min(1, 150 / CGFloat(page.size.width)) * 2
        let image = await Task.detached(priority: .utility) {
            PageRenderer.pageImage(page: page, notebook: nb, number: i + 1, drawing: ink, store: store, scale: scale)
        }.value
        thumbnails[id] = image
    }

    func refreshAllThumbnails() {
        for p in nb_.pages where thumbnails[p.id] != nil { requestThumbnail(p.id, force: true) }
    }

    // MARK: Handwriting recognition

    private func queueRecognition(_ id: UUID) {
        recognizeQueue.removeAll { $0 == id }
        recognizeQueue.append(id)
        guard recognizeTask == nil else { return }
        recognizeTask = Task { [weak self] in
            // Wait for a pause in writing.
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            await self?.runRecognition()
        }
    }

    private func runRecognition() async {
        indexingHandwriting = true
        while !recognizeQueue.isEmpty {
            let id = recognizeQueue.removeFirst()
            guard let page = nb_.pages.first(where: { $0.id == id }) else { continue }
            let text = await HandwritingRecognizer.recognize(drawing(for: page), size: page.size)
            if let i = nb_.pages.firstIndex(where: { $0.id == id }), nb_.pages[i].recognizedText != text {
                nb_.pages[i].recognizedText = text
                metadataDirty = true
                scheduleSave(delay: 1)
            }
        }
        indexingHandwriting = false
        recognizeTask = nil
    }

    /// Indexes pages written before recognition existed.
    private func indexUnrecognisedPages() {
        for p in nb_.pages where p.recognizedText.isEmpty {
            if store.readDrawing(notebook: nb_.id, page: p) != nil { queueRecognition(p.id) }
        }
    }

    // MARK: Search & contents

    func search(_ query: String) -> [EditorSearchResult] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard q.count >= 2 else { return [] }
        var out: [EditorSearchResult] = []
        if hasPDFPages {
            var files: [String] = []
            for p in nb_.pages {
                if case let .pdf(file, _) = p.background, !files.contains(file) { files.append(file) }
            }
            for file in files {
                guard let doc = PDFCache.shared.document(at: store.assetURL(notebook: nb_.id, file: file)) else { continue }
                for sel in doc.findString(q, withOptions: [.caseInsensitive, .diacriticInsensitive]).prefix(200) {
                    guard let page = sel.pages.first else { continue }
                    let original = doc.index(for: page)
                    guard let idx = nb_.pages.firstIndex(where: {
                        if case let .pdf(f, i) = $0.background { return f == file && i == original }
                        return false
                    }) else { continue }
                    let ext = sel.copy() as? PDFSelection
                    ext?.extend(atStart: 30)
                    ext?.extend(atEnd: 30)
                    let snippet = (ext?.string ?? sel.string ?? q).replacingOccurrences(of: "\n", with: " ")
                    out.append(EditorSearchResult(pageIndex: idx, snippet: snippet, source: "PDF", selection: sel))
                }
            }
        }
        for hit in LibraryQuery.pageHits(in: nb_, query: q) {
            out.append(EditorSearchResult(pageIndex: hit.pageIndex, snippet: hit.snippet, source: hit.source, selection: nil))
        }
        return out.sorted { $0.pageIndex < $1.pageIndex }
    }

    func show(_ result: EditorSearchResult) {
        if let sel = result.selection {
            canvas.show(selection: sel, pageID: nb_.pages[result.pageIndex].id)
            currentIndex = result.pageIndex
        } else {
            go(to: result.pageIndex)
        }
    }

    /// Table of contents of imported PDFs, mapped to nb_ pages.
    func outline() -> [OutlineEntry] {
        var out: [OutlineEntry] = []
        var files: [String] = []
        for p in nb_.pages {
            if case let .pdf(file, _) = p.background, !files.contains(file) { files.append(file) }
        }
        for file in files {
            guard let doc = PDFCache.shared.document(at: store.assetURL(notebook: nb_.id, file: file)),
                  let root = doc.outlineRoot else { continue }
            collect(root, depth: 0, doc: doc, file: file, into: &out)
        }
        return out
    }

    private func collect(_ item: PDFOutline, depth: Int, doc: PDFDocument, file: String, into out: inout [OutlineEntry]) {
        for k in 0..<item.numberOfChildren {
            guard let child = item.child(at: k) else { continue }
            if let page = child.destination?.page {
                let original = doc.index(for: page)
                if let idx = nb_.pages.firstIndex(where: {
                    if case let .pdf(f, i) = $0.background { return f == file && i == original }
                    return false
                }) {
                    out.append(OutlineEntry(title: child.label ?? "Untitled", depth: depth, pageIndex: idx))
                }
            }
            if depth < 4 { collect(child, depth: depth + 1, doc: doc, file: file, into: &out) }
        }
    }

    // MARK: Version history

    func snapshots() -> [SnapshotInfo] { store.snapshots(for: nb_.id) }

    func saveVersionNow() {
        changedSinceSnapshot = true
        canvas.flushAll()
        saveNow()
        snapshotIfDue(force: true)
    }

    // MARK: Export support

    /// Saves everything and waits for the disk, so exporters can read the files.
    func prepareForExport() -> Notebook {
        canvas.flushAll()
        saveNow()
        DiskWriter.shared.drain()
        return nb_
    }

    func close() {
        canvas.flushAll()
        saveNow()
        snapshotIfDue()
        DiskWriter.shared.drain()
        store.pruneAssets(of: nb_)
        library.openNotebookID = nil
        library.noteEdited(nb_.id)
        PDFCache.shared.clear()
    }
}
