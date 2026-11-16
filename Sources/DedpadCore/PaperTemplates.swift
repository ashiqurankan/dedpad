import Foundation

public enum PaperCategory: String, CaseIterable, Sendable, Identifiable {
    case basic, academic, maths, planning, creative
    public var id: String { rawValue }
    public var name: String {
        switch self {
        case .basic: return "Basic"
        case .academic: return "Academic"
        case .maths: return "Mathematics"
        case .planning: return "Planning"
        case .creative: return "Creative"
        }
    }
}

public enum PaperStyle: String, CaseIterable, Codable, Sendable, Identifiable {
    // Basic
    case blank, ruled, wideRuled, collegeRuled, dotted, squareGrid, graph
    // Academic
    case cornell, lecture, study, revision, questionAnswer, vocabulary
    // Maths
    case coordinatePlane, mathExercise, numberedGrid
    // Planning
    case dailyPlanner, weeklyPlanner, monthlyPlanner, taskList, habitTracker, goals
    // Creative
    case sketchbook, storyboard, drawingSheet, mindMap

    public var id: String { rawValue }

    public var name: String {
        switch self {
        case .blank: return "Blank"
        case .ruled: return "Ruled"
        case .wideRuled: return "Wide ruled"
        case .collegeRuled: return "College ruled"
        case .dotted: return "Dotted"
        case .squareGrid: return "Square grid"
        case .graph: return "Graph"
        case .cornell: return "Cornell notes"
        case .lecture: return "Lecture notes"
        case .study: return "Study notes"
        case .revision: return "Revision sheet"
        case .questionAnswer: return "Q & A"
        case .vocabulary: return "Vocabulary"
        case .coordinatePlane: return "Coordinate plane"
        case .mathExercise: return "Exercise sheet"
        case .numberedGrid: return "Numbered grid"
        case .dailyPlanner: return "Daily planner"
        case .weeklyPlanner: return "Weekly planner"
        case .monthlyPlanner: return "Monthly planner"
        case .taskList: return "Task list"
        case .habitTracker: return "Habit tracker"
        case .goals: return "Goal planning"
        case .sketchbook: return "Sketchbook"
        case .storyboard: return "Storyboard"
        case .drawingSheet: return "Drawing sheet"
        case .mindMap: return "Mind map"
        }
    }

    public var category: PaperCategory {
        switch self {
        case .blank, .ruled, .wideRuled, .collegeRuled, .dotted, .squareGrid, .graph: return .basic
        case .cornell, .lecture, .study, .revision, .questionAnswer, .vocabulary: return .academic
        case .coordinatePlane, .mathExercise, .numberedGrid: return .maths
        case .dailyPlanner, .weeklyPlanner, .monthlyPlanner, .taskList, .habitTracker, .goals: return .planning
        case .sketchbook, .storyboard, .drawingSheet, .mindMap: return .creative
        }
    }

    public static func styles(in category: PaperCategory) -> [PaperStyle] {
        allCases.filter { $0.category == category }
    }

    /// Default spacing in points (line height, grid cell or dot pitch).
    public var defaultSpacing: Double {
        switch self {
        case .wideRuled: return 34
        case .collegeRuled: return 22
        case .dotted: return 20
        case .squareGrid, .numberedGrid: return 20
        case .graph, .coordinatePlane: return 12
        case .vocabulary, .taskList: return 30
        default: return 26
        }
    }

    /// Whether the spacing slider means anything for this style.
    public var usesSpacing: Bool {
        switch self {
        case .blank, .sketchbook, .storyboard, .drawingSheet, .weeklyPlanner, .monthlyPlanner, .habitTracker: return false
        default: return true
        }
    }
}

// MARK: - Primitives

/// Which of the paper's colours a primitive uses.
public enum PaperInk: Sendable, Equatable {
    case line
    /// Lighter version of the line colour (minor grid lines, guide rules).
    case faint
    case accent
    /// Text labels (a darker version of the line colour).
    case label
}

