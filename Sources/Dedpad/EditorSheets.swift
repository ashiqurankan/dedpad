import SwiftUI
import DedpadCore

/// Change the paper of this page, all pages, or new pages.
struct PageStyleSheet: View {
    let model: EditorModel
    @Environment(\.dismiss) private var dismiss
    @State private var paper = PaperSpec()
    @State private var scope: EditorModel.PaperScope = .page
    @State private var loaded = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if case .paper = model.currentPage.background {
                        EmptyView()
                    } else {
                        Text("This page shows an imported PDF or image. Paper changes apply when you add new pages, or choose “All pages”.")
                            .font(DedFont.sans(13)).foregroundStyle(Ded.warn)
                    }
                    HStack(alignment: .top, spacing: 22) {
                        PaperPreview(spec: paper, size: model.currentPage.size, width: 150)
                        VStack(alignment: .leading, spacing: 10) {
                            Eyebrow(text: "Apply to")
                            Picker("Apply to", selection: $scope) {
                                ForEach(EditorModel.PaperScope.allCases) { Text($0.name).tag($0) }
                            }
                            .pickerStyle(.segmented)
                            Text(scopeHelp).font(DedFont.sans(12.5)).foregroundStyle(Ded.muted)
                        }
                    }
                    PaperPicker(paper: $paper, pageSize: model.currentPage.size)
                }
                .padding(24)
            }
            .background(Ded.bg)
            .navigationTitle("Paper")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") {
                        model.applyPaper(paper, scope: scope)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
        .onAppear {
            guard !loaded else { return }
            loaded = true
            paper = model.notebook.paper(for: model.currentPage)
        }
    }

    private var scopeHelp: String {
        switch scope {
        case .page: return "Only page \(model.currentIndex + 1) changes."
        case .all: return "Every page uses this paper, and it becomes the notebook default."
        case .notebookDefault: return "Existing pages stay as they are; pages you add from now on use this paper."
        }
    }
}

// MARK: - Export Center

struct ExportCenter: View {
    let model: EditorModel
    @EnvironmentObject private var library: LibraryModel
    @Environment(\.dismiss) private var dismiss

    enum PageScope: String, CaseIterable, Identifiable {
        case current, all, selected
        var id: String { rawValue }
        var name: String {
            switch self {
            case .current: return "This page"
            case .all: return "All pages"
            case .selected: return "Choose…"
            }
        }
    }

