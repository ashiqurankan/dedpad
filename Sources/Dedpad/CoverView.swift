import SwiftUI
import DedpadCore

/// A notebook cover: colour, pattern, optional photo, spine and title.
struct CoverView: View {
    let design: CoverDesign
    let title: String
    var image: UIImage? = nil
    /// Width / height of the cover (defaults to a portrait notebook).
    var aspect: CGFloat = 0.75
    var showsShadow = true

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            ZStack(alignment: .topLeading) {
                design.color.color

                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: w, height: h)
                        .clipped()
                    Color.black.opacity(design.imageDim)
                }

                Canvas { ctx, size in
                    CoverPatternPainter.paint(design.pattern, color: design.patternColor.color, in: &ctx, size: size)
                }

                // Spine
                HStack(spacing: 0) {
                    LinearGradient(
                        colors: [Color.black.opacity(0.22), Color.black.opacity(0.06), Color.white.opacity(0.10), Color.clear],
                        startPoint: .leading, endPoint: .trailing
                    )
                    .frame(width: max(8, w * 0.075))
                    Spacer(minLength: 0)
                }

                titleView(w: w, h: h)
            }
            .frame(width: w, height: h)
            .clipShape(CoverShape(radius: max(4, w * 0.045)))
            .overlay(CoverShape(radius: max(4, w * 0.045)).stroke(Color.black.opacity(0.08), lineWidth: 0.5))
        }
        .aspectRatio(aspect, contentMode: .fit)
        .shadow(color: showsShadow ? Color(red: 0.16, green: 0.18, blue: 0.14).opacity(0.18) : .clear, radius: 10, x: 0, y: 8)
    }

    @ViewBuilder
    private func titleView(w: CGFloat, h: CGFloat) -> some View {
        let text = title.isEmpty ? "Untitled" : title
        let size = max(9, w * 0.105)
        switch design.titlePlacement {
        case .hidden:
            EmptyView()
        case .label:
            VStack {
                Spacer().frame(height: h * 0.2)
                Text(text)
                    .font(titleFont(size * 0.78))
                    .foregroundStyle(design.color.isDark || design.color.luminance < 0.5 ? DedPalette.text.color : design.titleColor.color)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .minimumScaleFactor(0.6)
                    .padding(.horizontal, w * 0.06)
                    .padding(.vertical, w * 0.045)
                    .frame(width: w * 0.62)
                    .background(
                        RoundedRectangle(cornerRadius: w * 0.025, style: .continuous)
                            .fill(Color(white: 0.985))
                            .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: w * 0.02, style: .continuous)
                            .stroke(design.color.color.opacity(0.35), lineWidth: max(0.5, w * 0.004))
                            .padding(w * 0.015)
                    )
                Spacer()
            }
            .frame(width: w, height: h)
            .offset(x: w * 0.03)
        default:
            VStack(alignment: .leading, spacing: 0) {
                if design.titlePlacement != .top { Spacer(minLength: 0) }
                Text(text)
                    .font(titleFont(size))
                    .tracking(design.titleFont == .display ? -size * 0.04 : 0)
                    .foregroundStyle(design.titleColor.color)
                    .lineLimit(4)
                    .minimumScaleFactor(0.5)
                    .multilineTextAlignment(design.titlePlacement == .center ? .center : .leading)
                    .frame(maxWidth: .infinity, alignment: design.titlePlacement == .center ? .center : .leading)
                    .shadow(color: image != nil ? .black.opacity(0.35) : .clear, radius: 3, y: 1)
                if design.titlePlacement != .bottom { Spacer(minLength: 0) }
            }
            .padding(.leading, w * 0.15)
            .padding(.trailing, w * 0.09)
            .padding(.vertical, h * 0.09)
            .frame(width: w, height: h)
        }
    }

    private func titleFont(_ size: CGFloat) -> Font {
        switch design.titleFont {
        case .display: return DedFont.display(size, .heavy)
        case .sans: return DedFont.sans(size, .semibold)
        case .serif: return .system(size: size, weight: .semibold, design: .serif)
        case .italic: return DedFont.mark(size * 1.05)
        case .mono: return .system(size: size * 0.85, weight: .semibold, design: .monospaced)
        }
    }
}

