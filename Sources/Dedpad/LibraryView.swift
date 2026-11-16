import SwiftUI
import UniformTypeIdentifiers
import DedpadCore

struct OpenRequest: Identifiable, Hashable { let id: UUID }

enum StudioRequest: Identifiable {
    case create(folder: UUID?)
    case edit(UUID)
    var id: String {
        switch self {
        case .create: return "create"
        case let .edit(id): return id.uuidString
        }
    }
}

struct LibraryView: View {
    @EnvironmentObject private var library: LibraryModel
    @EnvironmentObject private var auth: GoogleAuth
    @EnvironmentObject private var backup: DriveBackup
    @State private var selection: LibraryFilter? = .all
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var open: OpenRequest?
    @State private var studio: StudioRequest?
    @State private var showSettings = false
    @State private var showImporter = false

    @State private var newFolderName = ""
    @State private var showNewFolder = false
    @State private var renamingFolder: Folder?
    @State private var folderRenameText = ""
    @State private var deletingFolder: Folder?

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
                .navigationSplitViewColumnWidth(min: 240, ideal: 260, max: 320)
        } detail: {
            NavigationStack {
                ShelfView(
                    filter: selection ?? .all,
                    open: { open = OpenRequest(id: $0) },
                    studio: { studio = $0 },
                    showImporter: $showImporter
                )
            }
        }
        .navigationSplitViewStyle(.balanced)
        .fullScreenCover(item: $open) { req in
            EditorScreen(notebookID: req.id)
                .environmentObject(library)
        }
        .sheet(item: $studio) { req in
            StudioView(request: req) { createdID in
                // Wait for the sheet to finish dismissing before presenting the editor.
                if let createdID {
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 450_000_000)
                        open = OpenRequest(id: createdID)
                    }
                }
            }
            .environmentObject(library)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView().environmentObject(library).environmentObject(auth).environmentObject(backup)
        }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.pdf, .image, .zip, .json],
            allowsMultipleSelection: true
        ) { result in
            guard case let .success(urls) = result else { return }
            let folder: UUID? = { if case let .folder(id) = selection { return id } else { return nil } }()
            let created = library.importFiles(urls, folder: folder)
            if created.count == 1 { open = OpenRequest(id: created[0].id) }
        }
        .alert(item: $library.alert) { a in
            Alert(title: Text(a.title), message: Text(a.message), dismissButton: .default(Text("OK")))
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        List(selection: $selection) {
            Section {
                row("All notebooks", "books.vertical", .all, count: LibraryQuery.apply(library.notebooks, filter: .all).count)
                row("Recent", "clock", .recent)
                row("Favourites", "star", .favorites, count: LibraryQuery.apply(library.notebooks, filter: .favorites).count)
                row("Unfiled", "tray", .unfiled, count: LibraryQuery.apply(library.notebooks, filter: .unfiled).count)
            } header: { sectionHeader("Library") }

            Section {
                if library.index.folders.isEmpty {
                    Text("Folders keep subjects and projects apart.")
                        .font(DedFont.sans(12))
                        .foregroundStyle(Ded.muted)
                        .listRowBackground(Color.clear)
                }
                ForEach(library.index.folders) { folder in
                    row(folder.name, "folder", .folder(folder.id), count: LibraryQuery.apply(library.notebooks, filter: .folder(folder.id)).count)
                        .contextMenu {
                            Button { folderRenameText = folder.name; renamingFolder = folder } label: { Label("Rename", systemImage: "pencil") }
                            Button(role: .destructive) { deletingFolder = folder } label: { Label("Delete folder", systemImage: "trash") }
                        }
                }
                .onMove { library.moveFolders(from: $0, to: $1) }
            } header: {
                HStack {
                    sectionHeader("Folders")
                    Spacer()
                    Button { newFolderName = ""; showNewFolder = true } label: {
                        Image(systemName: "plus").font(.system(size: 13, weight: .semibold)).foregroundStyle(Ded.muted)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("New folder")
                }
            }

            let categories = LibraryQuery.categories(in: library.notebooks)
            if !categories.isEmpty {
                Section {
                    ForEach(categories, id: \.self) { c in
                        row(c, "number", .category(c))
                    }
                } header: { sectionHeader("Categories") }
            }

            Section {
                row("Archive", "archivebox", .archived, count: LibraryQuery.apply(library.notebooks, filter: .archived).count)
                row("Recently Deleted", "trash", .trash, count: LibraryQuery.apply(library.notebooks, filter: .trash).count)
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(Ded.sidebar)
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 18) {
                BrandLockup()
                Button { studio = .create(folder: currentFolder) } label: {
                    HStack(spacing: 9) {
                        Image(systemName: "plus")
                        Text("New notebook")
                        Spacer()
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(PrimaryButtonStyle())
            }
            .padding(.horizontal, 18)
            .padding(.top, 14)
            .padding(.bottom, 8)
            .background(Ded.sidebar)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack {
                Button { showSettings = true } label: {
                    Label("Settings", systemImage: "gearshape")
                        .font(DedFont.sans(13, .medium))
                        .foregroundStyle(Ded.muted)
                }
                .buttonStyle(.plain)
                Spacer()
                BackupStatusLabel()
                    .font(DedFont.sans(11))
                    .foregroundStyle(Ded.faint)
                    .lineLimit(1)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(Ded.sidebar)
            .overlay(alignment: .top) { Rectangle().fill(Ded.line).frame(height: 1) }
        }
        .alert("New folder", isPresented: $showNewFolder) {
            TextField("Name", text: $newFolderName)
            Button("Cancel", role: .cancel) {}
            Button("Create") {
                let f = library.addFolder(newFolderName)
                selection = .folder(f.id)
            }
        }
        .alert("Rename folder", isPresented: Binding(get: { renamingFolder != nil }, set: { if !$0 { renamingFolder = nil } })) {
            TextField("Name", text: $folderRenameText)
            Button("Cancel", role: .cancel) { renamingFolder = nil }
            Button("Save") {
                if let f = renamingFolder { library.renameFolder(f.id, folderRenameText) }
                renamingFolder = nil
            }
        }
        .confirmationDialog(
            "Delete “\(deletingFolder?.name ?? "")”?",
            isPresented: Binding(get: { deletingFolder != nil }, set: { if !$0 { deletingFolder = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete folder", role: .destructive) {
                if let f = deletingFolder {
                    if selection == .folder(f.id) { selection = .all }
                    library.deleteFolder(f.id)
                }
                deletingFolder = nil
            }
        } message: {
            Text("The notebooks inside are kept and moved to Unfiled.")
        }
    }

    private var currentFolder: UUID? {
        if case let .folder(id) = selection { return id }
        return nil
    }

    private func sectionHeader(_ s: String) -> some View {
        Text(s.uppercased())
            .font(DedFont.sans(10.5, .bold))
            .tracking(1.3)
            .foregroundStyle(Ded.muted)
    }

    private func row(_ title: String, _ icon: String, _ filter: LibraryFilter, count: Int? = nil) -> some View {
        Label {
            HStack {
                Text(title).font(DedFont.sans(14)).lineLimit(1)
                Spacer()
                if let count, count > 0 {
                    Text("\(count)").font(DedFont.sans(11.5)).monospacedDigit().foregroundStyle(Ded.faint)
                }
            }
        } icon: {
            Image(systemName: icon).foregroundStyle(Ded.accent)
        }
        .tag(filter)
    }
}

// MARK: - Shelf

struct ShelfView: View {
    @EnvironmentObject private var library: LibraryModel
    let filter: LibraryFilter
    let open: (UUID) -> Void
    let studio: (StudioRequest) -> Void
    @Binding var showImporter: Bool

    @State private var search = ""
    @AppStorage(AppPrefs.sort) private var sortRaw = NotebookSort.modified.rawValue
    @AppStorage(AppPrefs.sortAscending) private var ascending = false
    @State private var renaming: Notebook?
    @State private var renameText = ""
    @State private var deleting: Notebook?
    @State private var share: ShareItem?
    @State private var history: Notebook?
    @State private var confirmEmptyTrash = false

    private var sort: NotebookSort { NotebookSort(rawValue: sortRaw) ?? .modified }

    /// Computed once per change instead of on every access during a redraw.
    @State private var items: [Notebook] = []

    private func refreshItems() {
        items = LibraryQuery.apply(library.notebooks, filter: filter, search: search, sort: sort, ascending: ascending)
    }

    private var recents: [Notebook] {
        Array(LibraryQuery.apply(library.notebooks, filter: .recent).prefix(6))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                header

                if filter == .all, search.isEmpty, recents.count > 1 {
                    VStack(alignment: .leading, spacing: 14) {
                        Eyebrow(text: "Continue writing")
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(alignment: .bottom, spacing: 22) {
                                ForEach(recents) { nb in
                                    Button { open(nb.id) } label: {
                                        VStack(alignment: .leading, spacing: 8) {
                                            CoverView(design: nb.cover, title: nb.displayTitle, image: library.coverImage(for: nb), aspect: coverAspect(nb))
                                                .frame(height: 130)
                                            Text(nb.displayTitle).font(DedFont.sans(12, .semibold)).foregroundStyle(Ded.text).lineLimit(1)
                                                .frame(maxWidth: 110, alignment: .leading)
                                        }
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.vertical, 6)
                        }
                    }
                }

                if items.isEmpty {
                    emptyState
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 200), spacing: 30, alignment: .top)], alignment: .leading, spacing: 34) {
                        if filter != .archived && filter != .recent && filter != .trash && search.isEmpty {
                            NewNotebookTile { studio(.create(folder: folderID)) }
                        }
                        ForEach(items) { nb in
                            NotebookCard(notebook: nb, image: library.coverImage(for: nb), aspect: coverAspect(nb),
                                         matchedInPages: LibraryQuery.matchesOnlyInPages(nb, search)) {
                                if nb.isDeleted { library.restoreFromTrash(nb.id) } else { open(nb.id) }
                            }
                                .contextMenu { menu(for: nb) }
                        }
                    }
                }
            }
            .padding(.horizontal, 34)
            .padding(.vertical, 26)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Ded.bg)
        .searchable(text: $search, prompt: "Search notebooks")
        .onAppear(perform: refreshItems)
        .onChange(of: library.notebooks) { _, _ in refreshItems() }
        .onChange(of: filter) { _, _ in refreshItems() }
        .onChange(of: search) { _, _ in refreshItems() }
        .onChange(of: sortRaw) { _, _ in refreshItems() }
        .onChange(of: ascending) { _, _ in refreshItems() }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Menu {
                    Picker("Sort by", selection: $sortRaw) {
                        ForEach(NotebookSort.allCases) { Text($0.name).tag($0.rawValue) }
                    }
                    Divider()
                    Toggle(isOn: $ascending) {
                        Label(sort == .name ? "Z to A" : "Oldest first", systemImage: "arrow.up.arrow.down")
                    }
                } label: {
                    Label("Sort", systemImage: "line.3.horizontal.decrease.circle")
                }
                if filter == .trash {
                    Button(role: .destructive) { confirmEmptyTrash = true } label: { Label("Empty", systemImage: "trash.slash") }
                        .disabled(items.isEmpty)
                } else {
                    Button { showImporter = true } label: { Label("Import", systemImage: "square.and.arrow.down") }
                    Button { studio(.create(folder: folderID)) } label: { Label("New notebook", systemImage: "plus") }
                }
            }
        }
        .toolbarBackground(Ded.bg, for: .navigationBar)
        .alert("Rename notebook", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Title", text: $renameText)
            Button("Cancel", role: .cancel) { renaming = nil }
            Button("Save") {
                if let nb = renaming { library.rename(nb.id, to: renameText) }
                renaming = nil
            }
        }
        .confirmationDialog(
            "Delete “\(deleting?.displayTitle ?? "")”?",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete permanently", role: .destructive) {
                if let nb = deleting { library.deletePermanently(nb.id) }
                deleting = nil
            }
        } message: {
            Text("All pages, handwriting and imported files in this notebook are removed from this iPad. This can't be undone.")
        }
        .confirmationDialog("Empty Recently Deleted?", isPresented: $confirmEmptyTrash, titleVisibility: .visible) {
            Button("Delete \(items.count) notebook\(items.count == 1 ? "" : "s") permanently", role: .destructive) { library.emptyTrash() }
        } message: {
            Text("This can't be undone.")
        }
        .sheet(item: $history) { nb in
            VersionHistoryView(notebookID: nb.id, onSaveNow: nil, snapshots: { library.store.snapshots(for: nb.id) })
                .environmentObject(library)
        }
        .sheet(item: $share) { item in ShareSheet(items: item.urls) }
    }

    private var folderID: UUID? {
        if case let .folder(id) = filter { return id }
        return nil
    }

    private var title: String {
        switch filter {
        case .all: return "All notebooks"
        case .recent: return "Recent"
        case .favorites: return "Favourites"
        case .unfiled: return "Unfiled"
        case let .folder(id): return library.folderName(id) ?? "Folder"
        case let .category(c): return c
        case .archived: return "Archive"
        case .trash: return "Recently Deleted"
        }
    }

    private var eyebrow: String {
        switch filter {
        case .folder: return "Folder"
        case .category: return "Category"
        case .archived: return "Put away"
        case .trash: return "Kept for \(LibraryQuery.trashDays) days"
        default: return "Your notebooks"
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Eyebrow(text: eyebrow)
            Text(title)
                .font(DedFont.display(32, .bold))
                .tracking(-1.2)
                .foregroundStyle(Ded.text)
            Text(items.count == 1 ? "1 notebook" : "\(items.count) notebooks")
                .font(DedFont.sans(13))
                .foregroundStyle(Ded.muted)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 18) {
            if !search.isEmpty {
                Text("Nothing matches “\(search)”.").font(DedFont.sans(14)).foregroundStyle(Ded.muted)
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 8).fill(Ded.paperBack).frame(width: 96, height: 120).rotationEffect(.degrees(9)).offset(x: 12)
                    RoundedRectangle(cornerRadius: 8).fill(Ded.panel).frame(width: 96, height: 120)
                        .overlay(
                            VStack(alignment: .leading, spacing: 9) {
                                Capsule().fill(Ded.accent.opacity(0.35)).frame(height: 5)
                                Capsule().fill(Ded.line).frame(width: 52, height: 5)
                                Capsule().fill(Ded.line).frame(height: 5)
                                Capsule().fill(Ded.line).frame(width: 40, height: 5)
                            }.padding(18)
                        )
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Ded.line))
                        .rotationEffect(.degrees(-5))
                }
                .shadow(color: .black.opacity(0.06), radius: 14, y: 10)
                .padding(.bottom, 8)
                (Text("Your notebooks. ").font(DedFont.display(30, .medium)) + Text("Your pages.").font(DedFont.mark(31)).foregroundColor(Ded.accent))
                    .tracking(-1)
                    .foregroundStyle(Ded.text)
                Text(filter == .trash ? "Deleted notebooks stay here for \(LibraryQuery.trashDays) days, then they're removed."
                     : filter == .archived ? "Archived notebooks show up here." : "Create a notebook, or import a PDF to annotate.")
                    .font(DedFont.sans(14))
                    .foregroundStyle(Ded.muted)
                if filter != .archived && filter != .trash {
                    HStack(spacing: 12) {
                        Button { studio(.create(folder: folderID)) } label: { Label("New notebook", systemImage: "plus") }
                            .buttonStyle(PrimaryButtonStyle())
                        Button { showImporter = true } label: { Label("Import PDF", systemImage: "square.and.arrow.down") }
                            .buttonStyle(SecondaryButtonStyle())
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }

    @ViewBuilder
    private func menu(for nb: Notebook) -> some View {
        if nb.isDeleted {
            Button { library.restoreFromTrash(nb.id) } label: { Label("Restore", systemImage: "arrow.uturn.backward") }
            Button(role: .destructive) { deleting = nb } label: { Label("Delete permanently", systemImage: "trash") }
        } else {
            liveMenu(for: nb)
        }
    }

    @ViewBuilder
    private func liveMenu(for nb: Notebook) -> some View {
        Button { open(nb.id) } label: { Label("Open", systemImage: "book") }
        Button { renameText = nb.title; renaming = nb } label: { Label("Rename", systemImage: "pencil") }
        Button { studio(.edit(nb.id)) } label: { Label("Customise", systemImage: "paintpalette") }
        Button { library.toggleFavorite(nb.id) } label: {
            Label(nb.isFavorite ? "Remove from favourites" : "Add to favourites", systemImage: nb.isFavorite ? "star.slash" : "star")
        }
        Button { library.duplicate(nb.id) } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
        Menu {
            Button { library.move(nb.id, to: nil) } label: { Label("Unfiled", systemImage: nb.folderID == nil ? "checkmark" : "tray") }
            ForEach(library.index.folders) { f in
                Button { library.move(nb.id, to: f.id) } label: { Label(f.name, systemImage: nb.folderID == f.id ? "checkmark" : "folder") }
            }
        } label: { Label("Move to folder", systemImage: "folder") }
        Button {
            let store = library.store
            Task {
                if let url = try? await Exporter.export(notebook: nb, options: ExportOptions(format: .zip), store: store, coverImage: nil).first {
                    share = ShareItem(urls: [url])
                }
            }
        } label: { Label("Export archive", systemImage: "square.and.arrow.up") }
        Button { history = nb } label: { Label("Version history", systemImage: "clock.arrow.circlepath") }
        Divider()
        Button { library.setArchived(nb.id, !nb.isArchived) } label: {
            Label(nb.isArchived ? "Restore from archive" : "Archive", systemImage: nb.isArchived ? "arrow.uturn.backward" : "archivebox")
        }
        Button(role: .destructive) { library.delete(nb.id) } label: { Label("Delete", systemImage: "trash") }
    }

    private func coverAspect(_ nb: Notebook) -> CGFloat {
        let d = nb.settings.pageDimensions
        return CGFloat(min(1.25, max(0.6, d.width / d.height)))
    }
}

