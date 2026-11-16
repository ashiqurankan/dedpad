import UIKit
import PencilKit
import DedpadCore

/// PencilKit ⇄ dedpad's open ink format, and programmatic strokes (shapes).
enum InkConverter {

    static func toolName(_ t: PKInk.InkType) -> String {
        switch t {
        case .pen: return "pen"
        case .pencil: return "pencil"
        case .marker: return "marker"
        default:
            if #available(iOS 17.0, *) {
                switch t {
                case .monoline: return "monoline"
                case .fountainPen: return "fountainPen"
                case .watercolor: return "watercolor"
                case .crayon: return "crayon"
                default: break
                }
            }
            return "pen"
        }
    }

    static func inkType(_ name: String) -> PKInk.InkType {
        switch name {
        case "pencil": return .pencil
        case "marker": return .marker
        case "monoline": if #available(iOS 17.0, *) { return .monoline } else { return .pen }
        case "fountainPen": if #available(iOS 17.0, *) { return .fountainPen } else { return .pen }
        case "watercolor": if #available(iOS 17.0, *) { return .watercolor } else { return .marker }
        case "crayon": if #available(iOS 17.0, *) { return .crayon } else { return .pencil }
        default: return .pen
        }
    }

    /// Flattens a drawing into the open format (page coordinates).
    static func inkPage(from drawing: PKDrawing, size: PageDimensions) -> InkPage {
        let light = UITraitCollection(userInterfaceStyle: .light)
        let strokes: [InkStroke] = drawing.strokes.map { s in
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 1
            s.ink.color.resolvedColor(with: light).getRed(&r, green: &g, blue: &b, alpha: &a)
            let t = s.transform
            let pts: [InkPoint] = s.path.interpolatedPoints(by: .distance(1.5)).map { p in
                InkPoint(x: Double(p.location.x), y: Double(p.location.y), t: p.timeOffset,
                         width: Double(p.size.width), height: Double(p.size.height), opacity: Double(p.opacity),
                         force: Double(p.force), azimuth: Double(p.azimuth), altitude: Double(p.altitude))
            }
            return InkStroke(tool: toolName(s.ink.inkType), color: RGBA(r: Double(r), g: Double(g), b: Double(b), a: Double(a)),
                             transform: [t.a, t.b, t.c, t.d, t.tx, t.ty].map(Double.init), points: pts)
        }
        return InkPage(width: size.width, height: size.height, strokes: strokes)
    }

    /// Rebuilds a PencilKit drawing from the open format (used if the PencilKit file is lost).
    static func drawing(from ink: InkPage) -> PKDrawing {
        let strokes: [PKStroke] = ink.strokes.compactMap { s in
            guard !s.points.isEmpty else { return nil }
            let date = Date()
            let points = s.points.map { p in
                PKStrokePoint(location: CGPoint(x: p.x, y: p.y), timeOffset: p.t,
                              size: CGSize(width: p.width, height: p.height), opacity: CGFloat(p.opacity),
                              force: CGFloat(p.force), azimuth: CGFloat(p.azimuth), altitude: CGFloat(p.altitude))
            }
            let t = s.transform
            let transform = CGAffineTransform(a: t[0], b: t[1], c: t[2], d: t[3], tx: t[4], ty: t[5])
            return PKStroke(ink: PKInk(inkType(s.tool), color: s.color.uiColor),
                            path: PKStrokePath(controlPoints: points, creationDate: date), transform: transform, mask: nil)
        }
        return PKDrawing(strokes: strokes)
    }

    // MARK: Shapes

    enum Shape: String, CaseIterable, Identifiable {
        case line, arrow, rectangle, ellipse, triangle
        var id: String { rawValue }
        var name: String { rawValue.capitalized }
        var symbol: String {
            switch self {
            case .line: return "line.diagonal"
            case .arrow: return "arrow.up.right"
            case .rectangle: return "rectangle"
            case .ellipse: return "circle"
            case .triangle: return "triangle"
            }
        }
    }

    /// Point lists (one per stroke) describing a shape dragged from `a` to `b`.
    static func outline(_ shape: Shape, from a: CGPoint, to b: CGPoint) -> [[CGPoint]] {
        let r = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
        switch shape {
        case .line:
            return [sample([a, b])]
        case .arrow:
            let angle = atan2(b.y - a.y, b.x - a.x)
            let len = min(28, max(10, hypot(b.x - a.x, b.y - a.y) * 0.25))
            let l = CGPoint(x: b.x - len * cos(angle - .pi / 7), y: b.y - len * sin(angle - .pi / 7))
            let rr = CGPoint(x: b.x - len * cos(angle + .pi / 7), y: b.y - len * sin(angle + .pi / 7))
            return [sample([a, b]), sample([l, b, rr])]
        case .rectangle:
            return [sample([CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
                            CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.minX, y: r.minY)])]
        case .triangle:
            return [sample([CGPoint(x: r.midX, y: r.minY), CGPoint(x: r.maxX, y: r.maxY),
                            CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.midX, y: r.minY)])]
        case .ellipse:
            let n = max(24, Int((r.width + r.height) / 4))
            return [(0...n).map { i in
                let t = CGFloat(i) / CGFloat(n) * 2 * .pi
                return CGPoint(x: r.midX + r.width / 2 * cos(t), y: r.midY + r.height / 2 * sin(t))
            }]
        }
    }

    /// Densely samples a polyline so PencilKit's spline follows straight edges and sharp corners.
    static func sample(_ pts: [CGPoint], step: CGFloat = 3) -> [CGPoint] {
        guard pts.count > 1 else { return pts }
        var out: [CGPoint] = [pts[0]]
        for (p, q) in zip(pts, pts.dropFirst()) {
            let d = hypot(q.x - p.x, q.y - p.y)
            let n = max(1, Int(d / step))
            for i in 1...n {
                let t = CGFloat(i) / CGFloat(n)
                out.append(CGPoint(x: p.x + (q.x - p.x) * t, y: p.y + (q.y - p.y) * t))
            }
            // Repeat corners so the spline doesn't round them off.
            out.append(q); out.append(q)
        }
        return out
    }

    static func stroke(_ points: [CGPoint], ink: PKInk, width: CGFloat) -> PKStroke {
        let pts = points.enumerated().map { i, p in
            PKStrokePoint(location: p, timeOffset: TimeInterval(i) * 0.004, size: CGSize(width: width, height: width),
                          opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }
        return PKStroke(ink: ink, path: PKStrokePath(controlPoints: pts, creationDate: Date()), transform: .identity, mask: nil)
    }
}
