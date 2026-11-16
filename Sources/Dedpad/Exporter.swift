import SwiftUI
import UIKit
import PencilKit
import PDFKit
import DedpadCore

enum ExportFormat: String, CaseIterable, Identifiable {
    case pdf, png, jpeg, svg, json, zip, txt, markdown, cover

    var id: String { rawValue }

    var name: String {
        switch self {
        case .pdf: return "PDF"
        case .png: return "PNG"
        case .jpeg: return "JPEG"
        case .svg: return "SVG"
        case .json: return "JSON backup"
        case .zip: return "ZIP archive"
        case .txt: return "Plain text"
        case .markdown: return "Markdown"
        case .cover: return "Cover image"
        }
    }

    var detail: String {
        switch self {
        case .pdf: return "Whole notebook or selected pages, ready to print. Annotated PDFs keep their original content."
        case .png: return "High-quality page images. Supports transparent backgrounds."
        case .jpeg: return "Smaller page images with adjustable quality."
        case .svg: return "Vector pages: paper and strokes as paths."
        case .json: return "One editable file with everything, including original drawing data."
        case .zip: return "The complete notebook folder. Import it on any iPad running dedpad."
        case .txt: return "Typed page notes only. Handwriting is not included."
        case .markdown: return "Typed page notes as Markdown. Handwriting is not included."
        case .cover: return "The notebook cover as a PNG."
        }
    }

    var symbol: String {
        switch self {
        case .pdf: return "doc.richtext"
        case .png, .jpeg: return "photo"
        case .svg: return "scribble.variable"
        case .json: return "curlybraces"
        case .zip: return "archivebox"
        case .txt: return "doc.plaintext"
        case .markdown: return "number"
        case .cover: return "book.closed"
        }
    }

    var usesPages: Bool { [.pdf, .png, .jpeg, .svg].contains(self) }
    var usesBackground: Bool { [.pdf, .png, .jpeg, .svg].contains(self) }
}

enum PDFPageSizeOption: String, CaseIterable, Identifiable {
    case original, a4, letter
    var id: String { rawValue }
    var name: String {
        switch self {
        case .original: return "Same as pages"
        case .a4: return "A4"
        case .letter: return "US Letter"
        }
    }
}

struct ExportOptions {
    var format: ExportFormat = .pdf
    var pageIDs: [UUID] = []
    var background: ExportBackground = .paper
    var resolution: CGFloat = 2
    var jpegQuality: Double = 0.85
    var pdfPageSize: PDFPageSizeOption = .original
    var includePageNumbers = true
    /// PDF only: ink and highlights as real PDF annotations other apps can edit.
    var editableAnnotations = true
}

/// Renders exports off the main thread, page by page, with progress and cancellation.
enum Exporter {

    typealias Progress = @Sendable (Double) -> Void

    static func export(
        notebook nb: Notebook, options o: ExportOptions, store: LibraryStore, coverImage: UIImage?,
        progress: @escaping Progress = { _ in }
    ) async throws -> [URL] {
        if o.format == .cover {
            return try await MainActor.run { try exportCover(nb, image: coverImage) }
        }
        return try await Task.detached(priority: .userInitiated) {
            try exportInBackground(nb, o, store: store, progress: progress)
        }.value
    }

