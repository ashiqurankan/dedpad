import UIKit
import PDFKit
import PencilKit
import DedpadCore

/// What goes under the ink when a page is rendered for export.
enum ExportBackground: String, CaseIterable, Identifiable {
    case paper, plain, transparent
    var id: String { rawValue }
    var name: String {
        switch self {
        case .paper: return "Paper"
        case .plain: return "Plain white"
        case .transparent: return "Transparent"
        }
    }
}

/// Opens PDFs once and keeps them around.
final class PDFCache {
    static let shared = PDFCache()
    private let cache = NSCache<NSURL, PDFDocument>()

    func document(at url: URL) -> PDFDocument? {
        if let d = cache.object(forKey: url as NSURL) { return d }
        guard let d = PDFDocument(url: url) else { return nil }
        cache.setObject(d, forKey: url as NSURL)
        return d
    }

    func page(at url: URL, index: Int) -> PDFPage? {
        guard let d = document(at: url), index >= 0, index < d.pageCount else { return nil }
        return d.page(at: index)
    }

    func clear() { cache.removeAllObjects() }

    /// Display size of a PDF page in points, taking /Rotate into account.
    static func displaySize(of page: PDFPage) -> PageDimensions {
        let b = page.bounds(for: .cropBox)
        let rotated = abs(page.rotation) % 180 == 90
        return rotated
            ? PageDimensions(width: Double(b.height), height: Double(b.width))
            : PageDimensions(width: Double(b.width), height: Double(b.height))
    }
}

/// Draws paper templates, page backgrounds and finished pages with CoreGraphics.
/// All coordinates are page points with a top-left origin (UIKit convention).
enum PageRenderer {

    // MARK: Paper

    static func drawPaper(_ spec: PaperSpec, size: PageDimensions, in ctx: CGContext, fill: Bool = true, extra: [PaperPrimitive] = []) {
        let rect = CGRect(x: 0, y: 0, width: size.width, height: size.height)
        if fill {
            ctx.setFillColor(spec.background.uiColor.cgColor)
            ctx.fill(rect)
        }
        for p in PaperLayout.primitives(for: spec, size: size) + extra {
            draw(p, spec: spec, in: ctx)
        }
    }

