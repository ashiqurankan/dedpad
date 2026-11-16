import Foundation

/// A handwriting stroke flattened for vector export.
public struct VectorStroke: Sendable, Equatable {
    public struct Point: Sendable, Equatable {
        public var x: Double, y: Double, width: Double
        public init(x: Double, y: Double, width: Double) { self.x = x; self.y = y; self.width = width }
    }
    public var points: [Point]
    public var color: RGBA
    /// Marker / highlighter strokes are translucent.
    public var opacity: Double
    public init(points: [Point], color: RGBA, opacity: Double = 1) {
        self.points = points; self.color = color; self.opacity = opacity
    }
}

public enum SVGWriter {

    /// - Parameters:
    ///   - paper: when non-nil, the paper colour and template are drawn under the strokes.
    public static func document(
        size: PageDimensions,
        paper: PaperSpec?,
        pageNumber: PaperPrimitive? = nil,
        strokes: [VectorStroke],
        title: String? = nil
    ) -> String {
        var s = """
        <?xml version="1.0" encoding="UTF-8"?>
        <svg xmlns="http://www.w3.org/2000/svg" width="\(n(size.width))" height="\(n(size.height))" viewBox="0 0 \(n(size.width)) \(n(size.height))">

        """
        if let title { s += "  <title>\(escape(title))</title>\n" }
        if let paper {
            s += "  <rect width=\"100%\" height=\"100%\" fill=\"\(paper.background.svgRGB)\"/>\n"
            s += "  <g id=\"paper\" stroke-linecap=\"butt\">\n"
            var prims = PaperLayout.primitives(for: paper, size: size)
            if let pageNumber { prims.append(pageNumber) }
            for p in prims { s += "    " + element(p, paper) + "\n" }
            s += "  </g>\n"
        }
        s += "  <g id=\"ink\" fill=\"none\" stroke-linecap=\"round\" stroke-linejoin=\"round\">\n"
        for stroke in strokes { s += strokeElement(stroke) }
        s += "  </g>\n</svg>\n"
        return s
    }

    static func strokeElement(_ stroke: VectorStroke) -> String {
        guard let first = stroke.points.first else { return "" }
        let color = stroke.color.svgRGB
        let opacity = stroke.opacity * stroke.color.a
        let op = opacity < 0.999 ? " stroke-opacity=\"\(n(opacity))\"" : ""
        if stroke.points.count == 1 {
            return "    <circle cx=\"\(n(first.x))\" cy=\"\(n(first.y))\" r=\"\(n(max(0.3, first.width / 2)))\" fill=\"\(color)\"\(opacity < 0.999 ? " fill-opacity=\"\(n(opacity))\"" : "")/>\n"
        }
        // Split into runs of similar width so pressure variation survives without one element per segment.
        var out = ""
        var run: [VectorStroke.Point] = [first]
        func flush() {
            guard run.count > 1 else { return }
            let w = run.map(\.width).reduce(0, +) / Double(run.count)
            var d = "M\(n(run[0].x)) \(n(run[0].y))"
            for p in run.dropFirst() { d += "L\(n(p.x)) \(n(p.y))" }
            out += "    <path d=\"\(d)\" stroke=\"\(color)\" stroke-width=\"\(n(max(0.2, w)))\"\(op)/>\n"
        }
        for p in stroke.points.dropFirst() {
            run.append(p)
            let w0 = run[0].width
            if abs(p.width - w0) > max(0.6, w0 * 0.25) && run.count > 2 {
                flush()
                run = [p]
            }
        }
        flush()
        return out
    }

    static func element(_ p: PaperPrimitive, _ spec: PaperSpec) -> String {
        func c(_ ink: PaperInk) -> String { spec.color(for: ink).svgRGB }
        func a(_ ink: PaperInk, _ extra: Double = 1, fill: Bool = false) -> String {
            let alpha = spec.color(for: ink).a * extra
            return alpha < 0.999 ? " \(fill ? "fill" : "stroke")-opacity=\"\(n(alpha))\"" : ""
        }
        switch p {
        case let .line(x1, y1, x2, y2, w, ink):
            return "<line x1=\"\(n(x1))\" y1=\"\(n(y1))\" x2=\"\(n(x2))\" y2=\"\(n(y2))\" stroke=\"\(c(ink))\" stroke-width=\"\(n(w))\"\(a(ink))/>"
        case let .rect(x, y, w, h, sw, ink, r):
            return "<rect x=\"\(n(x))\" y=\"\(n(y))\" width=\"\(n(w))\" height=\"\(n(h))\" rx=\"\(n(r))\" fill=\"none\" stroke=\"\(c(ink))\" stroke-width=\"\(n(sw))\"\(a(ink))/>"
        case let .fill(x, y, w, h, ink, opacity, r):
            return "<rect x=\"\(n(x))\" y=\"\(n(y))\" width=\"\(n(w))\" height=\"\(n(h))\" rx=\"\(n(r))\" fill=\"\(c(ink))\"\(a(ink, opacity, fill: true))/>"
        case let .dot(x, y, r, ink):
            return "<circle cx=\"\(n(x))\" cy=\"\(n(y))\" r=\"\(n(r))\" fill=\"\(c(ink))\"\(a(ink, fill: true))/>"
        case let .ellipse(x, y, w, h, sw, ink):
            return "<ellipse cx=\"\(n(x + w / 2))\" cy=\"\(n(y + h / 2))\" rx=\"\(n(w / 2))\" ry=\"\(n(h / 2))\" fill=\"none\" stroke=\"\(c(ink))\" stroke-width=\"\(n(sw))\"\(a(ink))/>"
        case let .text(t, x, y, size, bold, ink, align):
            let anchor: String
            switch align {
            case .left: anchor = "start"
            case .center: anchor = "middle"
            case .right: anchor = "end"
            }
            return "<text x=\"\(n(x))\" y=\"\(n(y))\" font-family=\"DM Sans, Helvetica, Arial, sans-serif\" font-size=\"\(n(size))\" font-weight=\"\(bold ? 700 : 400)\" letter-spacing=\"\(bold ? n(size * 0.08) : "0")\" text-anchor=\"\(anchor)\" fill=\"\(c(ink))\"\(a(ink, fill: true))>\(escape(t))</text>"
        }
    }

    /// Compact number formatting (max two decimals, no trailing zeros).
    static func n(_ v: Double) -> String {
        guard v.isFinite else { return "0" }
        let r = (v * 100).rounded() / 100
        if r == r.rounded() { return String(Int(r)) }
        var s = String(format: "%.2f", r)
        while s.hasSuffix("0") { s.removeLast() }
        return s
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
