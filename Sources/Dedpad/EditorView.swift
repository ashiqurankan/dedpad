import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import DedpadCore

/// Looks the notebook up and hosts the editor.
struct EditorScreen: View {
    @EnvironmentObject private var library: LibraryModel
    @Environment(\.dismiss) private var dismiss
    let notebookID: UUID
    /// Created once; the editor must not be rebuilt when the library publishes changes.
    @State private var model: EditorModel?

    var body: some View {
        if let model {
            EditorView(model: model)
                .alert(item: $library.alert) { a in
                    Alert(title: Text(a.title), message: Text(a.message), dismissButton: .default(Text("OK")))
                }
        } else if let nb = library.notebook(notebookID) {
            Ded.bg.ignoresSafeArea()
                .onAppear { if model == nil { model = EditorModel(notebook: nb, library: library) } }
        } else {
            VStack(spacing: 16) {
                Text("This notebook is no longer available.").font(DedFont.sans(15)).foregroundStyle(Ded.muted)
                Button("Back to library") { dismiss() }.buttonStyle(PrimaryButtonStyle())
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Ded.bg)
        }
    }
}

struct EditorView: View {
    let model: EditorModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    @AppStorage(AppPrefs.drawingPolicy) private var drawingPolicy = "system"
    @AppStorage("editor.showSidebar") private var showSidebar = true
    @AppStorage("editor.showNotes") private var showNotes = false

    @State private var sheet: EditorSheet?
    @State private var importKind: ImportKind?
    @State private var showPhotoPicker = false
    @State private var photoItem: PhotosPickerItem?
    @State private var photoTarget: ImportKind = .imagePage
    @State private var deletingPage: Int?

    enum EditorSheet: String, Identifiable {
        case paper, export, studio, stickers, history
        var id: String { rawValue }
    }

    enum ImportKind { case pdf, imagePage, imageElement }

    @AppStorage("editor.horizontal") private var horizontal = false