    private static func exportInBackground(_ nb: Notebook, _ o: ExportOptions, store: LibraryStore, progress: Progress) throws -> [URL] {
        let dir = ExportFiles.newDirectory()
        let base = LibraryStore.safeFileName(nb.displayTitle, fallback: "Notebook")
        let selected = o.pageIDs.isEmpty ? nb.pages : nb.pages.filter { o.pageIDs.contains($0.id) }
        func number(_ p: Page) -> Int? {
            guard o.includePageNumbers else { return nil }
            return (nb.pages.firstIndex { $0.id == p.id } ?? 0) + 1
        }
        func suffix(_ p: Page) -> String {
            selected.count == 1 && nb.pages.count == 1 ? "" : " - p\((nb.pages.firstIndex { $0.id == p.id } ?? 0) + 1)"
        }
        func ink(_ p: Page) -> PKDrawing { DrawingLoader.load(store: store, notebook: nb.id, page: p) }

        switch o.format {
        case .pdf:
            let url = dir.appendingPathComponent(base + ".pdf")
            try writePDF(nb, pages: selected, options: o, store: store, number: number, to: url, progress: progress)
            return [url]

        case .png, .jpeg:
            var urls: [URL] = []
            for (k, p) in selected.enumerated() {
                try Task.checkCancellation()
                let bg: ExportBackground = o.format == .jpeg && o.background == .transparent ? .plain : o.background
                let img = PageRenderer.pageImage(page: p, notebook: nb, number: number(p), drawing: ink(p), store: store, scale: o.resolution, background: bg)
                let isPNG = o.format == .png
                guard let data = isPNG ? img.pngData() : img.jpegData(compressionQuality: o.jpegQuality) else { continue }
                let url = dir.appendingPathComponent(base + suffix(p) + (isPNG ? ".png" : ".jpg"))
                try data.write(to: url)
                urls.append(url)
                progress(Double(k + 1) / Double(selected.count))
            }
            return urls

        case .svg:
            var urls: [URL] = []
            for (k, p) in selected.enumerated() {
                try Task.checkCancellation()
                let spec: PaperSpec? = {
                    guard o.background == .paper, case .paper = p.background else { return nil }
                    return nb.paper(for: p)
                }()
                let pn = number(p).flatMap { PaperLayout.pageNumberPrimitive($0, position: nb.settings.pageNumbers, size: p.size) }
                var svg = SVGWriter.document(size: p.size, paper: spec, pageNumber: pn,
                                             strokes: vectorStrokes(ink(p), darkPaper: spec?.background.isDark ?? false),
                                             title: nb.displayTitle)
                if o.background == .plain {
                    svg = svg.replacingOccurrences(of: "<g id=\"ink\"", with: "<rect width=\"100%\" height=\"100%\" fill=\"#FFFFFF\"/>\n  <g id=\"ink\"")
                }
                let url = dir.appendingPathComponent(base + suffix(p) + ".svg")
                try Data(svg.utf8).write(to: url)
                urls.append(url)
                progress(Double(k + 1) / Double(selected.count))
            }
            return urls

        case .json:
            let url = dir.appendingPathComponent(base + ".dedpad.json")
            try Portability.jsonBackup(nb, store: store).write(to: url)
            return [url]

        case .zip:
            let url = dir.appendingPathComponent(base + ".dedpad.zip")
            try Portability.archive(nb, store: store).write(to: url)
            return [url]

        case .txt:
            let url = dir.appendingPathComponent(base + ".txt")
            try Data(Portability.plainText(nb).utf8).write(to: url)
            return [url]

        case .markdown:
            let url = dir.appendingPathComponent(base + ".md")
            try Data(Portability.markdown(nb).utf8).write(to: url)
            return [url]

        case .cover:
            return []
        }
    }

    @MainActor
    private static func exportCover(_ nb: Notebook, image: UIImage?) throws -> [URL] {
        let url = ExportFiles.newDirectory().appendingPathComponent(LibraryStore.safeFileName(nb.displayTitle, fallback: "Notebook") + " - cover.png")
        let pageAspect = nb.settings.pageDimensions.width / nb.settings.pageDimensions.height
        let view = CoverView(design: nb.cover, title: nb.displayTitle, image: image, aspect: CGFloat(pageAspect), showsShadow: false)
            .frame(width: 900, height: 900 / CGFloat(pageAspect))
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let data = renderer.uiImage?.pngData() else { throw DedpadError.notFound("The cover image") }
        try data.write(to: url)
        return [url]
    }

    // MARK: PDF

