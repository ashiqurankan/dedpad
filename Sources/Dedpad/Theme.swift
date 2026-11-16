import SwiftUI
import UIKit
import CoreText
import DedpadCore

// The Ded Notes look: warm paper backgrounds, restrained sage-green accent,
// DM Sans for UI text, Manrope for headings, an italic serif "d" as the mark.

extension UIColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }

    static func ded(light: UInt32, dark: UInt32, alpha: CGFloat = 1) -> UIColor {
        UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: dark, alpha: alpha) : UIColor(hex: light, alpha: alpha) }
    }
}

extension Color {
    static func ded(light: UInt32, dark: UInt32) -> Color { Color(uiColor: .ded(light: light, dark: dark)) }
}

extension RGBA {
    var uiColor: UIColor { UIColor(red: CGFloat(r), green: CGFloat(g), blue: CGFloat(b), alpha: CGFloat(a)) }
    var color: Color { Color(uiColor: uiColor) }

    init(_ color: Color) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 1
        UIColor(color).resolvedColor(with: UITraitCollection(userInterfaceStyle: .light)).getRed(&r, green: &g, blue: &b, alpha: &a)
        self.init(r: Double(r), g: Double(g), b: Double(b), a: Double(a))
    }
}

enum Ded {
    static let bg = Color.ded(light: 0xF7F7F5, dark: 0x171916)
    static let panel = Color.ded(light: 0xFFFFFF, dark: 0x1E211D)
    static let sidebar = Color.ded(light: 0xF1F1EE, dark: 0x191C18)
    static let text = Color.ded(light: 0x252722, dark: 0xECEEE8)
    static let muted = Color.ded(light: 0x6E7368, dark: 0xA3AA98)
    static let faint = Color.ded(light: 0x8D9187, dark: 0x8A917F)
    static let line = Color.ded(light: 0xE6E6E0, dark: 0x30352E)
    static let soft = Color.ded(light: 0xF2F2EE, dark: 0x262A24)
    static let accent = Color.ded(light: 0x5F7059, dark: 0xA3B69A)
    static let accentDark = Color.ded(light: 0x4D6049, dark: 0xC4D4BC)
    static let accentPale = Color.ded(light: 0xE9EEE6, dark: 0x2B3629)
    static let brand = Color(uiColor: UIColor(hex: 0x687B62))
    static let selectedLine = Color.ded(light: 0xD9E0D2, dark: 0x3D4639)
    static let danger = Color.ded(light: 0xB0493E, dark: 0xE08378)
    static let warn = Color.ded(light: 0xA8701C, dark: 0xD6A35A)
    static let ok = Color.ded(light: 0x5F9455, dark: 0x8FBF83)
    static let paperBack = Color.ded(light: 0xE9EDE4, dark: 0x20251E)
    static let canvasBackdrop = Color.ded(light: 0xECEDE8, dark: 0x121411)

    static let uiBackdrop = UIColor.ded(light: 0xECEDE8, dark: 0x121411)
    static let uiAccent = UIColor.ded(light: 0x5F7059, dark: 0xA3B69A)
}

// MARK: - Fonts

enum DedFont {
    enum Weight { case regular, medium, semibold, bold }

    static func sans(_ size: CGFloat, _ weight: Weight = .regular) -> Font {
        let name: String
        switch weight {
        case .regular: name = "DedSans-Regular"
        case .medium: name = "DedSans-Medium"
        case .semibold: name = "DedSans-SemiBold"
        case .bold: name = "DedSans-Bold"
        }
        return available(name) ? .custom(name, size: size) : .system(size: size, weight: weight.system)
    }

    enum DisplayWeight { case medium, bold, heavy }

    static func display(_ size: CGFloat, _ weight: DisplayWeight = .bold) -> Font {
        let name: String
        switch weight {
        case .medium: name = "DedDisplay-Medium"
        case .bold: name = "DedDisplay-Bold"
        case .heavy: name = "DedDisplay-ExtraBold"
        }
        let fallback: Font.Weight = weight == .medium ? .medium : (weight == .bold ? .bold : .heavy)
        return available(name) ? .custom(name, size: size) : .system(size: size, weight: fallback, design: .rounded)
    }

    /// The italic serif used for the "d" mark and accent words.
    static func mark(_ size: CGFloat) -> Font {
        available("Georgia-Italic") ? .custom("Georgia-Italic", size: size) : .system(size: size, design: .serif).italic()
    }

