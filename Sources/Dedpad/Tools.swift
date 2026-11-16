import SwiftUI
import PencilKit
import DedpadCore

/// The active tool in the editor.
enum EditorTool: String, Codable, CaseIterable, Identifiable {
    case pen, pencil, marker, eraser, shape, lasso, text, selectText
    var id: String { rawValue }

    var name: String {
        switch self {
        case .pen: return "Pen"
        case .pencil: return "Pencil"
        case .marker: return "Highlighter"
        case .eraser: return "Eraser"
        case .lasso: return "Lasso"
        case .shape: return "Shapes"
        case .text: return "Text & images"
        case .selectText: return "Select PDF text"
        }
    }

    var symbol: String {
        switch self {
        case .pen: return "pencil.tip"
        case .pencil: return "pencil"
        case .marker: return "highlighter"
        case .eraser: return "eraser"
        case .lasso: return "lasso"
        case .shape: return "square.on.circle"
        case .text: return "textformat"
        case .selectText: return "character.cursor.ibeam"
        }
    }

    var isInking: Bool { self == .pen || self == .pencil || self == .marker }
    /// Whether the PencilKit canvas takes touches with this tool.
    var usesCanvas: Bool { isInking || self == .eraser || self == .lasso }
    /// Tools with colours and sizes in the tool bar.
    var hasStyle: Bool { isInking || self == .shape || self == .text }
}

/// Colours and sizes for one tool: a few quick slots, one of each selected.
struct ToolStyle: Codable, Equatable {
    var colors: [RGBA]
    var colorIndex = 0
    var sizes: [Double]
    var sizeIndex = 1
    /// PencilKit ink name (pen / fountainPen / monoline / pencil / crayon / watercolor / marker).
    var ink: String

    var color: RGBA {
        get { colors.indices.contains(colorIndex) ? colors[colorIndex] : (colors.first ?? DedPalette.text) }
        set { if colors.indices.contains(colorIndex) { colors[colorIndex] = newValue } else { colors.append(newValue); colorIndex = colors.count - 1 } }
    }

    var width: Double {
        get { sizes.indices.contains(sizeIndex) ? sizes[sizeIndex] : (sizes.first ?? 2) }
        set { if sizes.indices.contains(sizeIndex) { sizes[sizeIndex] = newValue } }
    }
}

/// A saved pen.
struct ToolPreset: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var tool: EditorTool
    var ink: String
    var color: RGBA
    var width: Double
}

/// Tool configuration, remembered between launches ("saved tool configurations").
struct ToolSettings: Codable, Equatable {
    var pen = ToolStyle(colors: [DedPalette.text, RGBA(0x3F5873), RGBA(0xB0493E)], sizes: [1.4, 2.4, 4.5], ink: "pen")
    var pencil = ToolStyle(colors: [RGBA(0x3E443A), RGBA(0x4D6049), RGBA(0x8C4A3C)], sizes: [2, 3.5, 6], ink: "pencil")
    var marker = ToolStyle(colors: [RGBA(0xF3E7A6), RGBA(0xC9E4C5), RGBA(0xF6C9C0)], sizes: [10, 16, 26], ink: "marker")
    var shapeStyle = ToolStyle(colors: [DedPalette.text, RGBA(0x3F5873), RGBA(0x4D6049)], sizes: [1.4, 2.4, 4.5], ink: "pen")
    var textStyle = ToolStyle(colors: [DedPalette.text, RGBA(0x3F5873), RGBA(0xB0493E)], sizes: [12, 16, 24], ink: "pen")
    var shape = InkConverter.Shape.rectangle.rawValue
    var bitmapEraser = false
    var eraserWidth = 12.0
    var highlighterColors: [RGBA] = [RGBA(0xF3E7A6), RGBA(0xC9E4C5), RGBA(0xF6C9C0), RGBA(0xC5D8F0)]
    var presets: [ToolPreset] = []

    static let key = "toolSettings.v2"

