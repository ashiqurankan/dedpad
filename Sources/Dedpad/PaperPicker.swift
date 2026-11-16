import SwiftUI
import DedpadCore

/// Small rendered previews of paper templates.
@MainActor
enum PaperPreviewCache {
    private static var cache: [String: UIImage] = [:]

    static func image(_ spec: PaperSpec, size: PageDimensions, width: CGFloat = 90) -> UIImage {
        let key = "\(spec.hashValue)-\(Int(size.width))x\(Int(size.height))-\(Int(width))"
        if let i = cache[key] { return i }
        let format = UIGraphicsImageRendererFormat()
        format.scale = (width / CGFloat(size.width)) * 2
        format.opaque = true
        let img = UIGraphicsImageRenderer(size: CGSize(width: size.width, height: size.height), format: format).image { rc in
            PageRenderer.drawPaper(spec, size: size, in: rc.cgContext)
        }
        if cache.count > 300 { cache.removeAll() }
        cache[key] = img
        return img
    }
}

struct PaperPreview: View {
    let spec: PaperSpec
    let size: PageDimensions
    var width: CGFloat = 90
    var selected = false

    var body: some View {
        Image(uiImage: PaperPreviewCache.image(spec, size: size, width: width))
            .resizable()
            .aspectRatio(CGFloat(size.width / size.height), contentMode: .fit)
            .frame(width: width)
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).stroke(selected ? Ded.accent : Ded.line, lineWidth: selected ? 2.5 : 1))
            .shadow(color: .black.opacity(0.05), radius: 3, y: 2)
    }
}

/// Template gallery plus paper colour, line colour, spacing and margins.
struct PaperPicker: View {
    @EnvironmentObject private var library: LibraryModel
    @Binding var paper: PaperSpec
    var pageSize: PageDimensions
    @State private var showSave = false
    @State private var saveName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            ForEach(PaperCategory.allCases) { category in
                VStack(alignment: .leading, spacing: 10) {
                    Eyebrow(text: category.name)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(alignment: .top, spacing: 14) {
                            ForEach(PaperStyle.styles(in: category)) { style in
                                Button {
                                    paper = paper.with(style: style)
                                } label: {
                                    VStack(spacing: 6) {
                                        PaperPreview(spec: paper.with(style: style), size: pageSize, width: 74, selected: paper.style == style)
                                        Text(style.name)
                                            .font(DedFont.sans(11, paper.style == style ? .semibold : .regular))
                                            .foregroundStyle(paper.style == style ? Ded.accentDark : Ded.muted)
                                            .lineLimit(1)
                                            .frame(width: 80)
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(4)
                    }
                }
            }

            if !library.index.savedPapers.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Eyebrow(text: "Your templates")
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(alignment: .top, spacing: 14) {
                            ForEach(library.index.savedPapers) { saved in
                                Button { paper = saved.paper } label: {
                                    VStack(spacing: 6) {
                                        PaperPreview(spec: saved.paper, size: pageSize, width: 74, selected: paper == saved.paper)
                                        Text(saved.name).font(DedFont.sans(11)).foregroundStyle(Ded.muted).lineLimit(1).frame(width: 80)
                                    }
                                }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    Button(role: .destructive) { library.deleteSavedPaper(saved.id) } label: { Label("Delete template", systemImage: "trash") }
                                }
                            }
                        }
                        .padding(4)
                    }
                }
            }

            DedSection(title: "Paper colour") {
                swatchRow(DedPalette.paperColors, selected: paper.background) { c in
                    let wasDark = paper.background.isDark
                    paper.background = c
                    // Keep lines visible when switching between light and dark paper.
                    if c.isDark != wasDark {
                        paper.lineColor = c.isDark ? RGBA(0x3E443A) : DedPalette.paperLine
                    }
                } custom: {
                    ColorPicker("Custom", selection: Binding(get: { paper.background.color }, set: { paper.background = RGBA($0) }), supportsOpacity: false)
                        .labelsHidden()
                }
            }

            DedSection(title: "Line colour") {
                swatchRow(DedPalette.lineColors, selected: paper.lineColor) { paper.lineColor = $0 } custom: {
                    ColorPicker("Custom", selection: Binding(get: { paper.lineColor.color }, set: { paper.lineColor = RGBA($0) }), supportsOpacity: true)
                        .labelsHidden()
                }
                HStack {
                    Text("Accent lines").font(DedFont.sans(13)).foregroundStyle(Ded.muted)
                    Spacer()
                    ColorPicker("Accent", selection: Binding(get: { paper.accentColor.color }, set: { paper.accentColor = RGBA($0) }), supportsOpacity: true)
                        .labelsHidden()
                }
            }

            DedSection(title: "Spacing") {
                if paper.style.usesSpacing {
                    sliderRow("Line / grid spacing", value: $paper.spacing, range: 8...48, unit: "pt")
                }
                sliderRow("Page margin", value: $paper.margin, range: 0...80, unit: "pt")
                Button("Reset to template defaults") { paper = PaperSpec(style: paper.style, background: paper.background) }
                    .font(DedFont.sans(13, .medium))
            }

            Button { saveName = paper.style.name; showSave = true } label: {
                Label("Save as my template", systemImage: "square.and.arrow.down.on.square")
            }
            .buttonStyle(SecondaryButtonStyle())
        }
        .alert("Save template", isPresented: $showSave) {
            TextField("Name", text: $saveName)
            Button("Cancel", role: .cancel) {}
            Button("Save") { library.savePaper(paper, name: saveName) }
        } message: {
            Text("Saved templates appear in every notebook.")
        }
    }

    private func swatchRow(_ colors: [RGBA], selected: RGBA, pick: @escaping (RGBA) -> Void, @ViewBuilder custom: () -> some View) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(colors, id: \.self) { c in
                    Button { pick(c) } label: { Swatch(color: c, selected: c == selected, size: 28) }
                        .buttonStyle(.plain)
                }
                custom()
            }
            .padding(.vertical, 2)
        }
    }

    private func sliderRow(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, unit: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(DedFont.sans(13)).foregroundStyle(Ded.text)
                Spacer()
                Text("\(Int(value.wrappedValue.rounded())) \(unit)").font(DedFont.sans(12)).monospacedDigit().foregroundStyle(Ded.muted)
            }
            Slider(value: value, in: range, step: 1)
        }
    }
}