    static func uiSans(_ size: CGFloat, bold: Bool = false) -> UIFont {
        UIFont(name: bold ? "DedSans-Bold" : "DedSans-Regular", size: size)
            ?? .systemFont(ofSize: size, weight: bold ? .bold : .regular)
    }

    private static var cache: [String: Bool] = [:]
    private static func available(_ name: String) -> Bool {
        if let v = cache[name] { return v }
        let v = UIFont(name: name, size: 12) != nil
        cache[name] = v
        return v
    }

    /// Registers the bundled fonts wherever xtool placed them in the app bundle.
    /// (`UIAppFonts` in Info.plist covers the usual case; this is the safety net.)
    static func registerBundledFonts() {
        guard let e = FileManager.default.enumerator(at: Bundle.main.bundleURL, includingPropertiesForKeys: nil) else { return }
        for case let url as URL in e where ["ttf", "otf"].contains(url.pathExtension.lowercased()) {
            let name = url.deletingPathExtension().lastPathComponent
            if UIFont(name: name, size: 12) == nil {
                CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
            }
        }
        cache.removeAll()
    }
}

private extension DedFont.Weight {
    var system: Font.Weight {
        switch self {
        case .regular: return .regular
        case .medium: return .medium
        case .semibold: return .semibold
        case .bold: return .bold
        }
    }
}

// MARK: - Reusable pieces

/// The green rounded square with an italic "d".
struct BrandMark: View {
    var size: CGFloat = 31
    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.32, style: .continuous)
            .fill(Ded.brand)
            .frame(width: size, height: size)
            .overlay(Text("d").font(DedFont.mark(size * 0.74)).foregroundStyle(.white).offset(y: -size * 0.04))
            .shadow(color: Color(uiColor: UIColor(hex: 0x64745F, alpha: 0.19)), radius: 5, y: 4)
    }
}

struct BrandLockup: View {
    var body: some View {
        HStack(spacing: 10) {
            BrandMark()
            Text("dedpad")
                .font(DedFont.display(21, .heavy))
                .tracking(-1)
                .foregroundStyle(Ded.text)
        }
    }
}

/// Small uppercase label in the accent colour ("eyebrow" in Ded Notes).
struct Eyebrow: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(DedFont.sans(10.5, .bold))
            .tracking(1.6)
            .foregroundStyle(Ded.accent)
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(DedFont.sans(13.5, .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .frame(minHeight: 40)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(configuration.isPressed ? Color(uiColor: UIColor(hex: 0x56694F)) : Ded.brand)
            )
            .shadow(color: Color(uiColor: UIColor(hex: 0x536849, alpha: 0.14)), radius: 6, y: 5)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(DedFont.sans(13.5, .semibold))
            .foregroundStyle(Ded.text)
            .padding(.horizontal, 14)
            .frame(minHeight: 40)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(configuration.isPressed ? Ded.soft : Ded.panel)
            )
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(Ded.line, lineWidth: 1))
    }
}

/// Square icon button used in toolbars.
struct IconButtonStyle: ButtonStyle {
    var active = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 17, weight: .regular))
            .foregroundStyle(active ? Ded.accentDark : Ded.muted)
            .frame(width: 40, height: 40)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(active ? Ded.accentPale : (configuration.isPressed ? Ded.soft : Color.clear))
            )
            .contentShape(Rectangle())
    }
}

/// Grouped "card" section used in sheets.
struct DedSection<Content: View>: View {
    let title: String
    var footnote: String? = nil
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Eyebrow(text: title)
            VStack(alignment: .leading, spacing: 12) { content }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Ded.panel))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Ded.line, lineWidth: 1))
            if let footnote {
                Text(footnote).font(DedFont.sans(12)).foregroundStyle(Ded.muted).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// A circular colour swatch with a selection ring.
struct Swatch: View {
    let color: RGBA
    let selected: Bool
    var size: CGFloat = 30
    var body: some View {
        Circle()
            .fill(color.color)
            .frame(width: size, height: size)
            .overlay(Circle().stroke(Color.black.opacity(0.12), lineWidth: 0.5))
            .overlay(Circle().stroke(Ded.accent, lineWidth: 2).padding(-4).opacity(selected ? 1 : 0))
            .padding(4)
            .contentShape(Circle())
    }
}

extension View {
    /// Standard sheet chrome: warm background, title font.
    func dedSheetBackground() -> some View {
        self.scrollContentBackground(.hidden).background(Ded.bg)
    }
}
