import UIKit
import SwiftUI
import PhotosUI
import PencilKit
import Vision
import PDFKit
import DedpadCore

/// Loads a page's ink with fallbacks: PencilKit file → its backup → the open ink JSON → empty.
enum DrawingLoader {
    static func load(store: LibraryStore, notebook: UUID, page: Page) -> PKDrawing {
        if let data = store.readDrawing(notebook: notebook, page: page), let d = try? PKDrawing(data: data) { return d }
        if let data = store.readDrawingBackup(notebook: notebook, page: page), let d = try? PKDrawing(data: data) { return d }
        if let data = store.readInk(notebook: notebook, page: page), let ink = try? InkPage.decode(data) {
            return InkConverter.drawing(from: ink)
        }
        return PKDrawing()
    }
}

/// Serial background writer, so saves never block the UI and always land in order.
final class DiskWriter {
    static let shared = DiskWriter()
    private let queue = DispatchQueue(label: "dedpad.disk", qos: .utility)

    func async(_ work: @escaping () -> Void) { queue.async(execute: work) }
    /// Waits for everything queued so far (before export, close, or sync).
    func drain() { queue.sync {} }
}

/// On-device handwriting recognition (Vision), used to make handwriting searchable.
enum HandwritingRecognizer {
    static func recognize(_ drawing: PKDrawing, size: PageDimensions) async -> String {
        guard !drawing.strokes.isEmpty else { return "" }
        return await withCheckedContinuation { (cont: CheckedContinuation<String, Never>) in
            DispatchQueue.global(qos: .utility).async {
                let rect = CGRect(x: 0, y: 0, width: size.width, height: size.height)
                let format = UIGraphicsImageRendererFormat()
                format.scale = 2
                format.opaque = true
                let ink = PageRenderer.inkImage(drawing, rect: rect, scale: 2, darkPaper: false)
                let image = UIGraphicsImageRenderer(size: rect.size, format: format).image { ctx in
                    UIColor.white.setFill()
                    ctx.fill(rect)
                    ink.draw(in: rect)
                }
                guard let cg = image.cgImage else { cont.resume(returning: ""); return }
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = true
                request.automaticallyDetectsLanguage = true
                do {
                    try VNImageRequestHandler(cgImage: cg, options: [:]).perform([request])
                    let lines = (request.results ?? [])
                        .sorted { $0.boundingBox.minY > $1.boundingBox.minY }
                        .compactMap { $0.topCandidates(1).first?.string }
                    cont.resume(returning: lines.joined(separator: "\n"))
                } catch {
                    cont.resume(returning: "")
                }
            }
        }
    }
}

/// Built-in stickers (SF Symbols rendered to PNG in the chosen colour).
enum Stickers {
    static let symbols: [String] = [
        "star.fill", "heart.fill", "checkmark.seal.fill", "exclamationmark.triangle.fill", "lightbulb.fill",
        "flag.fill", "bookmark.fill", "pin.fill", "bolt.fill", "leaf.fill", "sun.max.fill", "moon.fill",
        "cloud.fill", "graduationcap.fill", "book.fill", "pencil.and.outline", "brain.head.profile",
        "questionmark.circle.fill", "calendar", "clock.fill", "arrow.right.circle.fill", "hand.thumbsup.fill",
        "face.smiling", "sparkles", "trophy.fill", "target", "flame.fill", "music.note",
    ]

    static func image(_ symbol: String, color: UIColor, size: CGFloat = 256) -> UIImage? {
        let config = UIImage.SymbolConfiguration(pointSize: size * 0.8, weight: .regular)
        guard let sym = UIImage(systemName: symbol, withConfiguration: config)?.withTintColor(color, renderingMode: .alwaysOriginal) else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let s = sym.size
        return UIGraphicsImageRenderer(size: s, format: format).image { _ in sym.draw(at: .zero) }
    }
}

/// One search result in the editor.
struct EditorSearchResult: Identifiable {
    let id = UUID()
    let pageIndex: Int
    let snippet: String
    let source: String
    let selection: PDFSelection?
}

/// A PDF outline entry mapped to a notebook page.
struct OutlineEntry: Identifiable {
    let id = UUID()
    let title: String
    let depth: Int
    let pageIndex: Int
}

/// Loads a picked photo reliably (HEIC and iCloud photos included).
enum PhotoLoader {
    struct PickedImage: Transferable {
        let image: UIImage
        static var transferRepresentation: some TransferRepresentation {
            DataRepresentation(importedContentType: .image) { data in
                guard let img = UIImage(data: data) else { throw DedpadError.notFound("The photo") }
                return PickedImage(image: img)
            }
        }
    }

    static func load(_ item: PhotosPickerItem) async -> UIImage? {
        if let picked = try? await item.loadTransferable(type: PickedImage.self) { return picked.image }
        if let data = try? await item.loadTransferable(type: Data.self), let img = UIImage(data: data) { return img }
        return nil
    }
}
