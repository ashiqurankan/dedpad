import Foundation

/// Turns a hand-drawn stroke into a clean shape ("draw and hold" to snap).
public enum ShapeRecognizer {

    public struct Point: Equatable, Sendable {
        public var x: Double, y: Double
        public init(_ x: Double, _ y: Double) { self.x = x; self.y = y }
    }

    public enum Shape: Equatable, Sendable {
        case line(Point, Point)
        /// An open path of 2–3 straight segments (an "L", a "V", a "Z").
        case polyline([Point])
        /// A closed polygon (triangle, rectangle or other quadrilateral), corners in order.
        case polygon([Point])
        /// An ellipse (circles included), `rotation` in radians.
        case ellipse(center: Point, rx: Double, ry: Double, rotation: Double)

        public var name: String {
            switch self {
            case .line: return "line"
            case .polyline: return "polyline"
            case let .polygon(p): return p.count == 3 ? "triangle" : (p.count == 4 ? "quadrilateral" : "polygon")
            case let .ellipse(_, rx, ry, _): return abs(rx - ry) < 0.001 ? "circle" : "ellipse"
            }
        }

        /// The shape scaled about `center` (used to resize it while the Pencil is still down).
        public func scaled(by k: Double, about c: Point) -> Shape {
            func s(_ p: Point) -> Point { Point(c.x + (p.x - c.x) * k, c.y + (p.y - c.y) * k) }
            switch self {
            case let .line(a, b): return .line(s(a), s(b))
            case let .polyline(p): return .polyline(p.map(s))
            case let .polygon(p): return .polygon(p.map(s))
            case let .ellipse(e, rx, ry, r): return .ellipse(center: s(e), rx: rx * k, ry: ry * k, rotation: r)
            }
        }

        public var center: Point {
            switch self {
            case let .ellipse(c, _, _, _): return c
            case let .line(a, b): return Point((a.x + b.x) / 2, (a.y + b.y) / 2)
            case let .polyline(p), let .polygon(p):
                let b = ShapeRecognizer.bounds(p)
                return Point(b.x + b.w / 2, b.y + b.h / 2)
            }
        }
    }

    public static func recognize(_ raw: [Point]) -> Shape? {
        let pts0 = dedupe(raw)
        guard pts0.count >= 2 else { return nil }
        let length0 = pathLength(pts0)
        guard length0 > 12 else { return nil }
        let pts = resample(pts0, step: max(1.5, length0 / 160))
        guard let first = pts.first, let last = pts.last else { return nil }
        let box = bounds(pts)
        let diag = max(hypot(box.w, box.h), 1)

        // 1. A straight stroke → line (levelled to horizontal / vertical / 45° when close).
        let chord = dist(first, last)
        let deviation = pts.map { perpendicular($0, first, last) }.max() ?? 0
        if chord > length0 * 0.8 && deviation <= max(4, chord * 0.07) {
            return .line(first, snapAngle(first, last))
        }

        // 2. Closed? The end comes back near the start (overshoot trimmed).
        let closeTolerance = max(18, diag * 0.28)
        var closeIndex: Int?
        let searchFrom = Int(Double(pts.count) * 0.55)
        if searchFrom < pts.count {
            var best = Double.infinity
            for i in searchFrom..<pts.count {
                let d = dist(pts[i], first)
                if d < best { best = d; closeIndex = i }
            }
            if best > closeTolerance { closeIndex = nil }
        }
        if let ci = closeIndex {
            return closedShape(Array(pts[...ci]), diag: diag)
        }

        // 3. Open path with a few sharp turns → polyline.
        let corners = rdp(pts, epsilon: max(5, diag * 0.07))
        guard (3...4).contains(corners.count) else { return nil }
        let err = meanDistance(pts, toPath: corners)
        guard err < max(3, diag * 0.04) else { return nil }
        var snapped = [corners[0]]
        for c in corners.dropFirst() { snapped.append(snapAngle(snapped.last!, c)) }
        return .polyline(snapped)
    }