    var body: some View {
        VStack(spacing: 0) {
            topBar
            ToolStrip(
                model: model,
                onInsertImage: { photoTarget = .imageElement; showPhotoPicker = true },
                onSticker: { sheet = .stickers }
            )
            .background(Ded.panel)
            .overlay(alignment: .bottom) { Rectangle().fill(Ded.line).frame(height: 1) }
            HStack(spacing: 0) {
                if showSidebar {
                    EditorSidebar(model: model, onDelete: { deletingPage = $0 })
                        .frame(width: 236)
                        .background(Ded.sidebar)
                        .transition(.move(edge: .leading))
                    Rectangle().fill(Ded.line).frame(width: 1)
                }
                ZStack(alignment: .bottom) {
                    NotebookCanvasRepresentable(controller: model.canvas)
                        .ignoresSafeArea(.container, edges: .bottom)
                    if let d = model.deletedPage {
                        undoToast(d).padding(.bottom, 18)
                    }
                }
                .overlay(alignment: .topTrailing) { pageNavigator.padding(14) }
                if showNotes {
                    Rectangle().fill(Ded.line).frame(width: 1)
                    NotesPanel(model: model)
                        .frame(width: 300)
                        .background(Ded.panel)
                        .transition(.move(edge: .trailing))
                }
            }
        }
        .background(Ded.bg)
        .animation(.easeInOut(duration: 0.2), value: showSidebar)
        .animation(.easeInOut(duration: 0.2), value: showNotes)
        .animation(.easeInOut(duration: 0.2), value: model.deletedPage?.id)
        .sheet(item: $sheet, onDismiss: { model.canvas.activate() }) { which in
            switch which {
            case .paper:
                PageStyleSheet(model: model).environmentObject(model.library)
            case .export:
                ExportCenter(model: model).environmentObject(model.library)
            case .studio:
                StudioView(request: .edit(model.notebook.id), source: model.notebook, onSave: { model.replaceNotebookSettings(with: $0) })
                    .environmentObject(model.library)
            case .stickers:
                StickerPicker { image in model.insertElementImage(image, sticker: true) }
            case .history:
                VersionHistoryView(notebookID: model.notebook.id, onSaveNow: { model.saveVersionNow() }, snapshots: { model.snapshots() })
                    .environmentObject(model.library)
            }
        }
        .fileImporter(
            isPresented: Binding(get: { importKind != nil }, set: { if !$0 { importKind = nil } }),
            allowedContentTypes: importKind == .pdf ? [.pdf] : [.image]
        ) { result in
            let kind = importKind
            importKind = nil
            guard case let .success(url) = result else { return }
            switch kind {
            case .pdf: model.insertPDF(from: url)
            case .imageElement: if let img = model.imageFromFile(url) { model.insertElementImage(img, sticker: false) }
            default: if let img = model.imageFromFile(url) { model.insertImagePage(img) }
            }
        }
        .photosPicker(isPresented: $showPhotoPicker, selection: $photoItem, matching: .images, preferredItemEncoding: .compatible)
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task {
                if let image = await PhotoLoader.load(item) {
                    if photoTarget == .imageElement { model.insertElementImage(image, sticker: false) } else { model.insertImagePage(image) }
                } else {
                    model.library.show("Couldn't load that photo", "Try another photo, or pick the image from Files.")
                }
                photoItem = nil
            }
        }
        .confirmationDialog(
            "Delete page \((deletingPage ?? 0) + 1)?",
            isPresented: Binding(get: { deletingPage != nil }, set: { if !$0 { deletingPage = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete page", role: .destructive) {
                if let i = deletingPage { model.deletePage(at: i) }
                deletingPage = nil
            }
        } message: {
            Text("You can undo this for a few seconds afterwards.")
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { model.saveNow() }
        }
        .onChange(of: drawingPolicy) { _, v in model.setDrawingPolicy(v) }
        .onAppear {
            model.didAppear()
            model.canvas.setHorizontal(horizontal)
        }
        .onChange(of: horizontal) { _, v in model.canvas.setHorizontal(v) }
    }

    // MARK: Toast

    private func undoToast(_ d: EditorModel.DeletedPage) -> some View {
        HStack(spacing: 14) {
            Image(systemName: "trash").foregroundStyle(Ded.muted)
            Text("Page \(d.index + 1) deleted").font(DedFont.sans(13.5, .medium)).foregroundStyle(Ded.text)
            Button("Undo") { model.undoDeletePage() }
                .font(DedFont.sans(13.5, .bold))
                .foregroundStyle(Ded.accent)
        }
        .padding(.horizontal, 18)
        .frame(height: 44)
        .background(Capsule().fill(Ded.panel))
        .overlay(Capsule().stroke(Ded.line))
        .shadow(color: .black.opacity(0.12), radius: 12, y: 5)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack(spacing: 4) {
            Button {
                model.close()
                dismiss()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left").font(.system(size: 15, weight: .semibold))
                    Text("Library").font(DedFont.sans(14, .medium))
                }
                .foregroundStyle(Ded.accent)
                .frame(height: 40)
                .padding(.horizontal, 8)
            }
            .buttonStyle(.plain)

            Button { showSidebar.toggle() } label: { Image(systemName: "sidebar.left") }
                .buttonStyle(IconButtonStyle(active: showSidebar))
                .accessibilityLabel("Sidebar")

            VStack(alignment: .leading, spacing: 1) {
                Text(model.notebook.displayTitle)
                    .font(DedFont.display(15, .bold))
                    .tracking(-0.3)
                    .foregroundStyle(Ded.text)
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Text("Page \(model.currentIndex + 1) of \(model.pageCount)")
                    Text("·")
                    saveIndicator
                }
                .font(DedFont.sans(11.5))
                .foregroundStyle(Ded.muted)
            }
            .padding(.leading, 4)

            Spacer(minLength: 8)

            Group {
                Button { model.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                    .buttonStyle(IconButtonStyle())
                    .accessibilityLabel("Undo")
                    .keyboardShortcut("z", modifiers: .command)
                Button { model.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                    .buttonStyle(IconButtonStyle())
                    .accessibilityLabel("Redo")
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                divider
                Button {
                    drawingPolicy = drawingPolicy == "any" ? "pencil" : "any"
                } label: { Image(systemName: drawingPolicy == "any" ? "hand.draw.fill" : "hand.draw") }
                    .buttonStyle(IconButtonStyle(active: drawingPolicy == "any"))
                    .accessibilityLabel(drawingPolicy == "any" ? "Finger drawing on" : "Finger drawing off")
                Button { model.toggleBookmark() } label: { Image(systemName: model.currentPage.isBookmarked ? "bookmark.fill" : "bookmark") }
                    .buttonStyle(IconButtonStyle(active: model.currentPage.isBookmarked))
                    .accessibilityLabel("Bookmark page")
                divider
            }
            Group {
                Menu {
                    Button { model.addPage(afterCurrent: true) } label: { Label("New page after this one", systemImage: "doc.badge.plus") }
                    Button { model.addPage(afterCurrent: false) } label: { Label("New page at the end", systemImage: "plus.rectangle.portrait") }
                    Button { model.duplicatePage(at: model.currentIndex) } label: { Label("Duplicate this page", systemImage: "plus.square.on.square") }
                    Divider()
                    Button { photoTarget = .imageElement; showPhotoPicker = true } label: { Label("Photo on this page…", systemImage: "photo") }
                    Button { importKind = .imageElement } label: { Label("Image from Files on this page…", systemImage: "photo.on.rectangle") }
                    Button { sheet = .stickers } label: { Label("Sticker…", systemImage: "face.smiling") }
                    Divider()
                    Button { importKind = .pdf } label: { Label("Insert PDF pages…", systemImage: "doc.richtext") }
                    Button { photoTarget = .imagePage; showPhotoPicker = true } label: { Label("Photo as a new page…", systemImage: "photo.badge.plus") }
                    Button { importKind = .imagePage } label: { Label("Image from Files as a new page…", systemImage: "folder") }
                    Divider()
                    Button(role: .destructive) { deletingPage = model.currentIndex } label: { Label("Delete this page", systemImage: "trash") }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 17))
                        .foregroundStyle(Ded.muted)
                        .frame(width: 40, height: 40)
                }
                .accessibilityLabel("Insert")

                Button { sheet = .paper } label: { Image(systemName: "squareshape.split.2x2.dotted") }
                    .buttonStyle(IconButtonStyle())
                    .accessibilityLabel("Paper")
                Button { showNotes.toggle() } label: { Image(systemName: "text.alignleft") }
                    .buttonStyle(IconButtonStyle(active: showNotes))
                    .accessibilityLabel("Typed notes")
                Button { sheet = .export } label: { Image(systemName: "square.and.arrow.up") }
                    .buttonStyle(IconButtonStyle())
                    .accessibilityLabel("Export")
                Menu {
                    Button { sheet = .studio } label: { Label("Customise notebook…", systemImage: "paintpalette") }
                    Button { sheet = .history } label: { Label("Version history…", systemImage: "clock.arrow.circlepath") }
                    Divider()
                    Picker("Page layout", selection: $horizontal) {
                        Label("Scroll vertically", systemImage: "arrow.up.and.down").tag(false)
                        Label("Turn pages sideways", systemImage: "book").tag(true)
                    }
                    Divider()
                    Button { model.fitWidth() } label: { Label("Fit width", systemImage: "arrow.left.and.right") }
                    Button { model.fitPage() } label: { Label("Fit page", systemImage: "rectangle.portrait") }
                    Divider()
                    Button { model.setOrientation(.portrait, allPages: false) } label: { Label("Portrait page", systemImage: "rectangle.portrait") }
                    Button { model.setOrientation(.landscape, allPages: false) } label: { Label("Landscape page", systemImage: "rectangle") }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 17))
                        .foregroundStyle(Ded.muted)
                        .frame(width: 40, height: 40)
                }
                .accessibilityLabel("More")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 52)
        .background(Ded.panel)
    }

    private var divider: some View {
        Rectangle().fill(Ded.line).frame(width: 1, height: 22).padding(.horizontal, 4)
    }

    @ViewBuilder
    private var saveIndicator: some View {
        switch model.saveState {
        case .saved: Text(model.indexingHandwriting ? "Saved · indexing" : "Saved")
        case .pending: Text("Saving…")
        case .failed: Text("Not saved").foregroundStyle(Ded.danger)
        }
    }

    // MARK: Page navigator

    private var pageNavigator: some View {
        HStack(spacing: 2) {
            Button { model.previous() } label: { Image(systemName: horizontal ? "chevron.left" : "chevron.up") }
                .buttonStyle(NavPillButton())
                .disabled(model.currentIndex == 0)
                .keyboardShortcut(.upArrow, modifiers: .command)
            Text("\(model.currentIndex + 1) / \(model.pageCount)")
                .font(DedFont.sans(12.5, .semibold))
                .monospacedDigit()
                .foregroundStyle(Ded.text)
                .frame(minWidth: 52)
            Button {
                if model.currentIndex == model.pageCount - 1 && model.notebook.settings.mode == .fixed {
                    model.addPage(afterCurrent: true)
                } else {
                    model.next()
                }
            } label: {
                Image(systemName: model.currentIndex == model.pageCount - 1 && model.notebook.settings.mode == .fixed ? "plus" : (horizontal ? "chevron.right" : "chevron.down"))
            }
            .buttonStyle(NavPillButton())
            .keyboardShortcut(.downArrow, modifiers: .command)
            if model.zoomPercent != 100 {
                Button { model.fitWidth() } label: {
                    Text("\(model.zoomPercent)%")
                        .font(DedFont.sans(11))
                        .monospacedDigit()
                        .foregroundStyle(Ded.muted)
                        .padding(.horizontal, 6)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Reset zoom")
            }
        }
        .padding(4)
        .background(Capsule().fill(Ded.panel.opacity(0.94)))
        .overlay(Capsule().stroke(Ded.line))
        .shadow(color: .black.opacity(0.08), radius: 10, y: 4)
    }
}

