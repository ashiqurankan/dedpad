import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import DedpadCore

/// The Customisation Studio: cover, paper, page layout and notebook details.
struct StudioView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case cover, paper, layout, details
        var id: String { rawValue }
        var name: String {
            switch self {
            case .cover: return "Cover"
            case .paper: return "Paper"
            case .layout: return "Layout"
            case .details: return "Details"
            }
        }
    }

    @EnvironmentObject private var library: LibraryModel
    @Environment(\.dismiss) private var dismiss

    let request: StudioRequest
    /// Called with the new notebook's id after "Create" (nil otherwise).
    var onFinish: (UUID?) -> Void = { _ in }
    /// When editing from inside the editor, the editor applies the changes itself.
    var source: Notebook? = nil
    var onSave: ((Notebook) -> Void)? = nil

    @State private var draft = Notebook(title: "")
    @State private var loaded = false
    @State private var tab: Tab = .cover
    @State private var categoriesText = ""
    @State private var photoItem: PhotosPickerItem?
    @State private var showCoverFiles = false

    private var isCreating: Bool { if case .create = request { return true } else { return false } }

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                if geo.size.width > 640 {
                    HStack(spacing: 0) {
                        preview
                            .frame(width: min(320, geo.size.width * 0.38))
                            .frame(maxHeight: .infinity)
                            .background(Ded.sidebar)
                        Rectangle().fill(Ded.line).frame(width: 1)
                        form
                    }
                } else {
                    ScrollView {
                        VStack(spacing: 0) {
                            preview.padding(.bottom, 8)
                            formContent.padding(20)
                        }
                    }
                }
            }
            .background(Ded.bg)
            .navigationTitle(isCreating ? "New notebook" : "Customise")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { cancel() }
                }
                ToolbarItem(placement: .principal) {
                    Picker("Section", selection: $tab) {
                        ForEach(Tab.allCases) { Text($0.name).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 330)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isCreating ? "Create" : "Save") { save() }
                        .fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.large])
        .onAppear(perform: load)
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task {
                if let image = await PhotoLoader.load(item) {
                    setCoverImage(image)
                } else {
                    library.show("Couldn't load that photo", "Try another photo, or pick the image from Files.")
                }
                photoItem = nil
            }
        }
        .fileImporter(isPresented: $showCoverFiles, allowedContentTypes: [.image]) { result in
            guard case let .success(url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            if let data = try? Data(contentsOf: url), let image = UIImage(data: data) { setCoverImage(image) }
        }
    }

    // MARK: Loading / saving

    private func load() {
        guard !loaded else { return }
        loaded = true
        switch request {
        case let .create(folder):
            draft = Notebook(title: "", folderID: folder, cover: CoverPresets.random(), settings: AppPrefs.newNotebookSettings())
            tab = .cover
        case let .edit(id):
            if let nb = source ?? library.notebook(id) { draft = nb }
        }
        categoriesText = draft.categories.joined(separator: ", ")
    }

    private func save() {
        draft.title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.categories = LibraryQuery.parseCategories(categoriesText)
        if isCreating {
            draft.pages = [Page(size: draft.settings.pageDimensions)]
            library.create(draft)
            library.store.pruneAssets(of: draft)
            let id = draft.id
            dismiss()
            onFinish(id)
        } else if let onSave {
            onSave(draft)
            library.store.pruneAssets(of: draft)
            dismiss()
            onFinish(nil)
        } else {
            draft.touch()
            library.save(draft)
            library.store.pruneAssets(of: draft)
            dismiss()
            onFinish(nil)
        }
    }

    private func cancel() {
        if isCreating, library.notebook(draft.id) == nil {
            // Remove a cover photo stored for a notebook that was never created.
            try? library.store.delete(id: draft.id)
        }
        dismiss()
    }

    private func setCoverImage(_ image: UIImage) {
        guard let name = library.storeCoverImage(image, notebookID: draft.id) else { return }
        draft.cover.imageFile = name
        draft.cover.presetID = nil
        draft.cover.titleColor = .white
        if draft.cover.titlePlacement == .label { draft.cover.titlePlacement = .bottom }
    }

    // MARK: Preview

    private var preview: some View {
        VStack(spacing: 22) {
            Spacer(minLength: 10)
            CoverView(
                design: draft.cover, title: draft.displayTitle,
                image: library.coverImage(for: draft),
                aspect: CGFloat(min(1.25, max(0.6, draft.settings.pageDimensions.width / draft.settings.pageDimensions.height)))
            )
            .frame(maxWidth: 210, maxHeight: 290)

            TextField("Notebook title", text: $draft.title)
                .font(DedFont.display(19, .bold))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 12)
                .frame(height: 44)
                .background(RoundedRectangle(cornerRadius: 10).fill(Ded.panel))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Ded.line))
                .padding(.horizontal, 24)

            HStack(spacing: 12) {
                PaperPreview(spec: draft.settings.paper, size: draft.settings.pageDimensions, width: 64)
                VStack(alignment: .leading, spacing: 3) {
                    Text(draft.settings.paper.style.name).font(DedFont.sans(13, .semibold)).foregroundStyle(Ded.text)
                    Text("\(draft.settings.pageSize.name) · \(draft.settings.orientation.name)")
                        .font(DedFont.sans(12)).foregroundStyle(Ded.muted)
                    Text(draft.settings.mode.name).font(DedFont.sans(12)).foregroundStyle(Ded.muted)
                }
                Spacer()
            }
            .padding(.horizontal, 28)
            Spacer(minLength: 10)
        }
    }

    // MARK: Form

    private var form: some View {
        ScrollView {
            formContent
                .padding(24)
                .frame(maxWidth: 640, alignment: .leading)
        }
    }

    @ViewBuilder
    private var formContent: some View {
        switch tab {
        case .cover: coverForm
        case .paper:
            VStack(alignment: .leading, spacing: 12) {
                Text(isCreating ? "Pages start on this paper. You can change any page later." : "Default paper for new pages. To restyle existing pages, use the paper button in the editor.")
                    .font(DedFont.sans(13)).foregroundStyle(Ded.muted)
                PaperPicker(paper: $draft.settings.paper, pageSize: draft.settings.pageDimensions)
            }
        case .layout: layoutForm
        case .details: detailsForm
        }
    }

    private var coverForm: some View {
        VStack(alignment: .leading, spacing: 24) {
            ForEach(CoverCollection.allCases) { collection in
                VStack(alignment: .leading, spacing: 10) {
                    Eyebrow(text: collection.name)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 14) {
                            ForEach(CoverPresets.presets(in: collection)) { preset in
                                Button {
                                    var d = preset.design
                                    d.imageFile = nil
                                    draft.cover = d
                                } label: {
                                    CoverView(design: preset.design, title: collection == .solid ? "" : preset.name, aspect: 0.72, showsShadow: false)
                                        .frame(width: 58)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 5)
                                                .stroke(Ded.accent, lineWidth: 2.5)
                                                .padding(-4)
                                                .opacity(draft.cover.presetID == preset.id && draft.cover.imageFile == nil ? 1 : 0)
                                        )
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(preset.name)
                            }
                        }
                        .padding(6)
                    }
                }
            }

            DedSection(title: "Photo or illustration", footnote: "Use a picture from your photo library or the Files app.") {
                HStack(spacing: 10) {
                    PhotosPicker(selection: $photoItem, matching: .images, preferredItemEncoding: .compatible) {
                        Label("Photos", systemImage: "photo.on.rectangle")
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    Button { showCoverFiles = true } label: { Label("Files", systemImage: "folder") }
                        .buttonStyle(SecondaryButtonStyle())
                    if draft.cover.imageFile != nil {
                        Button(role: .destructive) { draft.cover.imageFile = nil } label: { Label("Remove", systemImage: "xmark") }
                            .buttonStyle(SecondaryButtonStyle())
                    }
                }
                if draft.cover.imageFile != nil {
                    HStack {
                        Text("Darken").font(DedFont.sans(13))
                        Slider(value: $draft.cover.imageDim, in: 0...0.6)
                    }
                }
            }

            DedSection(title: "Cover colour") {
                colorRow(DedPalette.coverColors, selection: Binding(get: { draft.cover.color }, set: { c in
                    draft.cover.color = c
                    draft.cover.presetID = nil
                    let dark = c.luminance < 0.45
                    draft.cover.titleColor = dark ? .white : DedPalette.text
                    draft.cover.patternColor = dark ? RGBA(0xFFFFFF, alpha: 0.16) : RGBA(0x252722, alpha: 0.10)
                }))
            }

            DedSection(title: "Pattern & texture") {
                chips(CoverPattern.allCases, selected: draft.cover.pattern, name: \.name) { draft.cover.pattern = $0; draft.cover.presetID = nil }
                HStack {
                    Text("Pattern colour").font(DedFont.sans(13)).foregroundStyle(Ded.muted)
                    Spacer()
                    ColorPicker("Pattern colour", selection: Binding(get: { draft.cover.patternColor.color }, set: { draft.cover.patternColor = RGBA($0); draft.cover.presetID = nil }), supportsOpacity: true)
                        .labelsHidden()
                }
            }

            DedSection(title: "Title") {
                chips(CoverFont.allCases, selected: draft.cover.titleFont, name: \.name) { draft.cover.titleFont = $0 }
                chips(CoverTitlePlacement.allCases, selected: draft.cover.titlePlacement, name: \.name) { draft.cover.titlePlacement = $0 }
                colorRow([.white, RGBA(0xF4EFE4), RGBA(0xC4D4BC), DedPalette.brand, RGBA(0x4D6049), DedPalette.text, RGBA(0x8C4A3C)],
                         selection: $draft.cover.titleColor)
            }
        }
    }

    private var layoutForm: some View {
        VStack(alignment: .leading, spacing: 24) {
            DedSection(title: "Page size", footnote: isCreating ? nil : "Changes apply to new pages. Existing pages keep their size.") {
                chips(PageSizePreset.allCases, selected: draft.settings.pageSize, name: \.name) { draft.settings.pageSize = $0 }
                chips(PageOrientation.allCases, selected: draft.settings.orientation, name: \.name) { draft.settings.orientation = $0 }
            }
            DedSection(title: "Page mode") {
                ForEach(PageMode.allCases) { mode in
                    Button { draft.settings.mode = mode } label: {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: draft.settings.mode == mode ? "largecircle.fill.circle" : "circle")
                                .foregroundStyle(draft.settings.mode == mode ? Ded.accent : Ded.faint)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(mode.name).font(DedFont.sans(14, .semibold)).foregroundStyle(Ded.text)
                                Text(mode == .fixed
                                     ? "Pages with set boundaries that you add, reorder and remove."
                                     : "One long page that keeps growing as you write near the bottom.")
                                    .font(DedFont.sans(12.5)).foregroundStyle(Ded.muted)
                                    .multilineTextAlignment(.leading)
                            }
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            DedSection(title: "Page numbers") {
                chips(PageNumberPosition.allCases, selected: draft.settings.pageNumbers, name: \.name) { draft.settings.pageNumbers = $0 }
            }
        }
    }

    private var detailsForm: some View {
        VStack(alignment: .leading, spacing: 24) {
            DedSection(title: "About") {
                TextField("Title", text: $draft.title)
                    .font(DedFont.sans(15, .semibold))
                Divider()
                TextField("Description (optional)", text: $draft.details, axis: .vertical)
                    .lineLimit(2...6)
                    .font(DedFont.sans(14))
            }
            DedSection(title: "Organise", footnote: "Separate categories with commas, for example: Biology, Year 2.") {
                Picker("Folder", selection: $draft.folderID) {
                    Text("Unfiled").tag(UUID?.none)
                    ForEach(library.index.folders) { f in Text(f.name).tag(Optional(f.id)) }
                }
                .font(DedFont.sans(14))
                Divider()
                TextField("Categories", text: $categoriesText)
                    .font(DedFont.sans(14))
                    .textInputAutocapitalization(.words)
            }
            if !isCreating {
                DedSection(title: "Information") {
                    info("Pages", "\(draft.pages.count)")
                    info("Created", draft.createdAt.formatted(date: .abbreviated, time: .shortened))
                    info("Modified", draft.modifiedAt.formatted(date: .abbreviated, time: .shortened))
                    if let opened = draft.lastOpenedAt { info("Last opened", opened.formatted(date: .abbreviated, time: .shortened)) }
                }
            }
        }
    }

    // MARK: Small builders

    private func info(_ k: String, _ v: String) -> some View {
        HStack {
            Text(k).font(DedFont.sans(13)).foregroundStyle(Ded.muted)
            Spacer()
            Text(v).font(DedFont.sans(13)).foregroundStyle(Ded.text)
        }
    }

    private func colorRow(_ colors: [RGBA], selection: Binding<RGBA>) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(colors, id: \.self) { c in
                    Button { selection.wrappedValue = c } label: { Swatch(color: c, selected: selection.wrappedValue == c, size: 28) }
                        .buttonStyle(.plain)
                }
                ColorPicker("Custom", selection: Binding(get: { selection.wrappedValue.color }, set: { selection.wrappedValue = RGBA($0) }), supportsOpacity: false)
                    .labelsHidden()
                    .padding(.leading, 6)
            }
            .padding(.vertical, 2)
        }
    }

    private func chips<T: Hashable & Identifiable>(_ values: [T], selected: T, name: KeyPath<T, String>, pick: @escaping (T) -> Void) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(values) { v in
                    let on = v == selected
                    Button { pick(v) } label: {
                        Text(v[keyPath: name])
                            .font(DedFont.sans(13, on ? .semibold : .regular))
                            .foregroundStyle(on ? Ded.accentDark : Ded.text)
                            .padding(.horizontal, 12)
                            .frame(height: 32)
                            .background(Capsule().fill(on ? Ded.accentPale : Ded.soft))
                            .overlay(Capsule().stroke(on ? Ded.selectedLine : Color.clear))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 2)
        }
    }
}