    private static func writePDF(
        _ nb: Notebook, pages: [Page], options o: ExportOptions, store: LibraryStore,
        number: (Page) -> Int?, to url: URL, progress: Progress
    ) throws {
        let editable = o.editableAnnotations
        let first = pages.first?.size ?? nb.settings.pageDimensions
        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = [kCGPDFContextTitle as String: nb.displayTitle, kCGPDFContextCreator as String: "dedpad"]
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: first.width, height: first.height), format: format)
        var cancelled = false
        // Placement of each page on its sheet (for annotations).
        var placements: [(Page, CGRect, CGRect)] = []
        let weight = editable ? 0.6 : 1.0

        try renderer.writePDF(to: url) { rc in
            for (k, p) in pages.enumerated() {
                if Task.isCancelled { cancelled = true; break }
                let pageRect = CGRect(x: 0, y: 0, width: p.size.width, height: p.size.height)
                let sheet: CGRect
                switch o.pdfPageSize {
                case .original: sheet = pageRect
                case .a4, .letter:
                    let d = (o.pdfPageSize == .a4 ? PageSizePreset.a4 : PageSizePreset.letter).dimensions
                    let fitted = p.size.isLandscape ? d.landscape : d.portrait
                    sheet = CGRect(x: 0, y: 0, width: fitted.width, height: fitted.height)
                }
                let target = sheet == pageRect ? pageRect : PageRenderer.aspectFit(pageRect.size, in: sheet.insetBy(dx: 18, dy: 18))
                placements.append((p, sheet, target))
                rc.beginPage(withBounds: sheet, pageInfo: [:])
                let ctx = rc.cgContext
                ctx.saveGState()
                if target != pageRect {
                    ctx.translateBy(x: target.minX, y: target.minY)
                    ctx.scaleBy(x: target.width / pageRect.width, y: target.height / pageRect.height)
                }
                if o.background == .plain {
                    ctx.setFillColor(UIColor.white.cgColor)
                    ctx.fill(pageRect)
                }
                // Paper and PDF pages stay vector.
                var layers: PageRenderer.Layers = [.paper, .elements]
                if !editable { layers.insert(.highlights) }
                PageRenderer.drawBackground(page: p, notebook: nb, number: number(p), store: store, in: ctx,
                                            includePaper: o.background == .paper, layers: layers)
                if !editable {
                    let d = DrawingLoader.load(store: store, notebook: nb.id, page: p)
                    if !d.strokes.isEmpty {
                        let dark = o.background == .paper && nb.paper(for: p).background.isDark
                        let ink = PageRenderer.inkImage(d, rect: pageRect, scale: max(2, o.resolution), darkPaper: dark)
                        UIGraphicsPushContext(ctx)
                        ink.draw(in: pageRect)
                        UIGraphicsPopContext()
                    }
                }
                ctx.restoreGState()
                progress(Double(k + 1) / Double(pages.count) * weight)
            }
        }
        if cancelled {
            try? FileManager.default.removeItem(at: url)
            throw CancellationError()
        }
        guard editable else { return }

        // Second pass: add ink and highlights as real PDF annotations.
        guard let doc = PDFDocument(url: url) else { return }
        for (k, entry) in placements.enumerated() {
            try Task.checkCancellation()
            let (p, sheet, target) = entry
            guard let pdfPage = doc.page(at: k) else { continue }
            let sx = target.width / CGFloat(p.size.width), sy = target.height / CGFloat(p.size.height)
            // Display (top-left, page points) → PDF page space (bottom-left, sheet points).
            func toPDF(_ pt: CGPoint) -> CGPoint {
                CGPoint(x: target.minX + pt.x * sx, y: sheet.height - (target.minY + pt.y * sy))
            }
            for h in p.highlights {
                for r in h.rects {
                    let a = toPDF(CGPoint(x: r.x, y: r.y + r.h)), b = toPDF(CGPoint(x: r.x + r.w, y: r.y))
                    let rect = CGRect(x: a.x, y: a.y, width: b.x - a.x, height: b.y - a.y)
                    let ann = PDFAnnotation(bounds: rect, forType: .highlight, withProperties: nil)
                    ann.color = h.color.uiColor
                    ann.quadrilateralPoints = [
                        NSValue(cgPoint: CGPoint(x: 0, y: rect.height)), NSValue(cgPoint: CGPoint(x: rect.width, y: rect.height)),
                        NSValue(cgPoint: .zero), NSValue(cgPoint: CGPoint(x: rect.width, y: 0)),
                    ]
                    pdfPage.addAnnotation(ann)
                }
            }
            let d = DrawingLoader.load(store: store, notebook: nb.id, page: p)
            let dark = o.background == .paper && nb.paper(for: p).background.isDark
            for stroke in vectorStrokes(d, darkPaper: dark) where stroke.points.count > 1 {
                let path = UIBezierPath()
                path.move(to: toPDF(CGPoint(x: stroke.points[0].x, y: stroke.points[0].y)))
                for pt in stroke.points.dropFirst() { path.addLine(to: toPDF(CGPoint(x: pt.x, y: pt.y))) }
                path.lineCapStyle = .round
                path.lineJoinStyle = .round
                let ann = PDFAnnotation(bounds: sheet, forType: .ink, withProperties: nil)
                ann.color = stroke.color.withAlpha(stroke.color.a * stroke.opacity).uiColor
                let border = PDFBorder()
                let avg = stroke.points.map(\.width).reduce(0, +) / Double(stroke.points.count)
                border.lineWidth = CGFloat(max(0.3, avg)) * sx
                ann.border = border
                ann.add(path)
                pdfPage.addAnnotation(ann)
            }
            progress(weight + Double(k + 1) / Double(placements.count) * (1 - weight))
        }
        doc.write(to: url)
    }

    // MARK: SVG strokes

    static func vectorStrokes(_ drawing: PKDrawing, darkPaper: Bool) -> [VectorStroke] {
        let traits = UITraitCollection(userInterfaceStyle: darkPaper ? .dark : .light)
        return drawing.strokes.map { stroke in
            let t = stroke.transform
            var pts: [VectorStroke.Point] = []
            for sp in stroke.path.interpolatedPoints(by: .distance(1.5)) {
                let loc = sp.location.applying(t)
                let w = Double(max(sp.size.width, sp.size.height)) * Double(sqrt(abs(t.a * t.d - t.b * t.c)))
                pts.append(.init(x: Double(loc.x), y: Double(loc.y), width: w * Double(sp.opacity > 0 ? 1 : 0)))
            }
            let ui = stroke.ink.color.resolvedColor(with: traits)
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 1
            ui.getRed(&r, green: &g, blue: &b, alpha: &a)
            let isMarker = stroke.ink.inkType == .marker
            return VectorStroke(points: pts, color: RGBA(r: Double(r), g: Double(g), b: Double(b), a: Double(a)), opacity: isMarker ? 0.45 : 1)
        }
    }
}

/// UIKit share sheet (includes "Save to Files", AirDrop, Mail, Photos…).
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    var onComplete: (() -> Void)? = nil

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let vc = UIActivityViewController(activityItems: items, applicationActivities: nil)
        vc.completionWithItemsHandler = { _, _, _, _ in onComplete?() }
        return vc
    }

    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

struct ShareItem: Identifiable {
    let id = UUID()
    let urls: [URL]
}