    private static func closedShape(_ pts: [Point], diag: Double) -> Shape? {
        // Ellipse fit (orientation from the covariance of the outline).
        let n = Double(pts.count)
        let cx = pts.reduce(0) { $0 + $1.x } / n, cy = pts.reduce(0) { $0 + $1.y } / n
        var sxx = 0.0, syy = 0.0, sxy = 0.0
        for p in pts { let dx = p.x - cx, dy = p.y - cy; sxx += dx * dx; syy += dy * dy; sxy += dx * dy }
        sxx /= n; syy /= n; sxy /= n
        var theta = 0.5 * atan2(2 * sxy, sxx - syy)
        let cosT = cos(theta), sinT = sin(theta)
        var maxU = 0.0, maxV = 0.0, minU = 0.0, minV = 0.0
        for p in pts {
            let dx = p.x - cx, dy = p.y - cy
            let u = dx * cosT + dy * sinT, v = -dx * sinT + dy * cosT
            maxU = max(maxU, u); minU = min(minU, u); maxV = max(maxV, v); minV = min(minV, v)
        }
        var rx = (maxU - minU) / 2, ry = (maxV - minV) / 2
        let ec = Point(cx + cosT * (maxU + minU) / 2 - sinT * (maxV + minV) / 2,
                       cy + sinT * (maxU + minU) / 2 + cosT * (maxV + minV) / 2)
        guard rx > 2, ry > 2 else { return nil }
        let ellipseErr = pts.map { p -> Double in
            let dx = p.x - ec.x, dy = p.y - ec.y
            let u = (dx * cosT + dy * sinT) / rx, v = (-dx * sinT + dy * cosT) / ry
            return abs(sqrt(u * u + v * v) - 1) * sqrt(rx * ry)
        }.reduce(0, +) / n

        // Polygon fit: corners from a closed simplification.
        var closed = pts
        closed.append(pts[0])
        var corners = Array(rdp(closed, epsilon: max(5, diag * 0.07)).dropLast())
        corners = mergeClose(corners, minDistance: diag * 0.15)
        corners = dropFlat(corners)
        var polyErr = Double.infinity
        if (3...4).contains(corners.count) {
            polyErr = meanDistance(pts, toPath: corners + [corners[0]])
        }

        let best = min(polyErr, ellipseErr)
        guard best < diag * 0.06 else { return nil }    // too messy to be a shape

        if polyErr < ellipseErr * 0.85 {
            if corners.count == 4, let rect = rectangle(corners) { return .polygon(rect) }
            return .polygon(corners)
        }
        // Level near-axis ellipses; make near-circles exact.
        let deg = theta * 180 / .pi
        let off = deg - (deg / 90).rounded() * 90
        if abs(off) < 10 {
            let swap = Int((deg / 90).rounded()) % 2 != 0
            theta = 0
            if swap { swap2(&rx, &ry) }
        }
        if abs(rx - ry) < max(rx, ry) * 0.15 { let r = (rx + ry) / 2; rx = r; ry = r; theta = 0 }
        return .ellipse(center: ec, rx: rx, ry: ry, rotation: theta)
    }

    private static func swap2(_ a: inout Double, _ b: inout Double) { let t = a; a = b; b = t }

    /// A quadrilateral with near-right angles becomes an exact (possibly rotated) rectangle.
    static func rectangle(_ c: [Point]) -> [Point]? {
        guard c.count == 4 else { return nil }
        for i in 0..<4 {
            let a = c[(i + 3) % 4], b = c[i], d = c[(i + 1) % 4]
            let v1 = (a.x - b.x, a.y - b.y), v2 = (d.x - b.x, d.y - b.y)
            let cosA = (v1.0 * v2.0 + v1.1 * v2.1) / max(hypot(v1.0, v1.1) * hypot(v2.0, v2.1), 1e-9)
            if abs(cosA) > 0.27 { return nil }    // more than ~15° off square
        }
        // Average edge direction modulo 90°.
        var sx = 0.0, sy = 0.0
        for i in 0..<4 {
            let a = c[i], b = c[(i + 1) % 4]
            let ang = atan2(b.y - a.y, b.x - a.x) * 4
            let w = dist(a, b)
            sx += cos(ang) * w; sy += sin(ang) * w
        }
        var theta = atan2(sy, sx) / 4
        if abs(theta) < 7 * .pi / 180 { theta = 0 }
        let ct = cos(theta), st = sin(theta)
        let local = c.map { Point($0.x * ct + $0.y * st, -$0.x * st + $0.y * ct) }
        let b = bounds(local)
        let box = [Point(b.x, b.y), Point(b.x + b.w, b.y), Point(b.x + b.w, b.y + b.h), Point(b.x, b.y + b.h)]
        return box.map { Point($0.x * ct - $0.y * st, $0.x * st + $0.y * ct) }
    }

    /// Outline points (closed shapes end where they start).
    public static func outline(_ shape: Shape, segments: Int = 72) -> [Point] {
        switch shape {
        case let .line(a, b): return [a, b]
        case let .polyline(p): return p
        case let .polygon(p): return p + (p.first.map { [$0] } ?? [])
        case let .ellipse(c, rx, ry, r):
            let cr = cos(r), sr = sin(r)
            return (0...segments).map { i in
                let t = Double(i) / Double(segments) * 2 * .pi
                let x = rx * cos(t), y = ry * sin(t)
                return Point(c.x + x * cr - y * sr, c.y + x * sr + y * cr)
            }
        }
    }

    // MARK: Geometry

    static func dist(_ a: Point, _ b: Point) -> Double { hypot(a.x - b.x, a.y - b.y) }