    @State private var options = ExportOptions()
    @State private var scope: PageScope = .all
    @State private var chosen = Set<UUID>()
    @State private var share: ShareItem?
    @State private var working = false
    @State private var progress: Double = 0
    @State private var exportTask: Task<Void, Never>?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    DedSection(title: "Format") {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 10)], spacing: 10) {
                            ForEach(ExportFormat.allCases) { f in
                                let on = options.format == f
                                Button { options.format = f } label: {
                                    VStack(alignment: .leading, spacing: 8) {
                                        Image(systemName: f.symbol).font(.system(size: 18)).foregroundStyle(on ? Ded.accentDark : Ded.muted)
                                        Text(f.name).font(DedFont.sans(13.5, .semibold)).foregroundStyle(Ded.text)
                                    }
                                    .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
                                    .padding(12)
                                    .background(RoundedRectangle(cornerRadius: 10).fill(on ? Ded.accentPale : Ded.soft))
                                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(on ? Ded.selectedLine : Color.clear, lineWidth: 1.5))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        Text(options.format.detail).font(DedFont.sans(12.5)).foregroundStyle(Ded.muted)
                    }

                    if options.format.usesPages {
                        DedSection(title: "Pages") {
                            Picker("Pages", selection: $scope) {
                                ForEach(PageScope.allCases) { Text($0.name).tag($0) }
                            }
                            .pickerStyle(.segmented)
                            if scope == .selected {
                                pageChooser
                            }
                        }

                        DedSection(title: "Options") {
                            Picker("Background", selection: $options.background) {
                                ForEach(ExportBackground.allCases.filter { $0 != .transparent || [.png, .svg].contains(options.format) }) {
                                    Text($0.name).tag($0)
                                }
                            }
                            .font(DedFont.sans(14))
                            Toggle("Page numbers", isOn: $options.includePageNumbers).font(DedFont.sans(14))
                            if options.format == .png || options.format == .jpeg || options.format == .pdf {
                                Picker(options.format == .pdf ? "Ink resolution" : "Resolution", selection: $options.resolution) {
                                    Text("1×").tag(CGFloat(1))
                                    Text("2×").tag(CGFloat(2))
                                    Text("3×").tag(CGFloat(3))
                                }
                                .font(DedFont.sans(14))
                            }
                            if options.format == .jpeg {
                                HStack {
                                    Text("Quality").font(DedFont.sans(14))
                                    Slider(value: $options.jpegQuality, in: 0.3...1)
                                    Text("\(Int(options.jpegQuality * 100))%").font(DedFont.sans(12)).monospacedDigit().foregroundStyle(Ded.muted)
                                }
                            }
                            if options.format == .pdf {
                                Toggle(isOn: $options.editableAnnotations) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Editable annotations").font(DedFont.sans(14))
                                        Text(options.editableAnnotations
                                             ? "Ink and highlights stay editable in Preview, Acrobat and other PDF apps."
                                             : "Ink is flattened into the page and looks exactly like it does in dedpad.")
                                            .font(DedFont.sans(12)).foregroundStyle(Ded.muted)
                                    }
                                }
                                Picker("PDF page size", selection: $options.pdfPageSize) {
                                    ForEach(PDFPageSizeOption.allCases) { Text($0.name).tag($0) }
                                }
                                .font(DedFont.sans(14))
                            }
                        }
                    }

                    if let error {
                        Text(error).font(DedFont.sans(13)).foregroundStyle(Ded.danger)
                    }

                    if working {
                        VStack(alignment: .leading, spacing: 10) {
                            ProgressView(value: progress)
                                .tint(Ded.accent)
                            HStack {
                                Text("Preparing \(summary)… \(Int(progress * 100))%")
                                    .font(DedFont.sans(13)).foregroundStyle(Ded.muted)
                                Spacer()
                                Button("Cancel") { exportTask?.cancel() }
                                    .font(DedFont.sans(13, .semibold))
                            }
                        }
                    } else {
                        Button(action: run) {
                            Text("Export \(summary)").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(options.format.usesPages && scope == .selected && chosen.isEmpty)
                    }
                }
                .padding(24)
            }
            .background(Ded.bg)
            .navigationTitle("Export")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
            }
        }
        .sheet(item: $share) { item in ShareSheet(items: item.urls) }
        .onAppear { chosen = [model.currentPage.id] }
    }

    private var summary: String {
        guard options.format.usesPages else { return options.format.name }
        let n: Int
        switch scope {
        case .current: n = 1
        case .all: n = model.pageCount
        case .selected: n = chosen.count
        }
        return "\(n) page\(n == 1 ? "" : "s") as \(options.format.name)"
    }

    private var pageChooser: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(Array(model.notebook.pages.enumerated()), id: \.element.id) { i, page in
                    let on = chosen.contains(page.id)
                    Button {
                        if on { chosen.remove(page.id) } else { chosen.insert(page.id) }
                    } label: {
                        VStack(spacing: 5) {
                            Group {
                                if let img = model.thumbnails[page.id] {
                                    Image(uiImage: img).resizable().scaledToFit()
                                } else {
                                    Rectangle().fill(model.notebook.paper(for: page).background.color)
                                        .aspectRatio(CGFloat(page.size.width / page.size.height), contentMode: .fit)
                                }
                            }
                            .frame(width: 64, height: 86)
                            .overlay(RoundedRectangle(cornerRadius: 4).stroke(on ? Ded.accent : Ded.line, lineWidth: on ? 2.5 : 1))
                            .overlay(alignment: .topTrailing) {
                                if on {
                                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Ded.accent).background(Circle().fill(.white)).padding(3)
                                }
                            }
                            Text("\(i + 1)").font(DedFont.sans(11)).foregroundStyle(Ded.muted)
                        }
                    }
                    .buttonStyle(.plain)
                    .onAppear { model.requestThumbnail(page.id) }
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func run() {
        working = true
        progress = 0
        error = nil
        let nb = model.prepareForExport()
        var o = options
        switch scope {
        case .current: o.pageIDs = [model.currentPage.id]
        case .all: o.pageIDs = []
        case .selected: o.pageIDs = nb.pages.map(\.id).filter { chosen.contains($0) }
        }
        let store = library.store
        let cover = library.coverImage(for: nb)
        exportTask = Task {
            do {
                let urls = try await Exporter.export(notebook: nb, options: o, store: store, coverImage: cover) { p in
                    Task { @MainActor in progress = p }
                }
                if !Task.isCancelled { share = ShareItem(urls: urls) }
            } catch is CancellationError {
                error = nil
            } catch {
                self.error = error.localizedDescription
            }
            working = false
        }
    }
}
