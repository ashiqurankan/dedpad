import Foundation

/// A platform-independent sRGB colour, stored in JSON as `#RRGGBB` or `#RRGGBBAA`.
public struct RGBA: Hashable, Sendable, Codable {
    public var r: Double
    public var g: Double
    public var b: Double
    public var a: Double

    public init(r: Double, g: Double, b: Double, a: Double = 1) {
        // Quantised to 8 bits per channel so values survive the hex round trip exactly.
        self.r = r.quantised; self.g = g.quantised; self.b = b.quantised; self.a = a.quantised
    }

    /// `0xRRGGBB` literal.
    public init(_ hex: UInt32, alpha: Double = 1) {
        self.init(
            r: Double((hex >> 16) & 0xFF) / 255,
            g: Double((hex >> 8) & 0xFF) / 255,
            b: Double(hex & 0xFF) / 255,
            a: alpha
        )
    }

    /// Parses `#RGB`, `#RRGGBB` or `#RRGGBBAA` (the `#` is optional).
    public init?(hex string: String) {
        var s = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        guard s.count == 6 || s.count == 8, let v = UInt64(s, radix: 16) else { return nil }
        if s.count == 6 {
            self.init(UInt32(v))
        } else {
            self.init(
                r: Double((v >> 24) & 0xFF) / 255,
                g: Double((v >> 16) & 0xFF) / 255,
                b: Double((v >> 8) & 0xFF) / 255,
                a: Double(v & 0xFF) / 255
            )
        }
    }

    public var hex: String {
        func c(_ v: Double) -> String { String(format: "%02X", Int((v * 255).rounded())) }
        return a >= 0.999 ? "#\(c(r))\(c(g))\(c(b))" : "#\(c(r))\(c(g))\(c(b))\(c(a))"
    }

    /// Opaque `#RRGGBB` for SVG output (opacity is written separately).
    public var svgRGB: String { String(hex.prefix(7)) }

    /// Relative luminance (WCAG).
    public var luminance: Double {
        func lin(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
    }

    public var isDark: Bool { luminance < 0.22 }

    public func withAlpha(_ alpha: Double) -> RGBA { RGBA(r: r, g: g, b: b, a: alpha) }

    /// Linear mix towards `other` (t = 0 → self, t = 1 → other).
    public func mixed(with other: RGBA, _ t: Double) -> RGBA {
        RGBA(r: r + (other.r - r) * t, g: g + (other.g - g) * t, b: b + (other.b - b) * t, a: a + (other.a - a) * t)
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        let s = try c.decode(String.self)
        guard let v = RGBA(hex: s) else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Invalid colour \(s)")
        }
        self = v
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(hex)
    }

    public static let white = RGBA(0xFFFFFF)
    public static let black = RGBA(0x000000)
}

private extension Double {
    var clamped01: Double { Swift.min(1, Swift.max(0, self.isFinite ? self : 0)) }
    var quantised: Double { (clamped01 * 255).rounded() / 255 }
}

/// The Ded Notes palette, shared by covers, paper and the UI.
public enum DedPalette {
    public static let brand = RGBA(0x687B62)
    public static let accent = RGBA(0x5F7059)
    public static let accentPale = RGBA(0xE9EEE6)
    public static let text = RGBA(0x252722)
    public static let paper = RGBA(0xFFFFFF)
    public static let warmPaper = RGBA(0xFBF8F1)
    public static let paperLine = RGBA(0xD9DED3)
    public static let marginLine = RGBA(0xD9A9A0)

    /// Paper colours offered in the customisation studio.
    public static let paperColors: [RGBA] = [
        RGBA(0xFFFFFF), RGBA(0xFBF8F1), RGBA(0xF7F7F5), RGBA(0xF4F1E6), RGBA(0xEEF1EA),
        RGBA(0xEAF0F4), RGBA(0xF6ECEA), RGBA(0x2B2E29), RGBA(0x1E211D), RGBA(0x18202A),
    ]

    /// Line colours offered in the customisation studio.
    public static let lineColors: [RGBA] = [
        RGBA(0xD9DED3), RGBA(0xC9D3E0), RGBA(0xE2CFC9), RGBA(0xBFC5B8), RGBA(0xA9B6A2),
        RGBA(0x8EA3BD), RGBA(0x3E443A), RGBA(0x4A5560),
    ]

    /// Cover colours offered in the customisation studio.
    public static let coverColors: [RGBA] = [
        RGBA(0x687B62), RGBA(0x4D6049), RGBA(0x2F3A2C), RGBA(0xA3B69A), RGBA(0xE9EEE6),
        RGBA(0xF4EFE4), RGBA(0xD8C7A8), RGBA(0xB5835A), RGBA(0x8C4A3C), RGBA(0xC9776B),
        RGBA(0xE7B8A8), RGBA(0x3F5873), RGBA(0x7C98B3), RGBA(0x5B4F73), RGBA(0x252722),
        RGBA(0xFFFFFF),
    ]
}