/// Square-ish on the spine side, rounder on the opening edge.
struct CoverShape: Shape {
    var radius: CGFloat
    func path(in rect: CGRect) -> Path {
        let small = radius * 0.35
        return Path(roundedRect: rect, cornerRadii: RectangleCornerRadii(
            topLeading: small, bottomLeading: small, bottomTrailing: radius, topTrailing: radius
        ), style: .continuous)
    }
}

enum CoverPatternPainter {
    static func paint(_ pattern: CoverPattern, color: Color, in ctx: inout GraphicsContext, size: CGSize) {
        let w = size.width, h = size.height
        let unit = max(4, w / 24)
        var path = Path()
        var lineWidth = max(0.6, w * 0.006)
        var fill = false

        switch pattern {
        case .none:
            return
        case .stripes:
            lineWidth = unit * 0.9
            var x = unit
            while x < w { path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: h)); x += unit * 2.6 }
        case .pinstripe:
            var x = unit * 0.6
            while x < w { path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: h)); x += unit * 0.8 }
        case .dots:
            fill = true
            let r = unit * 0.16
            var y = unit * 0.7
            var row = 0
            while y < h {
                var x = unit * (row % 2 == 0 ? 0.7 : 1.3)
                while x < w { path.addEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)); x += unit * 1.2 }
                y += unit * 1.05; row += 1
            }
        case .grid:
            var x = unit * 0.5
            while x < w { path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: h)); x += unit }
            var y = unit * 0.5
            while y < h { path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: w, y: y)); y += unit }
        case .diagonal:
            lineWidth = unit * 0.35
            var x = -h
            while x < w { path.move(to: CGPoint(x: x, y: h)); path.addLine(to: CGPoint(x: x + h, y: 0)); x += unit * 1.4 }
        case .linen:
            lineWidth = max(0.4, w * 0.003)
            var x: CGFloat = 0
            var i = 0
            while x < w {
                path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: h))
                x += unit * (i % 3 == 0 ? 0.22 : 0.31); i += 1
            }
            var y: CGFloat = 0
            i = 0
            while y < h {
                path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: w, y: y))
                y += unit * (i % 4 == 0 ? 0.2 : 0.29); i += 1
            }
        case .waves:
            lineWidth = max(1, w * 0.012)
            var y = unit
            while y < h + unit {
                path.move(to: CGPoint(x: 0, y: y))
                var x: CGFloat = 0
                while x < w {
                    path.addQuadCurve(to: CGPoint(x: x + unit * 2, y: y), control: CGPoint(x: x + unit, y: y - unit * 0.7))
                    x += unit * 2
                }
                y += unit * 1.6
            }
        case .arcs:
            lineWidth = max(1, w * 0.014)
            let center = CGPoint(x: w * 1.05, y: h * 1.02)
            var r = unit * 2
            while r < max(w, h) * 1.6 {
                path.addEllipse(in: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2))
                r += unit * 1.5
            }
        case .checks:
            fill = true
            let c = unit * 0.9
            var y: CGFloat = 0
            var row = 0
            while y < h {
                var x = (row % 2 == 0) ? 0 : c
                while x < w { path.addRect(CGRect(x: x, y: y, width: c, height: c)); x += c * 2 }
                y += c; row += 1
            }
        case .frame:
            lineWidth = max(1, w * 0.008)
            let inset = w * 0.1
            path.addRoundedRect(in: CGRect(x: inset + w * 0.03, y: inset, width: w - inset * 2 - w * 0.03, height: h - inset * 2), cornerSize: CGSize(width: w * 0.02, height: w * 0.02))
            let inner = inset + w * 0.025
            path.addRoundedRect(in: CGRect(x: inner + w * 0.03, y: inner, width: w - inner * 2 - w * 0.03, height: h - inner * 2), cornerSize: CGSize(width: w * 0.015, height: w * 0.015))
        }

        if fill {
            ctx.fill(path, with: .color(color))
        } else {
            ctx.stroke(path, with: .color(color), lineWidth: lineWidth)
        }
    }
}