    static func load() -> ToolSettings {
        guard let data = UserDefaults.standard.data(forKey: key),
              let s = try? JSONDecoder().decode(ToolSettings.self, from: data) else { return ToolSettings() }
        return s
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: Self.key) }
    }

    func style(for tool: EditorTool) -> ToolStyle {
        switch tool {
        case .pencil: return pencil
        case .marker: return marker
        case .shape: return shapeStyle
        case .text: return textStyle
        default: return pen
        }
    }

    mutating func updateStyle(for tool: EditorTool, _ change: (inout ToolStyle) -> Void) {
        switch tool {
        case .pen: change(&pen)
        case .pencil: change(&pencil)
        case .marker: change(&marker)
        case .shape: change(&shapeStyle)
        case .text: change(&textStyle)
        default: break
        }
    }

    func color(for tool: EditorTool) -> RGBA { style(for: tool).color }
    func width(for tool: EditorTool) -> Double { style(for: tool).width }
    mutating func setColor(_ c: RGBA, for tool: EditorTool) { updateStyle(for: tool) { $0.color = c } }
    mutating func setWidth(_ w: Double, for tool: EditorTool) { updateStyle(for: tool) { $0.width = w } }

    // Convenience used by the canvas and editor.
    var penInk: String { get { pen.ink } set { pen.ink = newValue } }
    var pencilInk: String { get { pencil.ink } set { pencil.ink = newValue } }
    var shapeColor: RGBA { shapeStyle.color }
    var shapeWidth: Double { shapeStyle.width }
    var textColor: RGBA { textStyle.color }
    var textSize: Double { textStyle.width }

    static func sizeRange(for tool: EditorTool) -> ClosedRange<Double> {
        switch tool {
        case .marker: return 4...40
        case .pencil: return 1...14
        case .text: return 9...48
        default: return 0.5...12
        }
    }

    /// The PencilKit tool for page coordinates displayed at `scale`.
    func pkTool(for tool: EditorTool, scale: CGFloat) -> PKTool {
        switch tool {
        case .pen:
            return PKInkingTool(InkConverter.inkType(pen.ink), color: pen.color.uiColor, width: CGFloat(pen.width) * scale)
        case .pencil:
            return PKInkingTool(InkConverter.inkType(pencil.ink), color: pencil.color.uiColor, width: CGFloat(pencil.width) * scale)
        case .marker:
            return PKInkingTool(.marker, color: marker.color.uiColor, width: CGFloat(marker.width) * scale)
        case .eraser:
            if #available(iOS 16.4, *) {
                return PKEraserTool(bitmapEraser ? .bitmap : .vector, width: CGFloat(eraserWidth) * scale)
            }
            return PKEraserTool(bitmapEraser ? .bitmap : .vector)
        case .lasso:
            return PKLassoTool()
        default:
            return PKInkingTool(.pen, color: pen.color.uiColor, width: CGFloat(pen.width) * scale)
        }
    }

    static func inkChoices(for tool: EditorTool) -> [(String, String)] {
        switch tool {
        case .pen: return [("pen", "Ballpoint"), ("fountainPen", "Fountain pen"), ("monoline", "Monoline")]
        case .pencil: return [("pencil", "Pencil"), ("crayon", "Crayon"), ("watercolor", "Watercolour")]
        default: return []
        }
    }
}

// MARK: - Tool bar (second header row)

/// The drawing tools, built into the editor header: tools in the middle, the selected tool's
/// colours and sizes beside them. Tap an active tool, colour or size again to fine-tune it.
struct ToolStrip: View {
    let model: EditorModel
    var onInsertImage: () -> Void
    var onSticker: () -> Void

    @State private var toolPopover: EditorTool?
    @State private var colorPopover: Int?
    @State private var sizePopover: Int?
    @State private var showSavePreset = false
    @State private var presetName = ""

    private var tool: EditorTool { model.tool }
    private var settings: ToolSettings { model.toolSettings }

    var body: some View {
        // No scroll view when everything fits: taps register instantly and never get eaten by scrolling.
        ViewThatFits(in: .horizontal) {
            strip
            ScrollView(.horizontal, showsIndicators: false) { strip }
        }
        .frame(height: 50)
        .alert("Save pen", isPresented: $showSavePreset) {
            TextField("Name", text: $presetName)
            Button("Cancel", role: .cancel) {}
            Button("Save") { model.saveCurrentPreset(name: presetName) }
        }
    }

    private var strip: some View {
            HStack(spacing: 4) {
                tools
                if tool.hasStyle {
                    divider
                    colorSlots
                    divider
                    sizeSlots
                } else if tool == .eraser {
                    divider
                    eraserOptions
                } else if tool == .selectText {
                    divider
                    highlightOptions
                }
                divider
                presetMenu
            }
            .padding(.horizontal, 12)
            .fixedSize(horizontal: true, vertical: false)
            .frame(maxWidth: .infinity)
    }