struct NavPillButton: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(enabled ? Ded.accentDark : Ded.faint)
            .frame(width: 34, height: 30)
            .background(Capsule().fill(configuration.isPressed ? Ded.accentPale : Color.clear))
            .contentShape(Capsule())
    }
}

// MARK: - Sidebar

struct EditorSidebar: View {
    let model: EditorModel
    let onDelete: (Int) -> Void
    @State private var tab: Tab = .pages

    enum Tab: String, CaseIterable, Identifiable {
        case pages, contents, search, bookmarks
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .pages: return "square.grid.2x2"
            case .contents: return "list.bullet.indent"
            case .search: return "magnifyingglass"
            case .bookmarks: return "bookmark"
            }
        }
        var name: String { rawValue.capitalized }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Sidebar", selection: $tab) {
                ForEach(Tab.allCases) { t in Image(systemName: t.symbol).tag(t).accessibilityLabel(t.name) }
            }
            .pickerStyle(.segmented)
            .padding(10)
            Divider()
            switch tab {
            case .pages: ThumbnailRail(model: model, onDelete: onDelete)
            case .contents: ContentsList(model: model)
            case .search: SearchPanel(model: model)
            case .bookmarks: BookmarksList(model: model)
            }
        }
    }
}

struct ThumbnailRail: View {
    let model: EditorModel
    let onDelete: (Int) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 18) {
                    ForEach(Array(model.notebook.pages.enumerated()), id: \.element.id) { i, page in
                        cell(i, page).id(page.id)
                    }
                    Button { model.addPage(afterCurrent: false) } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(Ded.accent)
                            .frame(width: 110, height: 56)
                            .background(RoundedRectangle(cornerRadius: 6).strokeBorder(Ded.selectedLine, style: StrokeStyle(lineWidth: 1.2, dash: [5, 4])))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Add page")
                }
                .padding(.vertical, 18)
                .frame(maxWidth: .infinity)
            }
            .onChange(of: model.currentIndex) { _, i in
                guard model.notebook.pages.indices.contains(i) else { return }
                withAnimation { proxy.scrollTo(model.notebook.pages[i].id, anchor: .center) }
            }
        }
    }

    private func cell(_ i: Int, _ page: Page) -> some View {
        let selected = i == model.currentIndex
        let aspect = CGFloat(page.size.width / max(1, page.size.height))
        return VStack(spacing: 6) {
            Group {
                if let img = model.thumbnails[page.id] {
                    Image(uiImage: img).resizable().aspectRatio(aspect, contentMode: .fit)
                } else {
                    Rectangle().fill(model.notebook.paper(for: page).background.color).aspectRatio(aspect, contentMode: .fit)
                }
            }
            .frame(width: 130)
            .frame(maxHeight: 220)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(selected ? Ded.accent : Ded.line, lineWidth: selected ? 2.5 : 1))
            .overlay(alignment: .topTrailing) {
                if page.isBookmarked {
                    Image(systemName: "bookmark.fill").font(.system(size: 12)).foregroundStyle(Ded.accent).padding(5)
                }
            }
            .shadow(color: .black.opacity(0.06), radius: 4, y: 2)
            Text("\(i + 1)")
                .font(DedFont.sans(11.5, selected ? .bold : .regular))
                .foregroundStyle(selected ? Ded.accentDark : Ded.muted)
        }
        .contentShape(Rectangle())
        .onTapGesture { model.go(to: i) }
        .onAppear { model.requestThumbnail(page.id) }
        .contextMenu {
            Button { model.insertPage(after: i) } label: { Label("Insert page after", systemImage: "doc.badge.plus") }
            Button { model.duplicatePage(at: i) } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
            Button { model.movePage(from: i, to: i - 1) } label: { Label("Move up", systemImage: "arrow.up") }
                .disabled(i == 0)
            Button { model.movePage(from: i, to: i + 1) } label: { Label("Move down", systemImage: "arrow.down") }
                .disabled(i == model.pageCount - 1)
            Divider()
            Button(role: .destructive) { onDelete(i) } label: { Label("Delete", systemImage: "trash") }
        }
        .draggable(page.id.uuidString)
        .dropDestination(for: String.self) { items, _ in
            guard let s = items.first, let id = UUID(uuidString: s), id != page.id else { return false }
            model.movePage(id: id, before: page.id)
            return true
        }
        .accessibilityLabel("Page \(i + 1)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct ContentsList: View {
    let model: EditorModel
    @State private var entries: [OutlineEntry] = []
    @State private var loaded = false

    var body: some View {
        Group {
            if entries.isEmpty {
                EmptyHint(text: loaded ? "No table of contents. Imported PDFs with chapters show them here." : "Loading…")
            } else {
                List(entries) { e in
                    Button { model.go(to: e.pageIndex) } label: {
                        HStack {
                            Text(e.title).font(DedFont.sans(13, e.depth == 0 ? .semibold : .regular)).foregroundStyle(Ded.text).lineLimit(2)
                            Spacer()
                            Text("\(e.pageIndex + 1)").font(DedFont.sans(11.5)).monospacedDigit().foregroundStyle(Ded.faint)
                        }
                        .padding(.leading, CGFloat(e.depth) * 12)
                    }
                    .listRowBackground(Color.clear)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .onAppear {
            entries = model.outline()
            loaded = true
        }
    }
}

struct SearchPanel: View {
    let model: EditorModel
    @State private var query = ""
    @State private var results: [EditorSearchResult] = []
    @State private var searchTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(Ded.faint)
                TextField("Search this notebook", text: $query)
                    .font(DedFont.sans(14))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Ded.faint) }.buttonStyle(.plain)
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 9).fill(Ded.panel))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Ded.line))
            .padding(10)
            if results.isEmpty {
                EmptyHint(text: query.count < 2 ? "Searches PDF text, typed notes, text boxes and your handwriting." : "No matches.")
            } else {
                List(results) { r in
                    Button { model.show(r) } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("Page \(r.pageIndex + 1)").font(DedFont.sans(12, .bold)).foregroundStyle(Ded.accentDark)
                                Text(r.source).font(DedFont.sans(11)).foregroundStyle(Ded.faint)
                            }
                            Text(r.snippet).font(DedFont.sans(12.5)).foregroundStyle(Ded.text).lineLimit(3)
                        }
                    }
                    .listRowBackground(Color.clear)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .onChange(of: query) { _, q in
            searchTask?.cancel()
            searchTask = Task {
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard !Task.isCancelled else { return }
                results = model.search(q)
            }
        }
    }
}