/// Device-independent drawing instructions for a paper template, in page points with the
/// origin at the top-left. Rendered by CoreGraphics on iPad and by the SVG exporter.
public enum PaperPrimitive: Sendable, Equatable {
    case line(x1: Double, y1: Double, x2: Double, y2: Double, width: Double, ink: PaperInk)
    case rect(x: Double, y: Double, w: Double, h: Double, width: Double, ink: PaperInk, radius: Double)
    case fill(x: Double, y: Double, w: Double, h: Double, ink: PaperInk, opacity: Double, radius: Double)
    case dot(x: Double, y: Double, r: Double, ink: PaperInk)
    case ellipse(x: Double, y: Double, w: Double, h: Double, width: Double, ink: PaperInk)
    case text(String, x: Double, y: Double, size: Double, bold: Bool, ink: PaperInk, align: TextAlign)

    public enum TextAlign: Sendable, Equatable { case left, center, right }
}

public extension PaperSpec {
    /// Resolves a primitive ink to a concrete colour for this paper.
    func color(for ink: PaperInk) -> RGBA {
        switch ink {
        case .line: return lineColor
        case .faint: return lineColor.mixed(with: background, 0.5)
        case .accent: return accentColor
        case .label: return background.isDark ? lineColor.mixed(with: .white, 0.35) : lineColor.mixed(with: DedPalette.text, 0.55)
        }
    }
}

// MARK: - Layout

public enum PaperLayout {