    static func pathLength(_ p: [Point]) -> Double {
        zip(p, p.dropFirst()).reduce(0) { $0 + dist($1.0, $1.1) }
    }

    static func bounds(_ p: [Point]) -> (x: Double, y: Double, w: Double, h: Double) {
        let xs = p.map(\.x), ys = p.map(\.y)
        let minX = xs.min() ?? 0, minY = ys.min() ?? 0
        return (minX, minY, (xs.max() ?? 0) - minX, (ys.max() ?? 0) - minY)
    }

    static func dedupe(_ p: [Point]) -> [Point] {
        var out: [Point] = []
        for q in p where out.last.map({ dist($0, q) > 0.5 }) ?? true { out.append(q) }
        return out
    }

    /// Evenly spaced points along the path (so slow and fast parts weigh the same).
    static func resample(_ p: [Point], step: Double) -> [Point] {
        guard p.count > 1, step > 0 else { return p }
        var out = [p[0]]
        var carry = 0.0
        for (a, b) in zip(p, p.dropFirst()) {
            let d = dist(a, b)
            guard d > 0 else { continue }
            var t = step - carry
            while t <= d {
                out.append(Point(a.x + (b.x - a.x) * t / d, a.y + (b.y - a.y) * t / d))
                t += step
            }
            carry = d - (t - step)
        }
        if let l = p.last, let o = out.last, dist(l, o) > 0.5 { out.append(l) }
        return out
    }

    /// Ramer–Douglas–Peucker simplification.
    static func rdp(_ p: [Point], epsilon: Double) -> [Point] {
        guard p.count > 2, let a = p.first, let b = p.last else { return p }
        var maxD = 0.0, index = 0
        for i in 1..<(p.count - 1) {
            let d = dist(a, b) < 1e-6 ? dist(p[i], a) : perpendicular(p[i], a, b)
            if d > maxD { maxD = d; index = i }
        }
        guard maxD > epsilon else { return [a, b] }
        let left = rdp(Array(p[...index]), epsilon: epsilon)
        let right = rdp(Array(p[index...]), epsilon: epsilon)
        return Array(left.dropLast()) + right
    }

    static func perpendicular(_ p: Point, _ a: Point, _ b: Point) -> Double {
        let len = dist(a, b)
        guard len > 0 else { return dist(p, a) }
        return abs((b.x - a.x) * (a.y - p.y) - (a.x - p.x) * (b.y - a.y)) / len
    }

    static func segmentDistance(_ p: Point, _ a: Point, _ b: Point) -> Double {
        let dx = b.x - a.x, dy = b.y - a.y
        let l2 = dx * dx + dy * dy
        guard l2 > 0 else { return dist(p, a) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / l2))
        return dist(p, Point(a.x + dx * t, a.y + dy * t))
    }

    static func meanDistance(_ pts: [Point], toPath path: [Point]) -> Double {
        guard path.count > 1, !pts.isEmpty else { return .infinity }
        let segs = Array(zip(path, path.dropFirst()))
        return pts.map { p in segs.map { segmentDistance(p, $0.0, $0.1) }.min() ?? 0 }.reduce(0, +) / Double(pts.count)
    }

    static func mergeClose(_ p: [Point], minDistance: Double) -> [Point] {
        var out: [Point] = []
        for q in p where out.last.map({ dist($0, q) >= minDistance }) ?? true { out.append(q) }
        if out.count > 2, let f = out.first, let l = out.last, dist(f, l) < minDistance { out.removeLast() }
        return out
    }

    /// Removes corners where the outline barely turns (under ~25°).
    static func dropFlat(_ c: [Point]) -> [Point] {
        var out = c
        var changed = true
        while changed && out.count > 3 {
            changed = false
            for i in 0..<out.count {
                let a = out[(i + out.count - 1) % out.count], b = out[i], d = out[(i + 1) % out.count]
                let a1 = atan2(b.y - a.y, b.x - a.x), a2 = atan2(d.y - b.y, d.x - b.x)
                var turn = abs(a2 - a1)
                if turn > .pi { turn = 2 * .pi - turn }
                if turn < 25 * .pi / 180 { out.remove(at: i); changed = true; break }
            }
        }
        return out
    }

    /// Snaps the end point so near-horizontal, vertical or diagonal lines become exact.
    public static func snapAngle(_ a: Point, _ b: Point) -> Point {
        let dx = b.x - a.x, dy = b.y - a.y
        let len = hypot(dx, dy)
        let angle = atan2(dy, dx)
        let step = Double.pi / 4
        let snapped = (angle / step).rounded() * step
        guard abs(angle - snapped) < 6 * .pi / 180 else { return b }
        return Point(a.x + len * cos(snapped), a.y + len * sin(snapped))
    }
}