struct BookmarksList: View {
    let model: EditorModel

    var body: some View {
        let marked = model.notebook.pages.enumerated().filter { $0.element.isBookmarked }.map { ($0.offset, $0.element) }
        if marked.isEmpty {
            EmptyHint(text: "Tap the bookmark button in the top bar to mark pages you come back to.")
        } else {
            List(marked, id: \.1.id) { i, page in
                Button { model.go(to: i) } label: {
                    HStack(spacing: 12) {
                        if let img = model.thumbnails[page.id] {
                            Image(uiImage: img).resizable().scaledToFit().frame(width: 40, height: 52)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Page \(i + 1)").font(DedFont.sans(13, .semibold)).foregroundStyle(Ded.text)
                            let preview = page.searchableText.split(separator: "\n").first.map(String.init) ?? ""
                            if !preview.isEmpty { Text(preview).font(DedFont.sans(11.5)).foregroundStyle(Ded.muted).lineLimit(1) }
                        }
                    }
                }
                .onAppear { model.requestThumbnail(page.id) }
                .listRowBackground(Color.clear)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
    }
}

struct EmptyHint: View {
    let text: String
    var body: some View {
        VStack {
            Text(text)
                .font(DedFont.sans(12.5))
                .foregroundStyle(Ded.muted)
                .multilineTextAlignment(.center)
                .padding(20)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Typed notes

struct NotesPanel: View {
    let model: EditorModel
    @State private var text = ""
    @State private var pageID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Eyebrow(text: "Page \(model.currentIndex + 1) notes")
            Text("Typed text for this page. It's searchable and included in TXT and Markdown exports.")
                .font(DedFont.sans(12))
                .foregroundStyle(Ded.muted)
            TextEditor(text: $text)
                .font(DedFont.sans(14))
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 10).fill(Ded.bg))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Ded.line))
            if !model.currentPage.recognizedText.isEmpty {
                Eyebrow(text: "Recognised handwriting")
                ScrollView {
                    Text(model.currentPage.recognizedText)
                        .font(DedFont.sans(12.5))
                        .foregroundStyle(Ded.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 160)
            }
        }
        .padding(16)
        .onAppear { sync() }
        .onChange(of: model.currentIndex) { _, _ in sync() }
        .onChange(of: text) { _, t in
            if pageID == model.currentPage.id { model.setTypedNotes(t) }
        }
    }