    /// Drawing instructions for `spec` on a page of `size`.
    public static func primitives(for spec: PaperSpec, size: PageDimensions) -> [PaperPrimitive] {
        let w = size.width, h = size.height
        let s = max(6, spec.spacing)
        let m = max(0, min(spec.margin, min(w, h) / 4))
        var p: [PaperPrimitive] = []

        func hline(_ y: Double, _ x1: Double = 0, _ x2: Double? = nil, width: Double = 0.75, ink: PaperInk = .line) {
            p.append(.line(x1: x1, y1: y, x2: x2 ?? w, y2: y, width: width, ink: ink))
        }
        func vline(_ x: Double, _ y1: Double = 0, _ y2: Double? = nil, width: Double = 0.75, ink: PaperInk = .line) {
            p.append(.line(x1: x, y1: y1, x2: x, y2: y2 ?? h, width: width, ink: ink))
        }
        func label(_ t: String, _ x: Double, _ y: Double, size: Double = 8.5, bold: Bool = true, align: PaperPrimitive.TextAlign = .left) {
            p.append(.text(t, x: x, y: y, size: size, bold: bold, ink: .label, align: align))
        }
        /// Horizontal rules between y1 and y2 inside x1...x2.
        func rules(from y1: Double, to y2: Double, x1: Double = 0, x2: Double? = nil, step: Double, ink: PaperInk = .line) {
            guard step > 0 else { return }
            var y = y1
            while y <= y2 + 0.01 { hline(y, x1, x2, ink: ink); y += step }
        }
        func grid(x1: Double, y1: Double, x2: Double, y2: Double, step: Double, major: Int = 0) {
            guard step > 0 else { return }
            var i = 0
            var x = x1
            while x <= x2 + 0.01 {
                let isMajor = major > 0 && i % major == 0
                vline(x, y1, y2, width: isMajor ? 0.9 : 0.5, ink: isMajor ? .line : .faint)
                x += step; i += 1
            }
            i = 0
            var y = y1
            while y <= y2 + 0.01 {
                let isMajor = major > 0 && i % major == 0
                hline(y, x1, x2, width: isMajor ? 0.9 : 0.5, ink: isMajor ? .line : .faint)
                y += step; i += 1
            }
        }
        func box(_ x: Double, _ y: Double, _ bw: Double, _ bh: Double, title: String? = nil, radius: Double = 6) {
            p.append(.rect(x: x, y: y, w: bw, h: bh, width: 0.9, ink: .line, radius: radius))
            if let title { label(title.uppercased(), x + 10, y + 16) }
        }
        func checkbox(_ x: Double, _ y: Double, _ size: Double = 11) {
            p.append(.rect(x: x, y: y, w: size, h: size, width: 0.9, ink: .line, radius: 2.5))
        }
        func header(_ fields: [String]) -> Double {
            let y = m
            // A field row like "DATE ________   TOPIC ________".
            let fieldW = (w - 2 * m) / Double(max(1, fields.count))
            for (i, f) in fields.enumerated() {
                let x = m + Double(i) * fieldW
                label(f.uppercased(), x, y + 14)
                hline(y + 26, x, x + fieldW - 14, width: 0.8)
            }
            return y + 44
        }

        let innerW = w - 2 * m
        let innerH = h - 2 * m

        switch spec.style {
        case .blank:
            break

        case .ruled, .wideRuled, .collegeRuled:
            let top = max(m, 60)
            rules(from: top, to: h - m * 0.6, step: s)
            if spec.style != .wideRuled {
                vline(max(48, m * 1.6), 0, h, width: 0.9, ink: .accent)
            }

        case .dotted:
            var y = m
            while y <= h - m + 0.01 {
                var x = m
                while x <= w - m + 0.01 {
                    p.append(.dot(x: x, y: y, r: 0.95, ink: .line))
                    x += s
                }
                y += s
            }

        case .squareGrid:
            grid(x1: m, y1: m, x2: m + floor(innerW / s) * s, y2: m + floor(innerH / s) * s, step: s)

        case .graph:
            grid(x1: m, y1: m, x2: m + floor(innerW / s / 5) * 5 * s, y2: m + floor(innerH / s / 5) * 5 * s, step: s, major: 5)

        case .cornell:
            let top = m + 44
            let cueX = m + innerW * 0.3
            let summaryY = h - m - innerH * 0.2
            _ = header(["Topic", "Date"])
            hline(top, m, w - m, width: 1.1)
            rules(from: top + s, to: summaryY - s * 0.5, x1: cueX + 8, x2: w - m, step: s, ink: .faint)
            vline(cueX, top, summaryY, width: 1.1, ink: .accent)
            hline(summaryY, m, w - m, width: 1.1)
            label("CUES", m, top + 16)
            label("NOTES", cueX + 10, top + 16)
            label("SUMMARY", m, summaryY + 16)

        case .lecture:
            let top = header(["Course", "Lecture", "Date"])
            box(m, top, innerW, 70, title: "Key question")
            rules(from: top + 70 + s * 1.5, to: h - m, x1: m, x2: w - m, step: s)

        case .study:
            let top = header(["Subject", "Chapter"])
            let colW = (innerW - 14) / 2
            box(m, top, colW, 110, title: "Key ideas")
            box(m + colW + 14, top, colW, 110, title: "Terms")
            let qTop = h - m - 120
            rules(from: top + 110 + s * 1.5, to: qTop - s, x1: m, x2: w - m, step: s)
            box(m, qTop, innerW, 120, title: "Questions to revisit")

        case .revision:
            let top = header(["Topic", "Exam date"])
            let gap = 12.0
            let bw = (innerW - gap) / 2
            let bh = (h - m - top - gap * 2) / 3
            let titles = ["Key points", "Definitions", "Formulas", "Examples", "Common mistakes", "Practise"]
            for i in 0..<6 {
                let col = Double(i % 2), row = Double(i / 2)
                box(m + col * (bw + gap), top + row * (bh + gap), bw, bh, title: titles[i])
            }

        case .questionAnswer:
            let top = header(["Topic", "Date"])
            let block = s * 6
            var y = top
            var n = 1
            while y + block <= h - m + 0.01 {
                p.append(.fill(x: m, y: y, w: innerW, h: s * 1.4, ink: .accent, opacity: 0.08, radius: 5))
                label("Q\(n)", m + 8, y + s * 0.9, size: 10)
                rules(from: y + s * 2.4, to: y + block - s * 0.6, x1: m + 30, x2: w - m, step: s, ink: .faint)
                label("A", m + 10, y + s * 2.4 - 4, size: 9)
                y += block
                n += 1
            }

        case .vocabulary:
            let top = m + 10
            let c1 = m + innerW * 0.28, c2 = m + innerW * 0.62
            label("WORD", m + 8, top + 14)
            label("MEANING", c1 + 8, top + 14)
            label("EXAMPLE", c2 + 8, top + 14)
            hline(top + 24, m, w - m, width: 1.1)
            rules(from: top + 24 + s, to: h - m, x1: m, x2: w - m, step: s, ink: .faint)
            vline(c1, top, h - m, width: 0.8)
            vline(c2, top, h - m, width: 0.8)

        case .coordinatePlane:
            let cols = floor(innerW / s), rows = floor(innerH / s)
            let gx1 = m, gy1 = m, gx2 = m + cols * s, gy2 = m + rows * s
            grid(x1: gx1, y1: gy1, x2: gx2, y2: gy2, step: s, major: 5)
            let cx = gx1 + floor(cols / 2) * s, cy = gy1 + floor(rows / 2) * s
            vline(cx, gy1, gy2, width: 1.6, ink: .accent)
            hline(cy, gx1, gx2, width: 1.6, ink: .accent)
            label("x", gx2 - 8, cy - 5, size: 9)
            label("y", cx + 5, gy1 + 10, size: 9)
            let stepUnits = 5
            var k = -Int(floor(cols / 2))
            while Double(k) * s + cx <= gx2 {
                if k != 0 && k % stepUnits == 0 { label("\(k)", cx + Double(k) * s, cy + 11, size: 6.5, bold: false, align: .center) }
                k += 1
            }
            k = -Int(floor(rows / 2))
            while Double(k) * s + cy <= gy2 {
                if k != 0 && k % stepUnits == 0 { label("\(-k)", cx - 4, cy + Double(k) * s + 2.5, size: 6.5, bold: false, align: .right) }
                k += 1
            }

        case .mathExercise:
            let top = header(["Name", "Topic", "Date"])
            let gap = 12.0
            let cols = 2.0
            let rows = max(2.0, floor((h - m - top) / 150))
            let bw = (innerW - gap) / cols
            let bh = (h - m - top - gap * (rows - 1)) / rows
            for r in 0..<Int(rows) {
                for c in 0..<Int(cols) {
                    let x = m + Double(c) * (bw + gap), y = top + Double(r) * (bh + gap)
                    p.append(.rect(x: x, y: y, w: bw, h: bh, width: 0.8, ink: .line, radius: 6))
                    p.append(.fill(x: x + 8, y: y + 8, w: 22, h: 18, ink: .accent, opacity: 0.12, radius: 4))
                    label("\(r * Int(cols) + c + 1)", x + 19, y + 21, size: 9.5, align: .center)
                    // A light grid to keep working tidy.
                    var gx = x + s
                    while gx < x + bw - 2 { vline(gx, y + 32, y + bh - 4, width: 0.35, ink: .faint); gx += s }
                    var gy = y + 32
                    while gy < y + bh - 2 { hline(gy, x + 4, x + bw - 4, width: 0.35, ink: .faint); gy += s }
                }
            }

        case .numberedGrid:
            let left = m + 18, top = m + 16
            let cols = floor((w - m - left) / s), rows = floor((h - m - top) / s)
            grid(x1: left, y1: top, x2: left + cols * s, y2: top + rows * s, step: s, major: 5)
            for c in 0..<Int(cols) {
                if c % 2 == 0 { label("\(c + 1)", left + (Double(c) + 0.5) * s, top - 5, size: 6.5, bold: false, align: .center) }
            }
            for r in 0..<Int(rows) {
                if r % 2 == 0 { label("\(r + 1)", left - 4, top + (Double(r) + 0.5) * s + 2.5, size: 6.5, bold: false, align: .right) }
            }

        case .dailyPlanner:
            label("DATE", m, m + 14)
            hline(m + 26, m + 40, m + innerW * 0.45, width: 0.8)
            let days = ["M", "T", "W", "T", "F", "S", "S"]
            for (i, d) in days.enumerated() {
                let cx = w - m - Double(days.count - 1 - i) * 22 - 8
                p.append(.ellipse(x: cx - 9, y: m + 4, w: 18, h: 18, width: 0.8, ink: .line))
                label(d, cx, m + 16.5, size: 8, align: .center)
            }
            let top = m + 44
            let schedW = innerW * 0.52
            label("SCHEDULE", m, top + 12)
            let hours = 6...21
            let slotH = (h - m - top - 22) / Double(hours.count)
            for (i, hr) in hours.enumerated() {
                let y = top + 22 + Double(i) * slotH
                hline(y, m, m + schedW, width: 0.7)
                hline(y + slotH / 2, m + 34, m + schedW, width: 0.4, ink: .faint)
                label(String(format: "%02d", hr), m + 2, y + 12, size: 8.5, bold: false)
            }
            hline(h - m, m, m + schedW, width: 0.7)
            let rx = m + schedW + 18, rw = w - m - rx
            label("TOP PRIORITIES", rx, top + 12)
            for i in 0..<3 {
                let y = top + 30 + Double(i) * 26
                checkbox(rx, y)
                hline(y + 12, rx + 18, w - m, width: 0.7)
            }
            let tTop = top + 30 + 3 * 26 + 14
            label("TO DO", rx, tTop + 12)
            for i in 0..<8 {
                let y = tTop + 26 + Double(i) * 24
                checkbox(rx, y, 10)
                hline(y + 11, rx + 18, w - m, width: 0.6, ink: .faint)
            }
            let nTop = tTop + 26 + 8 * 24 + 10
            if nTop < h - m - 60 {
                box(rx, nTop, rw, h - m - nTop, title: "Notes")
            }

        case .weeklyPlanner:
            label("WEEK OF", m, m + 14)
            hline(m + 26, m + 56, m + innerW * 0.5, width: 0.8)
            let top = m + 40
            let gap = 10.0
            let landscape = w > h
            let cols = landscape ? 4.0 : 2.0
            let rows = landscape ? 2.0 : 4.0
            let bw = (innerW - gap * (cols - 1)) / cols
            let bh = (h - m - top - gap * (rows - 1)) / rows
            let names = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday", "Notes"]
            for i in 0..<8 {
                let c = Double(i % Int(cols)), r = Double(i / Int(cols))
                let x = m + c * (bw + gap), y = top + r * (bh + gap)
                box(x, y, bw, bh, title: names[i])
                rules(from: y + 30, to: y + bh - 8, x1: x + 10, x2: x + bw - 10, step: 22, ink: .faint)
            }

        case .monthlyPlanner:
            label("MONTH", m, m + 14)
            hline(m + 26, m + 46, m + innerW * 0.45, width: 0.8)
            let top = m + 44
            let cw = innerW / 7
            let days = ["MON", "TUE", "WED", "THU", "FRI", "SAT", "SUN"]
            for (i, d) in days.enumerated() { label(d, m + Double(i) * cw + cw / 2, top + 10, size: 8, align: .center) }
            let gTop = top + 20
            let notesH = w > h ? 0.0 : innerH * 0.16
            let ch = (h - m - gTop - notesH - (notesH > 0 ? 12 : 0)) / 6
            for r in 0...6 { hline(gTop + Double(r) * ch, m, w - m, width: 0.8) }
            for c in 0...7 { vline(m + Double(c) * cw, gTop, gTop + 6 * ch, width: 0.8) }
            if notesH > 0 { box(m, h - m - notesH, innerW, notesH, title: "Notes") }

        case .taskList:
            label("TASKS", m, m + 14)
            hline(m + 26, m + 44, w - m - 120, width: 0.8)
            label("DUE", w - m - 100, m + 14)
            hline(m + 26, w - m - 76, w - m, width: 0.8)
            var y = m + 44
            while y + s <= h - m + 0.01 {
                checkbox(m + 4, y + s / 2 - 6, 12)
                hline(y + s, m + 26, w - m, width: 0.6, ink: .faint)
                y += s
            }

        case .habitTracker:
            let top = header(["Month", "Focus"])
            let nameW = innerW * 0.26
            let days = 31
            let cw = (innerW - nameW) / Double(days)
            label("HABIT", m + 4, top + 12)
            for d in 1...days {
                label("\(d)", m + nameW + (Double(d) - 0.5) * cw, top + 12, size: 6.5, bold: false, align: .center)
            }
            let rowsTop = top + 20
            let rows = 16
            let rh = min(30, (h - m - rowsTop) / Double(rows))
            for r in 0...rows { hline(rowsTop + Double(r) * rh, m, w - m, width: r == 0 ? 1 : 0.6) }
            vline(m + nameW, rowsTop, rowsTop + Double(rows) * rh, width: 0.9)
            for d in 1..<days { vline(m + nameW + Double(d) * cw, rowsTop, rowsTop + Double(rows) * rh, width: 0.35, ink: .faint) }

        case .goals:
            var y = m
            box(m, y, innerW, 80, title: "Goal")
            y += 92
            box(m, y, innerW, 80, title: "Why it matters")
            y += 92
            let mh = max(140, (h - m - y) * 0.55)
            box(m, y, innerW, mh, title: "Milestones")
            var my = y + 30
            while my + 22 <= y + mh - 6 {
                checkbox(m + 12, my, 11)
                hline(my + 11, m + 32, m + innerW * 0.72, width: 0.6, ink: .faint)
                hline(my + 11, m + innerW * 0.76, w - m - 12, width: 0.6, ink: .faint)
                my += 26
            }
            label("BY", m + innerW * 0.76, y + 16)
            y += mh + 12
            if y < h - m - 40 {
                let half = (innerW - 12) / 2
                box(m, y, half, h - m - y, title: "Resources")
                box(m + half + 12, y, half, h - m - y, title: "Reward")
            }

        case .sketchbook:
            p.append(.rect(x: m * 0.6, y: m * 0.6, w: w - m * 1.2, h: h - m * 1.2, width: 0.5, ink: .faint, radius: 0))

        case .storyboard:
            let gap = 16.0
            let cols = w > h ? 3.0 : 2.0
            let rows = w > h ? 2.0 : 3.0
            let cellW = (innerW - gap * (cols - 1)) / cols
            let cellH = (innerH - gap * (rows - 1)) / rows
            let frameH = cellH - 52
            for r in 0..<Int(rows) {
                for c in 0..<Int(cols) {
                    let x = m + Double(c) * (cellW + gap), y = m + Double(r) * (cellH + gap)
                    p.append(.rect(x: x, y: y, w: cellW, h: frameH, width: 1, ink: .line, radius: 4))
                    label("\(r * Int(cols) + c + 1)", x + 6, y + frameH + 13, size: 8)
                    hline(y + frameH + 26, x + 18, x + cellW, width: 0.6, ink: .faint)
                    hline(y + frameH + 44, x, x + cellW, width: 0.6, ink: .faint)
                }
            }

        case .drawingSheet:
            p.append(.rect(x: m * 0.7, y: m * 0.7, w: w - m * 1.4, h: h - m * 1.4, width: 1.2, ink: .line, radius: 0))
            let bw = min(220, innerW * 0.45), bh = 56.0
            let bx = w - m * 0.7 - bw, by = h - m * 0.7 - bh
            p.append(.rect(x: bx, y: by, w: bw, h: bh, width: 1, ink: .line, radius: 0))
            hline(by + bh / 2, bx, bx + bw, width: 0.7)
            vline(bx + bw * 0.62, by + bh / 2, by + bh, width: 0.7)
            label("TITLE", bx + 6, by + 11, size: 6.5)
            label("ARTIST", bx + 6, by + bh / 2 + 11, size: 6.5)
            label("DATE", bx + bw * 0.62 + 6, by + bh / 2 + 11, size: 6.5)

        case .mindMap:
            var y = m
            while y <= h - m + 0.01 {
                var x = m
                while x <= w - m + 0.01 {
                    p.append(.dot(x: x, y: y, r: 0.7, ink: .faint))
                    x += s
                }
                y += s
            }
            let cw = min(innerW * 0.38, 220), ch = cw * 0.5
            p.append(.ellipse(x: (w - cw) / 2, y: (h - ch) / 2, w: cw, h: ch, width: 1.4, ink: .accent))
        }

        return p
    }

    /// Where the page number goes, if any.
    public static func pageNumberPrimitive(_ number: Int, position: PageNumberPosition, size: PageDimensions) -> PaperPrimitive? {
        let isLeft = number % 2 == 0
        switch position {
        case .none:
            return nil
        case .bottomCenter:
            return .text("\(number)", x: size.width / 2, y: size.height - 14, size: 8, bold: false, ink: .label, align: .center)
        case .bottomOuter:
            return .text("\(number)", x: isLeft ? 18 : size.width - 18, y: size.height - 14, size: 8, bold: false, ink: .label, align: isLeft ? .left : .right)
        case .topOuter:
            return .text("\(number)", x: isLeft ? 18 : size.width - 18, y: 20, size: 8, bold: false, ink: .label, align: isLeft ? .left : .right)
        }
    }
}