    static func draw(_ p: PaperPrimitive, spec: PaperSpec, in ctx: CGContext) {
        func color(_ ink: PaperInk) -> CGColor { spec.color(for: ink).uiColor.cgColor }
        switch p {
        case let .line(x1, y1, x2, y2, w, ink):
            ctx.setStrokeColor(color(ink))
            ctx.setLineWidth(CGFloat(w))
            ctx.setLineCap(.butt)
            ctx.beginPath()
            ctx.move(to: CGPoint(x: x1, y: y1))
            ctx.addLine(to: CGPoint(x: x2, y: y2))
            ctx.strokePath()
        case let .rect(x, y, w, h, lw, ink, r):
            ctx.setStrokeColor(color(ink))
            ctx.setLineWidth(CGFloat(lw))
            let path = UIBezierPath(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerRadius: CGFloat(r))
            ctx.addPath(path.cgPath)
            ctx.strokePath()
        case let .fill(x, y, w, h, ink, opacity, r):
            ctx.setFillColor(spec.color(for: ink).withAlpha(spec.color(for: ink).a * opacity).uiColor.cgColor)
            let path = UIBezierPath(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerRadius: CGFloat(r))
            ctx.addPath(path.cgPath)
            ctx.fillPath()
        case let .dot(x, y, r, ink):
            ctx.setFillColor(color(ink))
            ctx.fillEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
        case let .ellipse(x, y, w, h, lw, ink):
            ctx.setStrokeColor(color(ink))
            ctx.setLineWidth(CGFloat(lw))
            ctx.strokeEllipse(in: CGRect(x: x, y: y, width: w, height: h))
        case let .text(t, x, y, size, bold, ink, align):
            let font = DedFont.uiSans(CGFloat(size), bold: bold)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: spec.color(for: ink).uiColor,
                .kern: bold ? CGFloat(size) * 0.08 : 0,
            ]
            let s = NSAttributedString(string: t, attributes: attrs)
            let width = s.size().width
            var origin = CGPoint(x: x, y: y - Double(font.ascender))
            switch align {
            case .left: break
            case .center: origin.x -= width / 2
            case .right: origin.x -= width
            }
            UIGraphicsPushContext(ctx)
            s.draw(at: origin)
            UIGraphicsPopContext()
        }
    }

    // MARK: Page background

    struct Layers: OptionSet {
        let rawValue: Int
        static let paper = Layers(rawValue: 1)
        static let elements = Layers(rawValue: 2)
        static let highlights = Layers(rawValue: 4)
        static let all: Layers = [.paper, .elements, .highlights]
    }

    /// Draws everything under the ink: paper, PDF page or image, page number, highlights, text boxes
    /// and images. Thread-safe (used by PDFView tiles, thumbnails and exports).
    static func drawBackground(
        page: Page, notebook: Notebook, number: Int?, store: LibraryStore, in ctx: CGContext,
        includePaper: Bool = true, layers: Layers = .all
    ) {
        let size = page.size
        let rect = CGRect(x: 0, y: 0, width: size.width, height: size.height)
        let spec = notebook.paper(for: page)
        var extra: [PaperPrimitive] = []
        if let number, case .paper = page.background,
           let pn = PaperLayout.pageNumberPrimitive(number, position: notebook.settings.pageNumbers, size: size) {
            extra.append(pn)
        }

        switch page.background {
        case .paper:
            if includePaper && layers.contains(.paper) { drawPaper(spec, size: size, in: ctx, extra: extra) }

        case let .pdf(file, index):
            if includePaper && layers.contains(.paper) {
                ctx.setFillColor(UIColor.white.cgColor)
                ctx.fill(rect)
            }
            if let cg = CGPDFCache.shared.page(at: store.assetURL(notebook: notebook.id, file: file), index: index) {
                drawPDFPage(cg, in: rect, ctx: ctx)
            } else {
                drawMissing("PDF page not found", rect: rect, ctx: ctx)
            }

        case let .image(file):
            if includePaper && layers.contains(.paper) { drawPaper(spec, size: size, in: ctx) }
            if let image = ImageCache.shared.image(at: store.assetURL(notebook: notebook.id, file: file)) {
                UIGraphicsPushContext(ctx)
                image.draw(in: aspectFit(image.size, in: rect))
                UIGraphicsPopContext()
            } else {
                drawMissing("Image not found", rect: rect, ctx: ctx)
            }
        }

        if layers.contains(.highlights) { drawHighlights(page.highlights, in: ctx) }
        if layers.contains(.elements) { drawElements(page.elements, notebook: notebook, store: store, in: ctx) }
    }

    static func drawHighlights(_ highlights: [PageHighlight], in ctx: CGContext) {
        guard !highlights.isEmpty else { return }
        ctx.saveGState()
        ctx.setBlendMode(.multiply)
        for h in highlights {
            ctx.setFillColor(h.color.uiColor.cgColor)
            for r in h.rects { ctx.fill(CGRect(x: r.x, y: r.y, width: r.w, height: r.h)) }
        }
        ctx.restoreGState()
    }

    static func drawElements(_ elements: [PageElement], notebook: Notebook, store: LibraryStore, in ctx: CGContext) {
        guard !elements.isEmpty else { return }
        UIGraphicsPushContext(ctx)
        for e in elements {
            let frame = CGRect(x: e.frame.x, y: e.frame.y, width: e.frame.w, height: e.frame.h)
            ctx.saveGState()
            if e.rotation != 0 {
                ctx.translateBy(x: frame.midX, y: frame.midY)
                ctx.rotate(by: CGFloat(e.rotation * .pi / 180))
                ctx.translateBy(x: -frame.midX, y: -frame.midY)
            }
            switch e.kind {
            case .text:
                ElementText.attributed(e).draw(with: frame.insetBy(dx: ElementText.inset, dy: ElementText.inset),
                                               options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], context: nil)
            case .image, .sticker:
                if let file = e.imageFile, let img = ImageCache.shared.image(at: store.assetURL(notebook: notebook.id, file: file)) {
                    img.draw(in: aspectFit(img.size, in: frame))
                }
            }
            ctx.restoreGState()
        }
        UIGraphicsPopContext()
    }

    /// Transform from PDF page space to display space (top-left origin, `size` points).
    static func pdfToDisplay(_ cg: CGPDFPage, size: CGSize) -> CGAffineTransform {
        let box = cg.getBoxRect(.cropBox)
        let rotated = abs(cg.rotationAngle) % 180 == 90
        let natural = rotated ? CGSize(width: box.height, height: box.width) : box.size
        let scale = min(size.width / max(1, natural.width), size.height / max(1, natural.height))
        let d = cg.getDrawingTransform(.cropBox, rect: CGRect(origin: .zero, size: natural), rotate: 0, preserveAspectRatio: true)
        let flip = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: size.height)
        return d.concatenating(CGAffineTransform(scaleX: scale, y: scale)).concatenating(flip)
    }

    static func drawPDFPage(_ cg: CGPDFPage, in rect: CGRect, ctx: CGContext) {
        ctx.saveGState()
        ctx.translateBy(x: rect.minX, y: rect.minY)
        ctx.concatenate(pdfToDisplay(cg, size: rect.size))
        ctx.clip(to: cg.getBoxRect(.cropBox))
        ctx.interpolationQuality = .high
        ctx.drawPDFPage(cg)
        ctx.restoreGState()
    }

    static func drawPDFPage(_ page: PDFPage, in rect: CGRect, ctx: CGContext) {
        guard let cg = page.pageRef else { return }
        drawPDFPage(cg, in: rect, ctx: ctx)
    }

    private static func drawMissing(_ message: String, rect: CGRect, ctx: CGContext) {
        let attrs: [NSAttributedString.Key: Any] = [.font: DedFont.uiSans(12), .foregroundColor: UIColor.gray]
        UIGraphicsPushContext(ctx)
        NSAttributedString(string: message, attributes: attrs).draw(at: CGPoint(x: rect.minX + 20, y: rect.minY + 20))
        UIGraphicsPopContext()
    }

    static func aspectFit(_ size: CGSize, in rect: CGRect) -> CGRect {
        guard size.width > 0, size.height > 0 else { return rect }
        let s = min(rect.width / size.width, rect.height / size.height)
        let w = size.width * s, h = size.height * s
        return CGRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h)
    }

    // MARK: Ink

    /// Renders ink in light appearance, so black ink stays black whatever the system theme.
    static func inkImage(_ drawing: PKDrawing, rect: CGRect, scale: CGFloat, darkPaper: Bool) -> UIImage {
        var image = UIImage()
        UITraitCollection(userInterfaceStyle: darkPaper ? .dark : .light).performAsCurrent {
            image = drawing.image(from: rect, scale: scale)
        }
        return image
    }

    // MARK: Whole page

    /// A finished page as a bitmap (thumbnails, PNG/JPEG export).
    static func pageImage(
        page: Page, notebook: Notebook, number: Int?, drawing: PKDrawing?, store: LibraryStore,
        scale: CGFloat, background: ExportBackground = .paper
    ) -> UIImage {
        let size = CGSize(width: page.size.width, height: page.size.height)
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = background != .transparent
        let darkPaper = background == .paper && notebook.paper(for: page).background.isDark
        let rect = CGRect(origin: .zero, size: size)
        return UIGraphicsImageRenderer(size: size, format: format).image { rc in
            let ctx = rc.cgContext
            if background == .plain {
                ctx.setFillColor(UIColor.white.cgColor)
                ctx.fill(rect)
            }
            drawBackground(page: page, notebook: notebook, number: number, store: store, in: ctx, includePaper: background == .paper)
            if let drawing, !drawing.strokes.isEmpty {
                UIGraphicsPushContext(ctx)
                inkImage(drawing, rect: rect, scale: scale, darkPaper: darkPaper).draw(in: rect)
                UIGraphicsPopContext()
            }
        }
    }
}