    private var divider: some View {
        Rectangle().fill(Ded.line).frame(width: 1, height: 26).padding(.horizontal, 6)
    }

    // MARK: Tools

    private var tools: some View {
        HStack(spacing: 2) {
            ForEach(EditorTool.allCases) { t in
                if t != .selectText || model.hasPDFPages {
                    toolButton(t)
                }
            }
            Button(action: onInsertImage) { Image(systemName: "photo") }
                .buttonStyle(ToolButtonStyle())
                .accessibilityLabel("Insert image")
            Button(action: onSticker) { Image(systemName: "face.smiling") }
                .buttonStyle(ToolButtonStyle())
                .accessibilityLabel("Stickers")
            Button { model.toggleRuler() } label: { Image(systemName: "ruler") }
                .buttonStyle(ToolButtonStyle(active: model.rulerActive))
                .accessibilityLabel("Ruler")
        }
    }

    private func toolButton(_ t: EditorTool) -> some View {
        let active = tool == t
        let symbol = t == .shape ? (InkConverter.Shape(rawValue: settings.shape)?.symbol ?? t.symbol) : t.symbol
        return Button {
            if active && t != .lasso && t != .selectText { toolPopover = t } else { model.setTool(t) }
        } label: {
            VStack(spacing: 2) {
                Image(systemName: symbol)
                // Pens show their current colour under the icon.
                Capsule()
                    .fill(t.isInking || t == .shape ? settings.color(for: t).color : Color.clear)
                    .frame(width: 14, height: 3)
            }
        }
        .buttonStyle(ToolButtonStyle(active: active))
        .accessibilityLabel(t.name)
        .accessibilityHint(active ? "Double-tap for options" : "")
        .popover(item: Binding(get: { toolPopover == t ? t : nil }, set: { toolPopover = $0 })) { which in
            ToolOptions(model: model, tool: which)
                .frame(width: 320)
                .presentationCompactAdaptation(.popover)
        }
    }

    // MARK: Colours & sizes