    private func sync() {
        pageID = model.currentPage.id
        text = model.currentPage.typedNotes
    }
}

// MARK: - Stickers

struct StickerPicker: View {
    let onPick: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var color = DedPalette.brand

    private let colors: [RGBA] = [DedPalette.brand, RGBA(0x252722), RGBA(0xB0493E), RGBA(0xA8701C), RGBA(0x3F5873), RGBA(0x5B4F73), RGBA(0xC9776B)]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 4) {
                        ForEach(colors, id: \.self) { c in
                            Button { color = c } label: { Swatch(color: c, selected: c == color, size: 28) }.buttonStyle(.plain)
                        }
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 64), spacing: 14)], spacing: 14) {
                        ForEach(Stickers.symbols, id: \.self) { s in
                            Button {
                                if let img = Stickers.image(s, color: color.uiColor) { onPick(img) }
                                dismiss()
                            } label: {
                                Image(systemName: s)
                                    .font(.system(size: 30))
                                    .foregroundStyle(color.color)
                                    .frame(width: 64, height: 64)
                                    .background(RoundedRectangle(cornerRadius: 12).fill(Ded.panel))
                                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Ded.line))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(22)
            }
            .background(Ded.bg)
            .navigationTitle("Stickers")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: - Version history

struct VersionHistoryView: View {
    @EnvironmentObject private var library: LibraryModel
    @Environment(\.dismiss) private var dismiss
    let notebookID: UUID
    var onSaveNow: (() -> Void)?
    let snapshots: () -> [SnapshotInfo]
    @State private var items: [SnapshotInfo] = []
    @State private var restored: String?