/// Thread-safe Core Graphics PDF documents for background rendering.
final class CGPDFCache {
    static let shared = CGPDFCache()
    private let cache = NSCache<NSURL, CGPDFDocument>()

    func document(at url: URL) -> CGPDFDocument? {
        if let d = cache.object(forKey: url as NSURL) { return d }
        guard let d = CGPDFDocument(url as CFURL) else { return nil }
        cache.setObject(d, forKey: url as NSURL)
        return d
    }

    /// Zero-based index.
    func page(at url: URL, index: Int) -> CGPDFPage? {
        guard let d = document(at: url), index >= 0, index < d.numberOfPages else { return nil }
        return d.page(at: index + 1)
    }
}

/// Shared text styling for text-box elements (on screen and in exports).
enum ElementText {
    static let inset: CGFloat = 6

    static func font(_ e: PageElement) -> UIFont { DedFont.uiSans(CGFloat(e.fontSize), bold: e.bold) }

    static func attributes(_ e: PageElement) -> [NSAttributedString.Key: Any] {
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byWordWrapping
        return [.font: font(e), .foregroundColor: e.color.uiColor, .paragraphStyle: para]
    }

    static func attributed(_ e: PageElement) -> NSAttributedString {
        NSAttributedString(string: e.text, attributes: attributes(e))
    }
}

/// Decoded images for page backgrounds and covers.
final class ImageCache {
    static let shared = ImageCache()
    private let cache = NSCache<NSURL, UIImage>()

    func image(at url: URL) -> UIImage? {
        if let i = cache.object(forKey: url as NSURL) { return i }
        guard let i = UIImage(contentsOfFile: url.path) else { return nil }
        cache.setObject(i, forKey: url as NSURL)
        return i
    }

    func invalidate(_ url: URL) { cache.removeObject(forKey: url as NSURL) }
}

extension UIImage {
    /// Downscales so the longest side is at most `maxSide` pixels.
    func downscaled(maxSide: CGFloat) -> UIImage {
        let longest = max(size.width * scale, size.height * scale)
        guard longest > maxSide else { return self }
        let factor = maxSide / longest
        let target = CGSize(width: (size.width * scale * factor).rounded(), height: (size.height * scale * factor).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in draw(in: CGRect(origin: .zero, size: target)) }
    }
}