    private var colorSlots: some View {
        let style = settings.style(for: tool)
        return HStack(spacing: 2) {
            ForEach(Array(style.colors.enumerated()), id: \.offset) { i, c in
                let on = i == style.colorIndex
                Button {
                    if on { colorPopover = i } else { model.updateTools { $0.updateStyle(for: tool) { $0.colorIndex = i } } }
                } label: {
                    Circle()
                        .fill(c.color)
                        .frame(width: 24, height: 24)
                        .overlay(Circle().stroke(Color.black.opacity(0.12), lineWidth: 0.5))
                        .overlay(Circle().stroke(Ded.accent, lineWidth: 2).padding(-4).opacity(on ? 1 : 0))
                        .frame(width: 36, height: 36)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Colour \(i + 1)\(on ? ", selected" : "")")
                .popover(item: Binding(get: { colorPopover == i ? ColorSlot(index: i) : nil }, set: { colorPopover = $0?.index })) { slot in
                    ColorSlotEditor(model: model, tool: tool, slot: slot.index)
                        .frame(width: 300)
                        .presentationCompactAdaptation(.popover)
                }
            }
        }
    }

    private var sizeSlots: some View {
        let style = settings.style(for: tool)
        let range = ToolSettings.sizeRange(for: tool)
        return HStack(spacing: 2) {
            ForEach(Array(style.sizes.enumerated()), id: \.offset) { i, w in
                let on = i == style.sizeIndex
                Button {
                    if on { sizePopover = i } else { model.updateTools { $0.updateStyle(for: tool) { $0.sizeIndex = i } } }
                } label: {
                    Group {
                        if tool == .text {
                            Text("A").font(.system(size: 11 + CGFloat(i) * 4, weight: .semibold))
                        } else {
                            let t = (w - range.lowerBound) / (range.upperBound - range.lowerBound)
                            Capsule().frame(width: 18, height: 2 + CGFloat(t) * 9)
                        }
                    }
                    .foregroundStyle(on ? Ded.accentDark : Ded.muted)
                    .frame(width: 40, height: 36)
                    .background(RoundedRectangle(cornerRadius: 8).fill(on ? Ded.accentPale : .clear))
                    .contentShape(Rectangle())     // the whole button is tappable, not just the line
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Size \(i + 1)\(on ? ", selected" : "")")
                .popover(item: Binding(get: { sizePopover == i ? SizeSlot(index: i) : nil }, set: { sizePopover = $0?.index })) { slot in
                    SizeSlotEditor(model: model, tool: tool, slot: slot.index)
                        .frame(width: 280)
                        .presentationCompactAdaptation(.popover)
                }
            }
        }
    }

    private var eraserOptions: some View {
        HStack(spacing: 6) {
            Picker("Eraser", selection: Binding(get: { settings.bitmapEraser }, set: { v in model.updateTools { $0.bitmapEraser = v } })) {
                Text("Whole stroke").tag(false)
                Text("Precise").tag(true)
            }
            .pickerStyle(.segmented)
            .frame(width: 190)
            Button(role: .destructive) { model.clearCurrentPage() } label: {
                Label("Erase page", systemImage: "trash").font(DedFont.sans(13, .medium))
            }
            .buttonStyle(.bordered)
            .tint(Ded.danger)
        }
    }

    private var highlightOptions: some View {
        HStack(spacing: 4) {
            Text(model.hasTextSelection ? "Highlight:" : "Select text in a PDF")
                .font(DedFont.sans(12.5)).foregroundStyle(Ded.muted).fixedSize()
            if model.hasTextSelection {
                ForEach(Array(settings.highlighterColors.enumerated()), id: \.offset) { _, c in
                    Button { model.highlightSelection(color: c.withAlpha(0.55)) } label: { Swatch(color: c, selected: false, size: 22) }
                        .buttonStyle(.plain)
                }
                Button { model.removeHighlightsInSelection() } label: { Image(systemName: "eraser.line.dashed") }
                    .buttonStyle(ToolButtonStyle())
                    .accessibilityLabel("Remove highlights")
            }
        }
    }

    private var presetMenu: some View {
        Menu {
            if settings.presets.isEmpty { Text("No saved pens yet") }
            ForEach(settings.presets) { p in
                Button { model.applyPreset(p) } label: { Label(p.name, systemImage: p.tool.symbol) }
            }
            Divider()
            if tool.isInking {
                Button { presetName = "\(tool.name) \(settings.presets.count + 1)"; showSavePreset = true } label: {
                    Label("Save current pen…", systemImage: "star")
                }
            }
            if !settings.presets.isEmpty {
                Menu("Remove") {
                    ForEach(settings.presets) { p in
                        Button(role: .destructive) { model.updateTools { $0.presets.removeAll { $0.id == p.id } } } label: { Text(p.name) }
                    }
                }
            }
        } label: {
            Image(systemName: "star").font(.system(size: 16)).foregroundStyle(Ded.muted).frame(width: 36, height: 36)
        }
        .accessibilityLabel("Saved pens")
    }
}

struct ToolButtonStyle: ButtonStyle {
    var active = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 18, weight: active ? .semibold : .regular))
            .foregroundStyle(active ? Ded.accentDark : Ded.muted)
            .frame(width: 40, height: 40)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(active ? Ded.accentPale : (configuration.isPressed ? Ded.soft : .clear))
            )
            .contentShape(Rectangle())
    }
}

private struct ColorSlot: Identifiable { let index: Int; var id: Int { index } }
private struct SizeSlot: Identifiable { let index: Int; var id: Int { index } }

// MARK: - Popovers