    var body: some View {
        NavigationStack {
            List {
                if let onSaveNow {
                    Section {
                        Button {
                            onSaveNow()
                            Task {
                                try? await Task.sleep(nanoseconds: 600_000_000)
                                items = snapshots()
                            }
                        } label: { Label("Save a version now", systemImage: "plus.circle") }
                    }
                }
                Section {
                    if items.isEmpty {
                        Text("No versions yet.").foregroundStyle(Ded.muted)
                    }
                    ForEach(items) { s in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(s.date.formatted(date: .abbreviated, time: .shortened)).font(DedFont.sans(14, .semibold))
                                Text("\(s.pageCount) page\(s.pageCount == 1 ? "" : "s") · \(s.title)").font(DedFont.sans(12)).foregroundStyle(Ded.muted)
                            }
                            Spacer()
                            Button("Restore as copy") {
                                if let nb = library.restoreVersion(of: notebookID, snapshot: s.name) {
                                    restored = nb.displayTitle
                                }
                            }
                            .font(DedFont.sans(13, .semibold))
                        }
                    }
                } header: {
                    Text("Versions")
                } footer: {
                    Text("dedpad saves a version every 20 minutes while you write and keeps the last \(LibraryStore.snapshotLimit). Restoring makes a separate copy, so nothing is overwritten.")
                }
            }
            .scrollContentBackground(.hidden)
            .background(Ded.bg)
            .navigationTitle("Version history")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .alert("Version restored", isPresented: Binding(get: { restored != nil }, set: { if !$0 { restored = nil } })) {
                Button("OK") {}
            } message: {
                Text("“\(restored ?? "")” is now in your library.")
            }
            .onAppear { items = snapshots() }
        }
    }
}
