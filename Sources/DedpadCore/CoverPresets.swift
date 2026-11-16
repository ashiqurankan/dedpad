import Foundation

public enum CoverCollection: String, CaseIterable, Sendable, Identifiable {
    case ded, minimal, academic, abstract, solid
    public var id: String { rawValue }
    public var name: String {
        switch self {
        case .ded: return "Ded"
        case .minimal: return "Minimalist"
        case .academic: return "Academic"
        case .abstract: return "Abstract"
        case .solid: return "Solid colour"
        }
    }
}

public struct CoverPreset: Identifiable, Sendable, Hashable {
    public let id: String
    public let name: String
    public let collection: CoverCollection
    public let design: CoverDesign
}

public enum CoverPresets {
    private static func preset(
        _ id: String, _ name: String, _ col: CoverCollection,
        _ color: UInt32, _ pattern: CoverPattern = .none, pattern pc: RGBA? = nil,
        title: UInt32 = 0xFFFFFF, font: CoverFont = .display, place: CoverTitlePlacement = .bottom
    ) -> CoverPreset {
        let bg = RGBA(color)
        let defaultPattern = bg.isDark || bg.luminance < 0.45 ? RGBA(0xFFFFFF, alpha: 0.16) : RGBA(0x252722, alpha: 0.10)
        return CoverPreset(
            id: id, name: name, collection: col,
            design: CoverDesign(
                presetID: id, color: bg, pattern: pattern, patternColor: pc ?? defaultPattern,
                titleColor: RGBA(title), titleFont: font, titlePlacement: place
            )
        )
    }

    public static let all: [CoverPreset] = [
        // Ded — the Ded Notes identity.
        preset("ded-sage", "Sage", .ded, 0x687B62, .none, font: .italic, place: .bottom),
        preset("ded-moss", "Moss", .ded, 0x4D6049, .linen, font: .display),
        preset("ded-paper", "Paper", .ded, 0xF4F1E6, .frame, pattern: RGBA(0x687B62, alpha: 0.55), title: 0x4D6049, font: .italic, place: .center),
        preset("ded-night", "Night", .ded, 0x1E211D, .dots, pattern: RGBA(0xA3B69A, alpha: 0.25), title: 0xC4D4BC, font: .display),
        preset("ded-mist", "Mist", .ded, 0xE9EEE6, .pinstripe, pattern: RGBA(0x687B62, alpha: 0.18), title: 0x4D6049, font: .display, place: .label),

        // Minimalist
        preset("min-chalk", "Chalk", .minimal, 0xF7F7F5, .none, title: 0x252722, font: .display, place: .top),
        preset("min-ink", "Ink", .minimal, 0x252722, .none, title: 0xF7F7F5, font: .sans, place: .top),
        preset("min-sand", "Sand", .minimal, 0xD8C7A8, .none, title: 0x3B3226, font: .serif, place: .center),
        preset("min-frame", "Frame", .minimal, 0xFFFFFF, .frame, pattern: RGBA(0x252722, alpha: 0.7), title: 0x252722, font: .serif, place: .center),
        preset("min-clay", "Clay", .minimal, 0xC9776B, .none, font: .display, place: .bottom),

        // Academic
        preset("aca-composition", "Composition", .academic, 0x252722, .checks, pattern: RGBA(0xFFFFFF, alpha: 0.12), font: .serif, place: .label),
        preset("aca-ledger", "Ledger", .academic, 0x3F5873, .pinstripe, pattern: RGBA(0xFFFFFF, alpha: 0.14), font: .serif, place: .label),
        preset("aca-library", "Library", .academic, 0x8C4A3C, .linen, font: .serif, place: .label),
        preset("aca-graph", "Graph", .academic, 0xEEF1EA, .grid, pattern: RGBA(0x5F7059, alpha: 0.2), title: 0x2F3A2C, font: .mono, place: .label),
        preset("aca-kraft", "Kraft", .academic, 0xB5835A, .linen, pattern: RGBA(0x3B2A1A, alpha: 0.12), font: .mono, place: .label),

        // Abstract
        preset("abs-waves", "Waves", .abstract, 0x7C98B3, .waves, font: .display),
        preset("abs-arcs", "Arcs", .abstract, 0xE7B8A8, .arcs, pattern: RGBA(0x8C4A3C, alpha: 0.22), title: 0x4A2A22, font: .display),
        preset("abs-diagonal", "Diagonal", .abstract, 0x5B4F73, .diagonal, font: .display),
        preset("abs-stripes", "Stripes", .abstract, 0xA3B69A, .stripes, pattern: RGBA(0xFFFFFF, alpha: 0.28), title: 0x2F3A2C, font: .display),
        preset("abs-dots", "Confetti", .abstract, 0xF4EFE4, .dots, pattern: RGBA(0xC9776B, alpha: 0.45), title: 0x252722, font: .italic),
    ] + DedPalette.coverColors.enumerated().map { i, c in
        let dark = c.luminance < 0.45
        return CoverPreset(
            id: "solid-\(i)", name: c.hex, collection: .solid,
            design: CoverDesign(
                presetID: "solid-\(i)", color: c, pattern: .none,
                patternColor: dark ? RGBA(0xFFFFFF, alpha: 0.16) : RGBA(0x252722, alpha: 0.1),
                titleColor: dark ? .white : DedPalette.text, titleFont: .display, titlePlacement: .bottom
            )
        )
    }

    public static func presets(in collection: CoverCollection) -> [CoverPreset] {
        all.filter { $0.collection == collection }
    }

    public static func preset(id: String) -> CoverPreset? { all.first { $0.id == id } }

    /// A pleasant random cover for new notebooks.
    public static func random() -> CoverDesign {
        let pool = all.filter { $0.collection != .solid }
        return (pool.randomElement() ?? all[0]).design
    }
}