/// Full options for a tool (tap the active tool again).
struct ToolOptions: View {
    let model: EditorModel
    let tool: EditorTool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(tool.name).font(DedFont.display(16, .bold))
            let inks = ToolSettings.inkChoices(for: tool)
            if !inks.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Eyebrow(text: "Type")
                    HStack(spacing: 6) {
                        ForEach(inks, id: \.0) { ink, name in
                            let on = model.toolSettings.style(for: tool).ink == ink
                            Button { model.updateTools { $0.updateStyle(for: tool) { $0.ink = ink } } } label: {
                                Text(name).font(DedFont.sans(12.5, on ? .semibold : .regular))
                                    .padding(.horizontal, 10).frame(height: 30)
                                    .background(Capsule().fill(on ? Ded.accentPale : Ded.soft))
                                    .foregroundStyle(on ? Ded.accentDark : Ded.text)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            if tool == .shape {
                VStack(alignment: .leading, spacing: 8) {
                    Eyebrow(text: "Shape")
                    HStack(spacing: 4) {
                        ForEach(InkConverter.Shape.allCases) { s in
                            Button { model.updateTools { $0.shape = s.rawValue } } label: { Image(systemName: s.symbol) }
                                .buttonStyle(ToolButtonStyle(active: model.toolSettings.shape == s.rawValue))
                                .accessibilityLabel(s.name)
                        }
                    }
                }
            }
            if tool == .eraser {
                VStack(alignment: .leading, spacing: 8) {
                    Eyebrow(text: "Size")
                    Slider(value: Binding(get: { model.toolSettings.eraserWidth }, set: { v in model.updateTools { $0.eraserWidth = v } }), in: 4...60)
                    Text("Size only applies to the precise eraser.").font(DedFont.sans(12)).foregroundStyle(Ded.muted)
                }
                Button(role: .destructive) { model.clearCurrentPage() } label: { Label("Erase whole page", systemImage: "trash") }
            }
            if tool.hasStyle {
                SizeSlider(model: model, tool: tool, slot: model.toolSettings.style(for: tool).sizeIndex)
                VStack(alignment: .leading, spacing: 8) {
                    Eyebrow(text: "Colour")
                    ColorGrid(selected: model.toolSettings.color(for: tool)) { c in
                        model.updateTools { $0.setColor(c, for: tool) }
                    }
                }
            }
        }
        .padding(18)
        .background(Ded.panel)
    }
}

/// Edit one colour slot (tap the selected colour again).
struct ColorSlotEditor: View {
    let model: EditorModel
    let tool: EditorTool
    let slot: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Eyebrow(text: "Colour \(slot + 1)")
            ColorGrid(selected: current) { c in set(c) }
            ColorPicker("Custom colour", selection: Binding(get: { current.color }, set: { set(RGBA($0)) }), supportsOpacity: tool == .marker)
                .font(DedFont.sans(13))
        }
        .padding(16)
        .background(Ded.panel)
    }

    private var current: RGBA {
        let s = model.toolSettings.style(for: tool)
        return s.colors.indices.contains(slot) ? s.colors[slot] : s.color
    }

    private func set(_ c: RGBA) {
        model.updateTools { $0.updateStyle(for: tool) { st in
            if st.colors.indices.contains(slot) { st.colors[slot] = c }
            st.colorIndex = slot
        } }
    }
}

/// Edit one size slot (tap the selected size again).
struct SizeSlotEditor: View {
    let model: EditorModel
    let tool: EditorTool
    let slot: Int
    var body: some View {
        SizeSlider(model: model, tool: tool, slot: slot).padding(16).background(Ded.panel)
    }
}

struct SizeSlider: View {
    let model: EditorModel
    let tool: EditorTool
    let slot: Int

    var body: some View {
        let style = model.toolSettings.style(for: tool)
        let value = style.sizes.indices.contains(slot) ? style.sizes[slot] : style.width
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Eyebrow(text: tool == .text ? "Text size" : "Thickness")
                Spacer()
                Text(String(format: tool == .text ? "%.0f pt" : "%.1f", value)).font(DedFont.sans(12)).monospacedDigit().foregroundStyle(Ded.muted)
            }
            Slider(value: Binding(get: { value }, set: { v in
                model.updateTools { $0.updateStyle(for: tool) { st in
                    if st.sizes.indices.contains(slot) { st.sizes[slot] = v }
                    st.sizeIndex = slot
                } }
            }), in: ToolSettings.sizeRange(for: tool))
            if tool != .text {
                Capsule()
                    .fill(model.toolSettings.color(for: tool).color)
                    .frame(width: 120, height: max(1, min(30, value)))
                    .frame(maxWidth: .infinity)
            }
        }
    }
}

/// A grid of ink colours.
struct ColorGrid: View {
    let selected: RGBA
    let pick: (RGBA) -> Void

    static let palette: [RGBA] = [
        RGBA(0x252722), RGBA(0x5F6B6E), RGBA(0x9AA19A), RGBA(0xFFFFFF),
        RGBA(0x3F5873), RGBA(0x2F6FB5), RGBA(0x7C98B3), RGBA(0x5B4F73),
        RGBA(0x4D6049), RGBA(0x5F9455), RGBA(0x687B62), RGBA(0xA3B69A),
        RGBA(0xB0493E), RGBA(0xC9776B), RGBA(0xA8701C), RGBA(0xE0A93B),
        RGBA(0xF3E7A6), RGBA(0xC9E4C5), RGBA(0xF6C9C0), RGBA(0xC5D8F0),
    ]

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(34), spacing: 8), count: 6), spacing: 8) {
            ForEach(Self.palette, id: \.self) { c in
                Button { pick(c) } label: { Swatch(color: c, selected: c.hex == selected.hex, size: 26) }
                    .buttonStyle(.plain)
            }
        }
    }
}