struct NotebookCard: View {
    let notebook: Notebook
    let image: UIImage?
    let aspect: CGFloat
    var matchedInPages = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                CoverView(design: notebook.cover, title: notebook.displayTitle, image: image, aspect: aspect)
                    .overlay(alignment: .topTrailing) {
                        if notebook.isFavorite {
                            Image(systemName: "star.fill")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(6)
                                .background(Circle().fill(Color.black.opacity(0.25)))
                                .padding(8)
                        }
                    }
                VStack(alignment: .leading, spacing: 3) {
                    Text(notebook.displayTitle)
                        .font(DedFont.sans(14, .semibold))
                        .foregroundStyle(Ded.text)
                        .lineLimit(2)
                    Text(subtitle)
                        .font(DedFont.sans(11.5))
                        .foregroundStyle(Ded.muted)
                        .lineLimit(1)
                    if matchedInPages {
                        Label("Found in pages", systemImage: "text.magnifyingglass")
                            .font(DedFont.sans(11, .semibold))
                            .foregroundStyle(Ded.accent)
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(CardPressStyle())
        .opacity(notebook.isDeleted ? 0.7 : 1)
        .accessibilityLabel("\(notebook.displayTitle), \(notebook.pages.count) pages")
    }

    private var subtitle: String {
        if let d = notebook.deletedAt {
            let left = max(0, LibraryQuery.trashDays - (Calendar.current.dateComponents([.day], from: d, to: Date()).day ?? 0))
            return "\(left) day\(left == 1 ? "" : "s") left · tap to restore"
        }
        return "\(notebook.pages.count) page\(notebook.pages.count == 1 ? "" : "s") · \(notebook.modifiedAt.formatted(.relative(presentation: .named)))"
    }
}

struct CardPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

struct NewNotebookTile: View {
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Ded.selectedLine, style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Ded.accentPale.opacity(0.45)))
                    .aspectRatio(0.707, contentMode: .fit)
                    .overlay(
                        VStack(spacing: 10) {
                            Image(systemName: "plus")
                                .font(.system(size: 22, weight: .medium))
                                .foregroundStyle(Ded.accent)
                            Text("New notebook").font(DedFont.sans(13, .semibold)).foregroundStyle(Ded.accentDark)
                        }
                    )
                Text(" ").font(DedFont.sans(14))
            }
        }
        .buttonStyle(CardPressStyle())
    }
}
