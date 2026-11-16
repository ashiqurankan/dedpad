import SwiftUI
import UIKit
import PDFKit
import PencilKit
import DedpadCore

// The editor surface: ONE PencilKit canvas holds the ink for every page, so PencilKit does the
// zooming and keeps handwriting sharp at any zoom. The pages (paper, PDF pages, images, text boxes)
// sit underneath in a layer that follows the canvas's scroll and zoom; their backgrounds are drawn
// in tiles (CATiledLayer), so they are re-rendered crisply at every zoom level too.
// Ink is stored per page: strokes are split by page and handed to the model in page coordinates.

// MARK: - Diagnostics

/// A small touch log, kept in Documents/Logs so it can be read after a test session.
enum DebugLog {
    private static let queue = DispatchQueue(label: "dedpad.log", qos: .utility)
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()
    static let url: URL = {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("touch-log.txt")
    }()

    static func write(_ message: String) {
        let now = Date()
        queue.async {
            let line = "\(formatter.string(from: now)) \(message)\n"
            let fm = FileManager.default
            if let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int, size > 2_000_000 {
                try? fm.removeItem(at: url)
            }
            if let h = try? FileHandle(forWritingTo: url) {
                h.seekToEndOfFile()
                h.write(Data(line.utf8))
                try? h.close()
            } else {
                try? Data(line.utf8).write(to: url)
            }
        }
    }
}

func dlog(_ message: @autoclosure () -> String) {
    let m = message()
    NSLog("[dedpad] %@", m)
    DebugLog.write(m)
}

/// Watches every touch on the pages without interfering, to spot the Pencil and resting palms.
/// While either is down, the page must not scroll or zoom (palm rejection for navigation).
///
/// Rules (radii on iPad come in ~10.4 pt steps: fingertip ≈ 21, flat finger ≈ 31, palm ≥ 42):
/// - any finger/palm touch that is on the glass while the Pencil writes is a palm until it lifts;
/// - a touch that lands while a palm is down is part of the same hand;
/// - shortly after writing, a broad touch (≥ 31) is a palm; a very broad one (≥ 42) always is,
///   unless a two-finger zoom is already under way.
final class PalmGuard: UIGestureRecognizer {
    /// What navigation must be frozen: nothing, scrolling only (a broad touch that may be a palm —
    /// or a thumb about to pinch), or everything (the Pencil is writing, or its hand is resting).
    enum Block: Equatable { case none, scroll, all }
    var onBlockChange: ((Block) -> Void)?
    /// Called when the first touch of a sequence lands (to remember the scroll position).
    var onSequenceStart: (() -> Void)?
    /// Called when the Pencil touches down (to undo a scroll a palm just caused).
    var onPencilDown: (() -> Void)?
    /// Whether a pinch is in progress (palms aren't re-judged mid-zoom).
    var isZooming: (() -> Bool)?
    /// Only writing tools freeze scrolling for the Pencil; palms always do.
    var pencilBlocks = true

    static let palmRadius: CGFloat = 26
    static let certainPalmRadius: CGFloat = 38
    static let pencilMemory: TimeInterval = 1.5

    private var pencils = Set<UITouch>()
    private var fingers = Set<UITouch>()
    /// Touches that were on the glass with the Pencil (certainly the writing hand).
    private var palms = Set<UITouch>()
    /// Touches judged a palm only by their size (could be a thumb).
    private var broad = Set<UITouch>()
    private var blocking = Block.none
    private var lastPencil = Date.distantPast
    private var sequenceStarted = false

    init() {
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
        requiresExclusiveTouchType = false
    }

    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }

    private func classify(_ touches: Set<UITouch>, began: Bool) {
        if began && !sequenceStarted {
            sequenceStarted = true
            onSequenceStart?()
        }
        for t in touches {
            if t.type == .pencil {
                if !pencils.contains(t) {
                    pencils.insert(t)
                    if pencilBlocks {
                        // Everything already resting on the glass belongs to the writing hand.
                        if !fingers.isEmpty { dlog("palm: \(fingers.count) touch(es) marked on pencil down") }
                        palms.formUnion(fingers)
                        palms.formUnion(broad)
                        fingers.removeAll()
                        broad.removeAll()
                        onPencilDown?()
                    }
                }
                lastPencil = Date()
            } else if t.type == .direct, !palms.contains(t) {
                let r = t.majorRadius
                let recentPencil = Date().timeIntervalSince(lastPencil) < Self.pencilMemory
                let zooming = isZooming?() ?? false
                if pencilBlocks && !pencils.isEmpty || (began && !palms.isEmpty) {
                    palms.insert(t)
                    fingers.remove(t)
                    broad.remove(t)
                    dlog("palm: r=\(Int(r)) (\(pencils.isEmpty ? "near palm" : "pencil down"))")
                } else if !broad.contains(t) && !zooming
                            && (r >= Self.certainPalmRadius || (pencilBlocks && recentPencil && r >= Self.palmRadius)) {
                    broad.insert(t)
                    fingers.remove(t)
                    dlog("broad touch: r=\(Int(r))")
                } else if began && !broad.contains(t) {
                    fingers.insert(t)
                    dlog("finger: r=\(Int(r))")
                }
            }
        }
        update()
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) { classify(touches, began: true) }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) { classify(touches, began: false) }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) { finish(touches, event) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { finish(touches, event) }

    private func finish(_ touches: Set<UITouch>, _ event: UIEvent) {
        for t in touches {
            if t.type == .pencil { lastPencil = Date() }
            pencils.remove(t)
            palms.remove(t)
            broad.remove(t)
            fingers.remove(t)
        }
        update()
        let remaining = (event.allTouches ?? []).filter { $0.phase != .ended && $0.phase != .cancelled }
        if remaining.isEmpty { state = .failed }
    }

    override func reset() {
        super.reset()
        pencils.removeAll()
        palms.removeAll()
        broad.removeAll()
        fingers.removeAll()
        sequenceStarted = false
        update()
    }

    /// A pinch started: the broad touches were fingers (a thumb), not a palm.
    func pinchBegan() {
        guard !broad.isEmpty else { return }
        fingers.formUnion(broad)
        broad.removeAll()
        update()
    }

    private func update() {
        let block: Block
        if (pencilBlocks && !pencils.isEmpty) || !palms.isEmpty { block = .all }
        else if !broad.isEmpty { block = .scroll }
        else { block = .none }
        guard block != blocking else { return }
        blocking = block
        onBlockChange?(block)
    }
}

/// Follows the Pencil for "draw and hold": when it pauses, the stroke can snap into a shape
/// right away, and further movement (before lifting) resizes it.
final class HoldWatcher: UIGestureRecognizer {
    /// The Pencil paused. Gets the stroke so far and where the Pencil is; returns true if it snapped.
    var onHold: (([CGPoint], CGPoint) -> Bool)?
    /// The Pencil moved after a snap.
    var onAdjust: ((CGPoint) -> Void)?
    /// The Pencil lifted after a snap.
    var onFinish: (() -> Void)?
    /// Where a touch is, in drawing coordinates.
    var locate: ((UITouch) -> CGPoint)?

    static let holdNanos: UInt64 = 380_000_000
    /// In screen points.
    static let stillTolerance: CGFloat = 3.5
    /// Drawing units per screen point (1 / zoom), so stillness is judged on screen.
    var unitsPerPoint: (() -> CGFloat)?

    private var tracking: UITouch?
    private var points: [CGPoint] = []
    private var anchor: CGPoint = .zero
    private var timer: Task<Void, Never>?
    private var snapped = false

    init() {
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
        allowedTouchTypes = [NSNumber(value: UITouch.TouchType.pencil.rawValue)]
    }

    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard tracking == nil, let t = touches.first else { return }
        tracking = t
        snapped = false
        anchor = position(t)
        points = [anchor]
        restart()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let t = tracking, touches.contains(t) else { return }
        for c in event.coalescedTouches(for: t) ?? [t] { points.append(position(c)) }
        let p = position(t)
        if snapped { onAdjust?(p); return }
        if hypot(p.x - anchor.x, p.y - anchor.y) > Self.stillTolerance * (unitsPerPoint?() ?? 1) {
            anchor = p
            restart()
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) { end(touches) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { end(touches) }

    private func position(_ t: UITouch) -> CGPoint { locate?(t) ?? t.location(in: view) }

    private func end(_ touches: Set<UITouch>) {
        guard let t = tracking, touches.contains(t) else { return }
        timer?.cancel()
        if snapped { onFinish?() }
        snapped = false
        tracking = nil
        points = []
        state = .failed
    }

    private func restart() {
        timer?.cancel()
        timer = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: HoldWatcher.holdNanos)
            guard !Task.isCancelled, let self, self.tracking != nil, !self.snapped else { return }
            self.snapped = self.onHold?(self.points, self.anchor) ?? false
        }
    }

    override func reset() {
        super.reset()
        timer?.cancel()
        tracking = nil
        snapped = false
        points = []
    }
}

// MARK: - Page views

/// What a page's background tiles are drawn from (read on background threads).
struct PageRenderInfo {
    var page: Page
    var notebook: Notebook
    var number: Int
    var store: LibraryStore

    /// Only these affect how the background looks; anything else changing needs no redraw.
    var key: AnyHashable {
        AnyHashable([AnyHashable(page.size.width), AnyHashable(page.size.height), AnyHashable(page.background),
                     AnyHashable(notebook.paper(for: page)), AnyHashable(page.highlights), AnyHashable(number),
                     AnyHashable(notebook.settings.pageNumbers)])
    }
}

final class PageTileLayer: CATiledLayer {
    override class func fadeDuration() -> CFTimeInterval { 0.06 }
}

/// Paper / PDF page / image background, drawn in tiles at the current zoom (always sharp).
final class PageBackgroundView: UIView {
    override class var layerClass: AnyClass { PageTileLayer.self }
    private let lock = NSLock()
    private var _info: PageRenderInfo

    var info: PageRenderInfo {
        get { lock.lock(); defer { lock.unlock() }; return _info }
        set { lock.lock(); _info = newValue; lock.unlock() }
    }

    init(info: PageRenderInfo) {
        _info = info
        super.init(frame: CGRect(x: 0, y: 0, width: info.page.size.width, height: info.page.size.height))
        isUserInteractionEnabled = false
        backgroundColor = .clear
        isOpaque = false
        let tiled = layer as! CATiledLayer
        tiled.tileSize = CGSize(width: 512, height: 512)
        tiled.levelsOfDetail = 8
        tiled.levelsOfDetailBias = 4      // sharp up to 16× the base resolution
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        let i = info
        ctx.clip(to: rect)
        PageRenderer.drawBackground(page: i.page, notebook: i.notebook, number: i.number, store: i.store,
                                    in: ctx, layers: [.paper, .highlights])
    }
}

/// One page under the ink: its background plus its text boxes and images.
final class PageView: UIView {
    let pageID: UUID
    let background: PageBackgroundView
    let elementsView = UIView()
    private(set) var elementViews: [UUID: ElementView] = [:]
    private var renderKey: AnyHashable

    var onElementChanged: ((UUID, PageElement) -> Void)?
    var onElementDeleted: ((UUID, UUID) -> Void)?
    var assetImage: ((String) -> UIImage?)?
    private var editable = false

    init(info: PageRenderInfo, frame: CGRect) {
        pageID = info.page.id
        background = PageBackgroundView(info: info)
        renderKey = info.key
        super.init(frame: frame)
        let spec = info.notebook.paper(for: info.page)
        if case .paper = info.page.background { backgroundColor = spec.background.uiColor } else { backgroundColor = .white }
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.12
        layer.shadowRadius = 5
        layer.shadowOffset = CGSize(width: 0, height: 1.5)
        layer.shadowPath = UIBezierPath(rect: bounds).cgPath
        addSubview(background)
        elementsView.frame = bounds
        addSubview(elementsView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(info: PageRenderInfo, frame newFrame: CGRect) {
        if frame != newFrame {
            frame = newFrame
            layer.shadowPath = UIBezierPath(rect: bounds).cgPath
            elementsView.frame = bounds
        }
        let key = info.key
        background.info = info
        if background.bounds.size != newFrame.size {
            background.frame = CGRect(origin: .zero, size: newFrame.size)
        }
        if key != renderKey {
            renderKey = key
            background.layer.setNeedsDisplay()
        }
    }

    func setElements(_ elements: [PageElement]) {
        let ids = Set(elements.map(\.id))
        for (id, v) in elementViews where !ids.contains(id) {
            v.removeFromSuperview()
            elementViews[id] = nil
        }
        for e in elements {
            if let v = elementViews[e.id] {
                if !v.isEditing { v.element = e }
            } else {
                let v = ElementView(element: e)
                v.image = e.imageFile.flatMap { assetImage?($0) }
                v.onChange = { [weak self] e in
                    guard let self else { return }
                    self.onElementChanged?(self.pageID, e)
                }
                v.onDelete = { [weak self] id in
                    guard let self else { return }
                    self.onElementDeleted?(self.pageID, id)
                }
                v.setEditable(editable)
                elementsView.addSubview(v)
                elementViews[e.id] = v
            }
        }
    }

    func setEditable(_ on: Bool) {
        editable = on
        for v in elementViews.values { v.setEditable(on) }
    }

    var isEditingElement: Bool { elementViews.values.contains { $0.isEditing } }

    /// Renders text at the zoomed resolution so text boxes stay sharp.
    func setTextScale(_ s: CGFloat) {
        func apply(_ v: UIView) {
            if v.contentScaleFactor != s { v.contentScaleFactor = s }
            for sub in v.subviews { apply(sub) }
        }
        for v in elementViews.values { apply(v) }
    }
}

/// The PencilKit canvas; in the text tool it lets touches reach the text boxes underneath.
final class InkCanvasView: PKCanvasView {
    var elementHit: ((CGPoint, UIEvent?) -> UIView?)?
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        if let v = elementHit?(point, event) { return v }
        return super.hitTest(point, with: event)
    }
}

/// The view SwiftUI hosts.
final class CanvasContainerView: UIView {
    var onLayout: (() -> Void)?
    override func layoutSubviews() {
        super.layoutSubviews()
        onLayout?()
    }
}

// MARK: - Controller

@MainActor
final class NotebookCanvasController: NSObject, PKCanvasViewDelegate, UIGestureRecognizerDelegate {
    let view = CanvasContainerView()
    let canvas = InkCanvasView()
    private let pagesContent = UIView()
    private let overlayContent = UIView()
    private let previewLayer = CAShapeLayer()
    private let selectionLayer = CAShapeLayer()

    // Callbacks into the editor model.
    var drawingForPage: ((UUID) -> PKDrawing)?
    var onDrawingChanged: ((UUID, PKDrawing) -> Void)?
    var onPageChanged: ((UUID) -> Void)?
    var onZoomChanged: (() -> Void)?
    var onSelectionChanged: ((Bool) -> Void)?
    var onElementChanged: ((UUID, PageElement) -> Void)?
    var onElementDeleted: ((UUID, UUID) -> Void)?
    var onAddTextBox: ((UUID, CGPoint) -> Void)?
    var pageLookup: ((UUID) -> Page?)?
    var darkPaper: ((UUID) -> Bool)?
    var assetImage: ((String) -> UIImage?)?

    static let margin: CGFloat = 24
    static let gap: CGFloat = 24

    private struct Slot { let id: UUID; var rect: CGRect }
    private var slots: [Slot] = []
    private var indexByID: [UUID: Int] = [:]
    private var pages: [UUID: Page] = [:]
    private var pageViews: [UUID: PageView] = [:]
    private var notebook: Notebook?
    private var store: LibraryStore?
    private var baseSize: CGSize = .zero
    private var signatures: [UUID: Int] = [:]
    private var splitTask: Task<Void, Never>?
    private var loadGeneration = 0
    private var applying = false

    private(set) var horizontal = false
    private var fitZoom: CGFloat = 1
    private var autoFit = true
    private var laidOutSize: CGSize = .zero
    private var pendingFocus: UUID?
    private var currentID: UUID?

    private(set) var tool: EditorTool = .pen
    private var toolConfigured = false
    private(set) var settings = ToolSettings()
    private var policyPref = "system"
    private(set) var rulerActive = false

    private let palmGuard = PalmGuard()
    private let holdWatcher = HoldWatcher()
    private var shapeGesture: UILongPressGestureRecognizer!
    private var selectGesture: UILongPressGestureRecognizer!
    private var textTap: UITapGestureRecognizer!
    private var unblockTask: Task<Void, Never>?

    private struct SnapSession {
        var base: PKDrawing
        var shape: ShapeRecognizer.Shape
        var current: ShapeRecognizer.Shape
        var anchor: CGPoint
        var ink: PKInk
        var width: CGFloat
        var color: UIColor
    }
    private var snap: SnapSession?
    private var shapeStart: CGPoint?

    private struct TextSelection { let pageID: UUID; let selection: PDFSelection; let pdfPage: PDFPage }
    private var selection: TextSelection?
    private var selectAnchor: (index: Int, point: CGPoint)?

    override init() {
        super.init()
        view.backgroundColor = Ded.uiBackdrop
        view.clipsToBounds = true

        pagesContent.layer.anchorPoint = .zero
        view.addSubview(pagesContent)

        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.contentInsetAdjustmentBehavior = .never
        canvas.delegate = self
        canvas.bouncesZoom = false          // no zoom bounce that could move the page mid-stroke
        canvas.alwaysBounceVertical = true
        canvas.showsHorizontalScrollIndicator = false
        canvas.elementHit = { [weak self] p, e in
            MainActor.assumeIsolated { self?.elementHit(p, e) }
        }
        view.addSubview(canvas)

        overlayContent.layer.anchorPoint = .zero
        overlayContent.isUserInteractionEnabled = false
        selectionLayer.fillColor = Ded.uiAccent.withAlphaComponent(0.28).cgColor
        previewLayer.fillColor = UIColor.clear.cgColor
        previewLayer.lineCap = .round
        previewLayer.lineJoin = .round
        overlayContent.layer.addSublayer(selectionLayer)
        overlayContent.layer.addSublayer(previewLayer)
        view.addSubview(overlayContent)

        view.onLayout = { [weak self] in MainActor.assumeIsolated { self?.layoutChanged() } }

        // Palm rejection for navigation.
        palmGuard.onBlockChange = { [weak self] block in
            MainActor.assumeIsolated { self?.setNavigationBlocked(block) }
        }
        palmGuard.onPencilDown = { [weak self] in
            MainActor.assumeIsolated { self?.pencilSeen() }
        }
        canvas.pinchGestureRecognizer?.addTarget(self, action: #selector(pinchChanged(_:)))
        palmGuard.isZooming = { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return false }
                let st = self.canvas.pinchGestureRecognizer?.state
                return st == .began || st == .changed || self.canvas.isZooming
            }
        }
        canvas.addGestureRecognizer(palmGuard)

        // Draw and hold.
        holdWatcher.locate = { [weak self] t in
            MainActor.assumeIsolated { self?.basePoint(t.location(in: self?.canvas)) ?? .zero }
        }
        holdWatcher.unitsPerPoint = { [weak self] in
            MainActor.assumeIsolated { 1 / max(self?.canvas.zoomScale ?? 1, 0.01) }
        }
        holdWatcher.onHold = { [weak self] pts, p in
            MainActor.assumeIsolated { self?.beginSnap(points: pts, at: p) ?? false }
        }
        holdWatcher.onAdjust = { [weak self] p in MainActor.assumeIsolated { self?.adjustSnap(to: p) } }
        holdWatcher.onFinish = { [weak self] in MainActor.assumeIsolated { self?.commitSnap() } }
        canvas.addGestureRecognizer(holdWatcher)

        shapeGesture = UILongPressGestureRecognizer(target: self, action: #selector(shapeDrag(_:)))
        shapeGesture.minimumPressDuration = 0
        shapeGesture.isEnabled = false
        canvas.addGestureRecognizer(shapeGesture)

        selectGesture = UILongPressGestureRecognizer(target: self, action: #selector(selectDrag(_:)))
        selectGesture.minimumPressDuration = 0
        selectGesture.isEnabled = false
        canvas.addGestureRecognizer(selectGesture)

        textTap = UITapGestureRecognizer(target: self, action: #selector(textTapped(_:)))
        textTap.isEnabled = false
        canvas.addGestureRecognizer(textTap)

        applyDrawingPolicy()
    }

    // MARK: Coordinates

    /// Canvas (scroll view) point → drawing / layout coordinates.
    private func basePoint(_ p: CGPoint) -> CGPoint {
        let z = max(canvas.zoomScale, 0.01)
        return CGPoint(x: p.x / z, y: p.y / z)
    }

    private func pageIndex(at p: CGPoint) -> Int? {
        guard !slots.isEmpty else { return nil }
        var best = 0
        var bestD = CGFloat.infinity
        for (i, s) in slots.enumerated() {
            if s.rect.contains(p) { return i }
            let d = horizontal ? abs(p.x - s.rect.midX) : abs(p.y - s.rect.midY)
            if d < bestD { bestD = d; best = i }
        }
        return best
    }

    private func pageIndex(of stroke: PKStroke) -> Int? {
        let b = stroke.renderBounds
        return pageIndex(at: CGPoint(x: b.midX, y: b.midY))
    }

    // MARK: Document

    func load(notebook nb: Notebook, store: LibraryStore, keepPosition: Bool, focus: UUID? = nil) {
        loadGeneration &+= 1
        let generation = loadGeneration
        // Hand pending ink to the model first; that may itself trigger a reload (page growth).
        if !slots.isEmpty { splitNow() }
        guard generation == loadGeneration else { return }

        let firstLoad = slots.isEmpty
        self.notebook = nb
        self.store = store
        pages = Dictionary(uniqueKeysWithValues: nb.pages.map { ($0.id, $0) })
        relayout(pageIDs: nb.pages.map(\.id), firstLoad: firstLoad)

        let dark = nb.pages.first.map { darkPaper?($0.id) ?? false } ?? false
        canvas.overrideUserInterfaceStyle = dark ? .dark : .light

        if firstLoad || !keepPosition {
            pendingFocus = focus ?? nb.pages.first?.id
            autoFit = true
        } else if let focus, !isVisible(focus) {
            pendingFocus = focus      // keep the view still while writing; only jump to off-screen pages
        }
        layoutChanged(force: true)
    }

    /// Lays the pages out and moves existing ink with its page when page positions change.
    private func relayout(pageIDs: [UUID], firstLoad: Bool) {
        let oldRects = Dictionary(uniqueKeysWithValues: slots.map { ($0.id, $0.rect) })
        let oldSlots = slots

        // New layout.
        let sizes = pageIDs.map { id -> CGSize in
            let s = pages[id]?.size
            return CGSize(width: s?.width ?? 612, height: s?.height ?? 792)
        }
        let maxW = sizes.map(\.width).max() ?? 612
        let maxH = sizes.map(\.height).max() ?? 792
        let m = Self.margin, g = Self.gap
        var newSlots: [Slot] = []
        if horizontal {
            var x = m
            for (id, s) in zip(pageIDs, sizes) {
                newSlots.append(Slot(id: id, rect: CGRect(x: x, y: m + (maxH - s.height) / 2, width: s.width, height: s.height)))
                x += s.width + g
            }
            baseSize = CGSize(width: max(x - g + m, maxW + 2 * m), height: maxH + 2 * m)
        } else {
            var y = m
            for (id, s) in zip(pageIDs, sizes) {
                newSlots.append(Slot(id: id, rect: CGRect(x: m + (maxW - s.width) / 2, y: y, width: s.width, height: s.height)))
                y += s.height + g
            }
            baseSize = CGSize(width: maxW + 2 * m, height: max(y - g + m, maxH + 2 * m))
        }

        // Ink.
        if firstLoad {
            var strokes: [PKStroke] = []
            for s in newSlots {
                let d = drawingForPage?(s.id) ?? PKDrawing()
                signatures[s.id] = Self.signature(d.strokes, origin: .zero)
                let t = CGAffineTransform(translationX: s.rect.minX, y: s.rect.minY)
                strokes += d.transformed(using: t).strokes
            }
            slots = newSlots
            reindex()
            setDrawing(PKDrawing(strokes: strokes))
        } else {
            let moved = newSlots.contains { s in oldRects[s.id].map { $0.origin != s.rect.origin } ?? false }
            let removed = oldSlots.contains { o in !newSlots.contains { $0.id == o.id } }
            let added = newSlots.filter { oldRects[$0.id] == nil }
            if moved || removed || !added.isEmpty {
                // Assign current strokes to their old pages, then shift them to the new positions.
                var strokes: [PKStroke] = []
                let newRects = Dictionary(uniqueKeysWithValues: newSlots.map { ($0.id, $0.rect) })
                for var st in canvas.drawing.strokes {
                    guard let i = pageIndex(of: st), oldSlots.indices.contains(i) else { continue }
                    let id = oldSlots[i].id
                    guard let to = newRects[id], let from = oldRects[id] else { continue }   // page deleted
                    if to.origin != from.origin {
                        st.transform = st.transform.concatenating(
                            CGAffineTransform(translationX: to.minX - from.minX, y: to.minY - from.minY))
                    }
                    strokes.append(st)
                }
                var addedInk = false
                for s in added {
                    let d = drawingForPage?(s.id) ?? PKDrawing()
                    signatures[s.id] = Self.signature(d.strokes, origin: .zero)
                    if !d.strokes.isEmpty { addedInk = true }
                    strokes += d.transformed(using: CGAffineTransform(translationX: s.rect.minX, y: s.rect.minY)).strokes
                }
                slots = newSlots
                reindex()
                if moved || removed || addedInk {
                    setDrawing(PKDrawing(strokes: strokes))
                    // Old undo steps refer to strokes at their old positions.
                    canvas.undoManager?.removeAllActions()
                }
            } else {
                slots = newSlots
                reindex()
            }
            for id in signatures.keys where indexByID[id] == nil { signatures[id] = nil }
        }

        // Page views: drop removed ones, move and refresh the rest.
        for (id, v) in pageViews where indexByID[id] == nil {
            v.removeFromSuperview()
            pageViews[id] = nil
        }
        for (id, v) in pageViews {
            guard let i = indexByID[id], let info = renderInfo(id) else { continue }
            v.update(info: info, frame: slots[i].rect)
            if let p = pages[id] { v.setElements(p.elements) }
        }
        pagesContent.bounds = CGRect(origin: .zero, size: baseSize)
        overlayContent.bounds = CGRect(origin: .zero, size: baseSize)
        pagesContent.layer.position = .zero
        overlayContent.layer.position = .zero
    }

    private func reindex() {
        indexByID = Dictionary(uniqueKeysWithValues: slots.enumerated().map { ($1.id, $0) })
    }

    private func renderInfo(_ id: UUID) -> PageRenderInfo? {
        guard let nb = notebook, let store, let p = pages[id], let i = indexByID[id] else { return nil }
        return PageRenderInfo(page: p, notebook: nb, number: i + 1, store: store)
    }

    private func setDrawing(_ d: PKDrawing) {
        applying = true
        canvas.drawing = d
        applying = false
    }

    var currentPageID: UUID? { currentID }

    private func isVisible(_ id: UUID) -> Bool {
        guard let i = indexByID[id] else { return false }
        let z = max(canvas.zoomScale, 0.01)
        let o = canvas.contentOffset
        let b = canvas.bounds.size
        return slots[i].rect.intersects(CGRect(x: o.x / z, y: o.y / z, width: b.width / z, height: b.height / z))
    }

    func go(to id: UUID, animated: Bool = false) {
        guard let i = indexByID[id] else { return }
        let r = slots[i].rect
        let z = canvas.zoomScale
        var o = canvas.contentOffset
        if horizontal {
            o.x = r.midX * z - canvas.bounds.width / 2
            o.y = r.midY * z - canvas.bounds.height / 2
        } else {
            o.y = r.minY * z - 12
        }
        canvas.setContentOffset(clamp(o), animated: animated)
        sync()
    }

    private func clamp(_ o: CGPoint) -> CGPoint {
        let inset = canvas.contentInset
        let cs = canvas.contentSize
        let b = canvas.bounds.size
        let minX = -inset.left, minY = -inset.top
        let maxX = max(minX, cs.width - b.width + inset.right)
        let maxY = max(minY, cs.height - b.height + inset.bottom)
        return CGPoint(x: min(max(o.x, minX), maxX), y: min(max(o.y, minY), maxY))
    }

    // MARK: Zoom & layout

    private func computeFit() -> CGFloat {
        let b = view.bounds.size
        guard b.width > 10, b.height > 10, baseSize.width > 0 else { return 1 }
        if horizontal {
            let maxH = baseSize.height
            let maxW = (slots.map(\.rect.width).max() ?? 612) + 2 * Self.margin
            return min(b.width / maxW, b.height / maxH)
        }
        return b.width / baseSize.width
    }

    private func layoutChanged(force: Bool = false) {
        let size = view.bounds.size
        guard size.width > 10, size.height > 10 else { return }
        let sizeChanged = size != laidOutSize
        guard force || sizeChanged else { return }
        laidOutSize = size
        canvas.frame = view.bounds
        let fit = computeFit()
        fitZoom = fit
        canvas.minimumZoomScale = fit * 0.5
        canvas.maximumZoomScale = fit * 6
        if autoFit || canvas.zoomScale < canvas.minimumZoomScale || canvas.zoomScale > canvas.maximumZoomScale {
            canvas.zoomScale = autoFit ? fit : min(max(canvas.zoomScale, canvas.minimumZoomScale), canvas.maximumZoomScale)
        }
        updateContentSize()
        if let f = pendingFocus {
            pendingFocus = nil
            go(to: f)
        }
        sync()
        updateTextSharpness()
        onZoomChanged?()
    }

    private func updateContentSize() {
        let z = canvas.zoomScale
        let cs = CGSize(width: baseSize.width * z, height: baseSize.height * z)
        if abs(canvas.contentSize.width - cs.width) > 0.5 || abs(canvas.contentSize.height - cs.height) > 0.5 {
            canvas.contentSize = cs
        }
        updateInsets()
    }

    /// Centres the pages when they're smaller than the screen.
    private func updateInsets() {
        let z = canvas.zoomScale
        let b = canvas.bounds.size
        let ix = max(0, (b.width - baseSize.width * z) / 2)
        let iy = max(0, (b.height - baseSize.height * z) / 2)
        let inset = UIEdgeInsets(top: iy, left: ix, bottom: iy, right: ix)
        if canvas.contentInset != inset { canvas.contentInset = inset }
    }

    /// Moves the pages (and overlays) to follow the canvas's scroll and zoom.
    private func sync() {
        let z = canvas.zoomScale
        let o = canvas.contentOffset
        let t = CGAffineTransform(a: z, b: 0, c: 0, d: z, tx: -o.x, ty: -o.y)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pagesContent.transform = t
        overlayContent.transform = t
        CATransaction.commit()
        updateVisiblePages()
        updateCurrentPage()
    }

    private func updateVisiblePages() {
        guard !slots.isEmpty else { return }
        let z = max(canvas.zoomScale, 0.01)
        let o = canvas.contentOffset
        let b = canvas.bounds.size
        let visible = CGRect(x: o.x / z, y: o.y / z, width: b.width / z, height: b.height / z)
        let keep = visible.insetBy(dx: -visible.width * 0.6, dy: -visible.height * 0.6)
        for s in slots where s.rect.intersects(keep) && pageViews[s.id] == nil {
            guard let info = renderInfo(s.id) else { continue }
            let v = PageView(info: info, frame: s.rect)
            v.onElementChanged = { [weak self] pid, e in self?.onElementChanged?(pid, e) }
            v.onElementDeleted = { [weak self] pid, eid in self?.onElementDeleted?(pid, eid) }
            v.assetImage = { [weak self] f in self?.assetImage?(f) }
            v.setElements(info.page.elements)
            v.setEditable(tool == .text)
            v.setTextScale(textScale)
            pagesContent.addSubview(v)
            pageViews[s.id] = v
        }
        let far = visible.insetBy(dx: -visible.width * 1.5, dy: -visible.height * 1.5)
        for (id, v) in pageViews {
            guard let i = indexByID[id] else { continue }
            if !slots[i].rect.intersects(far) && !v.isEditingElement {
                v.removeFromSuperview()
                pageViews[id] = nil
            }
        }
    }

    private func updateCurrentPage() {
        guard !slots.isEmpty else { return }
        let z = max(canvas.zoomScale, 0.01)
        let o = canvas.contentOffset
        let b = canvas.bounds.size
        let probe = CGPoint(x: (o.x + b.width / 2) / z, y: (o.y + b.height * 0.4) / z)
        guard let i = pageIndex(at: probe) else { return }
        let id = slots[i].id
        if id != currentID {
            currentID = id
            onPageChanged?(id)
        }
    }

    private var textScale: CGFloat {
        min(UIScreen.main.scale * max(canvas.zoomScale, 1), 8)
    }

    private func updateTextSharpness() {
        let s = textScale
        for v in pageViews.values { v.setTextScale(s) }
    }

    func fitWidth() {
        autoFit = true
        let page = currentID
        canvas.setZoomScale(fitZoom, animated: false)
        updateContentSize()
        if let page { go(to: page) }
        sync()
        updateTextSharpness()
        onZoomChanged?()
    }

    func fitPage() {
        guard let id = currentID, let i = indexByID[id] else { return }
        let r = slots[i].rect
        let b = canvas.bounds.size
        autoFit = false
        let z = min((b.width - 32) / r.width, (b.height - 32) / r.height)
        canvas.setZoomScale(min(max(z, canvas.minimumZoomScale), canvas.maximumZoomScale), animated: false)
        updateContentSize()
        let zz = canvas.zoomScale
        canvas.setContentOffset(clamp(CGPoint(x: r.midX * zz - b.width / 2, y: r.midY * zz - b.height / 2)), animated: false)
        sync()
        updateTextSharpness()
        onZoomChanged?()
    }

    var zoomPercent: Int {
        guard fitZoom > 0 else { return 100 }
        return Int((canvas.zoomScale / fitZoom * 100).rounded())
    }

    // MARK: Page turning

    /// Vertical continuous scrolling, or pages side by side, turned one at a time like a book.
    func setHorizontal(_ on: Bool) {
        guard on != horizontal else { return }
        let page = currentID
        if !slots.isEmpty { splitNow() }
        horizontal = on
        canvas.decelerationRate = on ? .fast : .normal
        canvas.alwaysBounceVertical = !on
        canvas.alwaysBounceHorizontal = on
        if !slots.isEmpty { relayout(pageIDs: slots.map(\.id), firstLoad: false) }
        autoFit = true
        pendingFocus = page
        layoutChanged(force: true)
    }

    // MARK: UIScrollViewDelegate

    func scrollViewDidScroll(_ scrollView: UIScrollView) { sync() }

    func scrollViewWillBeginZooming(_ scrollView: UIScrollView, with view: UIView?) {
        autoFit = false
        dlog("zoom began at \(Int(zoomPercent))%")
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        updateInsets()
        sync()
        onZoomChanged?()
    }

    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        updateContentSize()
        sync()
        updateTextSharpness()
        onZoomChanged?()
        dlog("zoom ended at \(Int(zoomPercent))%")
    }

    func scrollViewWillEndDragging(_ scrollView: UIScrollView, withVelocity velocity: CGPoint,
                                   targetContentOffset: UnsafeMutablePointer<CGPoint>) {
        // Book mode: settle on a whole page (unless zoomed in to look closer).
        guard horizontal, canvas.zoomScale <= fitZoom * 1.08, !slots.isEmpty else { return }
        let z = canvas.zoomScale
        let w = canvas.bounds.width
        let centre = (scrollView.contentOffset.x + w / 2) / z
        var i = slots.enumerated().min { abs($0.element.rect.midX - centre) < abs($1.element.rect.midX - centre) }?.offset ?? 0
        if velocity.x > 0.25, slots[i].rect.midX <= centre + 1 { i += 1 }
        if velocity.x < -0.25, slots[i].rect.midX >= centre - 1 { i -= 1 }
        i = min(max(i, 0), slots.count - 1)
        let r = slots[i].rect
        targetContentOffset.pointee = clamp(CGPoint(x: r.midX * z - w / 2, y: targetContentOffset.pointee.y))
    }

    // MARK: Tools

    func apply(tool: EditorTool, settings: ToolSettings) {
        let toolChanged = tool != self.tool
        self.tool = tool
        self.settings = settings
        if tool.usesCanvas { canvas.tool = settings.pkTool(for: tool, scale: 1) }
        // A colour or size change only needs the new ink (keeps switching instant).
        guard toolChanged || !toolConfigured else { return }
        toolConfigured = true
        canvas.drawingGestureRecognizer.isEnabled = tool.usesCanvas
        shapeGesture.isEnabled = tool == .shape
        selectGesture.isEnabled = tool == .selectText
        textTap.isEnabled = tool == .text
        if tool != .selectText { clearSelection() }
        for v in pageViews.values { v.setEditable(tool == .text) }
        if tool != .text { view.endEditing(true) }
        configureScrolling()
    }

    func setDrawingPolicy(_ value: String) {
        policyPref = value
        applyDrawingPolicy()
    }

    private static let pencilSeenKey = "pencilSeen"

    private func applyDrawingPolicy() {
        let policy: PKCanvasViewDrawingPolicy
        switch policyPref {
        case "pencil": policy = .pencilOnly
        case "any": policy = .anyInput
        default:
            // Once an Apple Pencil is in use, fingers and palms never draw.
            let pencil = UserDefaults.standard.bool(forKey: Self.pencilSeenKey) || UIPencilInteraction.prefersPencilOnlyDrawing
            policy = pencil ? .pencilOnly : .anyInput
        }
        if canvas.drawingPolicy != policy { canvas.drawingPolicy = policy }
        configureScrolling()
    }

    private func pencilSeen() {
        guard !UserDefaults.standard.bool(forKey: Self.pencilSeenKey) else { return }
        UserDefaults.standard.set(true, forKey: Self.pencilSeenKey)
        applyDrawingPolicy()
    }

    private var fingersDraw: Bool { canvas.drawingPolicy == .anyInput }

    /// Fingers scroll and zoom; the Pencil writes. With finger drawing on, two fingers scroll.
    func configureScrolling() {
        let writing = tool.usesCanvas || tool == .shape || tool == .selectText
        palmGuard.pencilBlocks = writing
        let pan = canvas.panGestureRecognizer
        let direct = NSNumber(value: UITouch.TouchType.direct.rawValue)
        let pointer = NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)
        let pencil = NSNumber(value: UITouch.TouchType.pencil.rawValue)
        pan.allowedTouchTypes = writing ? [direct, pointer] : [direct, pencil, pointer]
        let twoFingers = tool == .selectText || (fingersDraw && (tool.usesCanvas || tool == .shape))
        pan.minimumNumberOfTouches = twoFingers ? 2 : 1
        canvas.pinchGestureRecognizer?.allowedTouchTypes = [direct]
        let shapeTypes: [UITouch.TouchType] = fingersDraw ? [.pencil, .direct] : [.pencil]
        shapeGesture.allowedTouchTypes = shapeTypes.map { NSNumber(value: $0.rawValue) }
        selectGesture.allowedTouchTypes = [pencil, direct]
    }

    /// Freezes scrolling and zooming while the Pencil or a palm is on the glass.
    private func setNavigationBlocked(_ level: PalmGuard.Block) {
        unblockTask?.cancel()
        dlog("navigation: \(level)")
        if level == .scroll {
            // A broad touch alone: hold the page still, but let a one-hand pinch (thumb + finger) zoom.
            if canvas.isDecelerating { canvas.setContentOffset(canvas.contentOffset, animated: false) }
            canvas.isScrollEnabled = false
            canvas.pinchGestureRecognizer?.isEnabled = true
        } else if level == .all {
            // Stop any scroll still gliding, and cancel a scroll/zoom a palm may have started.
            if canvas.isDecelerating { canvas.setContentOffset(canvas.contentOffset, animated: false) }
            canvas.panGestureRecognizer.isEnabled = false
            canvas.panGestureRecognizer.isEnabled = true
            canvas.isScrollEnabled = false
            canvas.pinchGestureRecognizer?.isEnabled = false
        } else {
            unblockTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 80_000_000)
                guard !Task.isCancelled, let self else { return }
                self.canvas.isScrollEnabled = true
                self.canvas.pinchGestureRecognizer?.isEnabled = true
            }
        }
    }

    @objc private func pinchChanged(_ g: UIPinchGestureRecognizer) {
        if g.state == .began {
            palmGuard.pinchBegan()
            canvas.isScrollEnabled = true
        }
    }

    func setRuler(_ on: Bool) {
        rulerActive = on
        canvas.isRulerActive = on
    }

    var undoManager: UndoManager? { canvas.undoManager }
    func undo() { undoManager?.undo() }
    func redo() { undoManager?.redo() }

    /// Makes the canvas first responder so ⌘Z and the Pencil work straight away.
    func activate() { canvas.becomeFirstResponder() }

    // MARK: Ink → pages

    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        guard !applying, snap == nil else { return }
        splitTask?.cancel()
        splitTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            self?.splitNow()
        }
    }

    /// Pushes all pending canvas edits to the model.
    func flushAll() { splitNow() }

    /// Splits the canvas ink into pages and reports the pages that changed.
    private func splitNow() {
        splitTask?.cancel()
        splitTask = nil
        guard !slots.isEmpty else { return }
        var buckets = [[PKStroke]](repeating: [], count: slots.count)
        for st in canvas.drawing.strokes {
            if let i = pageIndex(of: st) { buckets[i].append(st) }
        }
        var changed: [(UUID, PKDrawing)] = []
        for (i, strokes) in buckets.enumerated() {
            let s = slots[i]
            let sig = Self.signature(strokes, origin: s.rect.origin)
            guard sig != signatures[s.id] else { continue }
            signatures[s.id] = sig
            let d = PKDrawing(strokes: strokes).transformed(using: CGAffineTransform(translationX: -s.rect.minX, y: -s.rect.minY))
            changed.append((s.id, d))
        }
        // Signatures are up to date before the model reacts (it may reload the layout).
        for (id, d) in changed { onDrawingChanged?(id, d) }
    }

    private static func signature(_ strokes: [PKStroke], origin: CGPoint) -> Int {
        var h = Hasher()
        h.combine(strokes.count)
        for st in strokes {
            let b = st.renderBounds
            h.combine(Int(((b.minX - origin.x) * 8).rounded()))
            h.combine(Int(((b.minY - origin.y) * 8).rounded()))
            h.combine(Int((b.width * 8).rounded()))
            h.combine(Int((b.height * 8).rounded()))
            h.combine(st.path.count)
            h.combine(st.ink.inkType.rawValue)
            var r: CGFloat = 0, g: CGFloat = 0, bl: CGFloat = 0, a: CGFloat = 0
            st.ink.color.getRed(&r, green: &g, blue: &bl, alpha: &a)
            h.combine(Int(r * 255)); h.combine(Int(g * 255)); h.combine(Int(bl * 255)); h.combine(Int(a * 255))
        }
        return h.finalize()
    }

    /// Erases all ink on a page (undoable).
    func clearPage(_ id: UUID) -> Bool {
        guard let i = indexByID[id] else { return false }
        let old = canvas.drawing
        var d = old
        d.strokes.removeAll { pageIndex(of: $0) == i }
        guard d.strokes.count != old.strokes.count else { return true }
        canvas.drawing = d
        canvas.undoManager?.registerUndo(withTarget: canvas) { c in c.drawing = old }
        canvas.undoManager?.setActionName("Erase page")
        splitNow()
        return true
    }

    /// Replaces a page's ink programmatically (undo of page deletion, sync).
    func reloadDrawing(pageID: UUID) {
        guard let i = indexByID[pageID] else { return }
        let r = slots[i].rect
        let fresh = drawingForPage?(pageID) ?? PKDrawing()
        var d = canvas.drawing
        d.strokes.removeAll { pageIndex(of: $0) == i }
        d.strokes += fresh.transformed(using: CGAffineTransform(translationX: r.minX, y: r.minY)).strokes
        signatures[pageID] = Self.signature(fresh.strokes, origin: .zero)
        setDrawing(d)
    }

    // MARK: Draw and hold

    /// The Pencil paused mid-stroke: if the stroke so far is a shape, swap it for the clean
    /// shape immediately (the Pencil is still down, so moving on resizes it).
    private func beginSnap(points: [CGPoint], at p: CGPoint) -> Bool {
        guard tool.isInking, snap == nil, let inkTool = canvas.tool as? PKInkingTool else { return false }
        let st = canvas.drawingGestureRecognizer.state
        guard st == .began || st == .changed, points.count > 4 else { return false }
        let pts = points.map { ShapeRecognizer.Point(Double($0.x), Double($0.y)) }
        guard let shape = ShapeRecognizer.recognize(pts) else {
            dlog("hold: no shape (\(points.count) points)")
            return false
        }
        dlog("hold: snapped to \(shape.name)")
        let dark = canvas.overrideUserInterfaceStyle == .dark
        let color = dark ? PKInkingTool.convertColor(inkTool.color, from: .light, to: .dark) : inkTool.color
        snap = SnapSession(base: canvas.drawing, shape: shape, current: shape, anchor: p,
                           ink: inkTool.ink, width: inkTool.width, color: color)
        // Drop the hand-drawn stroke in progress; the clean shape shows instead.
        canvas.drawingGestureRecognizer.isEnabled = false
        canvas.drawingGestureRecognizer.isEnabled = true
        showSnapPreview()
        return true
    }

    private func adjustSnap(to p: CGPoint) {
        guard var s = snap else { return }
        let q = ShapeRecognizer.Point(Double(p.x), Double(p.y))
        switch s.shape {
        case let .line(a, _):
            s.current = .line(a, ShapeRecognizer.snapAngle(a, q))
        default:
            let c = s.shape.center
            let d0 = hypot(Double(s.anchor.x) - c.x, Double(s.anchor.y) - c.y)
            guard d0 > 4 else { return }
            let k = min(6, max(0.15, hypot(q.x - c.x, q.y - c.y) / d0))
            s.current = s.shape.scaled(by: k, about: c)
        }
        snap = s
        showSnapPreview()
    }

    private func showSnapPreview() {
        guard let s = snap else { previewLayer.path = nil; return }
        let path = UIBezierPath()
        let outline = ShapeRecognizer.outline(s.current)
        if let f = outline.first { path.move(to: CGPoint(x: f.x, y: f.y)) }
        for q in outline.dropFirst() { path.addLine(to: CGPoint(x: q.x, y: q.y)) }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        previewLayer.strokeColor = s.color.cgColor
        previewLayer.lineWidth = s.width
        previewLayer.path = path.cgPath
        CATransaction.commit()
    }

    /// The Pencil lifted: the shape becomes a real (undoable) stroke.
    private func commitSnap() {
        guard let s = snap else { return }
        let outline = ShapeRecognizer.outline(s.current).map { CGPoint(x: $0.x, y: $0.y) }
        let sampled: [CGPoint]
        if case .ellipse = s.current { sampled = outline } else { sampled = InkConverter.sample(outline) }
        var d = s.base
        d.strokes.append(InkConverter.stroke(sampled, ink: s.ink, width: s.width))
        snap = nil
        canvas.drawing = d
        previewLayer.path = nil
        let base = s.base
        canvas.undoManager?.registerUndo(withTarget: canvas) { c in c.drawing = base }
        canvas.undoManager?.setActionName("Shape")
        canvasViewDrawingDidChange(canvas)
    }

    // MARK: Shape tool

    @objc private func shapeDrag(_ g: UILongPressGestureRecognizer) {
        let p = basePoint(g.location(in: canvas))
        switch g.state {
        case .began:
            shapeStart = p
        case .changed:
            guard let a = shapeStart else { return }
            let shape = InkConverter.Shape(rawValue: settings.shape) ?? .rectangle
            let path = UIBezierPath()
            for pts in InkConverter.outline(shape, from: a, to: p) {
                guard let f = pts.first else { continue }
                path.move(to: f)
                for q in pts.dropFirst() { path.addLine(to: q) }
            }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            previewLayer.path = path.cgPath
            previewLayer.strokeColor = settings.shapeColor.uiColor.cgColor
            previewLayer.lineWidth = CGFloat(settings.shapeWidth)
            CATransaction.commit()
        case .ended:
            defer { shapeStart = nil; previewLayer.path = nil }
            guard let a = shapeStart, hypot(p.x - a.x, p.y - a.y) > 4 else { return }
            let shape = InkConverter.Shape(rawValue: settings.shape) ?? .rectangle
            let ink = PKInk(.pen, color: settings.shapeColor.uiColor)
            let strokes = InkConverter.outline(shape, from: a, to: p).map {
                InkConverter.stroke($0, ink: ink, width: CGFloat(settings.shapeWidth))
            }
            let old = canvas.drawing
            var d = old
            d.strokes.append(contentsOf: strokes)
            canvas.drawing = d
            canvas.undoManager?.registerUndo(withTarget: canvas) { c in c.drawing = old }
            canvas.undoManager?.setActionName("Shape")
            canvasViewDrawingDidChange(canvas)
        default:
            shapeStart = nil
            previewLayer.path = nil
        }
    }

    // MARK: Text boxes & images

    private func elementHit(_ point: CGPoint, _ event: UIEvent?) -> UIView? {
        guard tool == .text else { return nil }
        for pv in pageViews.values {
            for ev in pv.elementViews.values {
                let p = canvas.convert(point, to: ev)
                if let h = ev.hitTest(p, with: event) { return h }
            }
        }
        return nil
    }

    @objc private func textTapped(_ g: UITapGestureRecognizer) {
        if let editing = pageViews.values.flatMap({ $0.elementViews.values }).first(where: { $0.isEditing }) {
            editing.finishEditing()
            return
        }
        let p = basePoint(g.location(in: canvas))
        guard let i = pageIndex(at: p), slots[i].rect.contains(p) else { return }
        let r = slots[i].rect
        onAddTextBox?(slots[i].id, CGPoint(x: p.x - r.minX, y: p.y - r.minY))
    }

    func elementsChanged(pageID: UUID) {
        guard let page = pageLookup?(pageID) else { return }
        pages[pageID] = page
        pageViews[pageID]?.setElements(page.elements)
        pageViews[pageID]?.setTextScale(textScale)
    }

    func beginEditing(element id: UUID, pageID: UUID) {
        if pageViews[pageID] == nil { go(to: pageID) }
        pageViews[pageID]?.elementViews[id]?.beginTextEditing()
    }

    // MARK: PDF text selection & highlights

    @objc private func selectDrag(_ g: UILongPressGestureRecognizer) {
        let p = basePoint(g.location(in: canvas))
        switch g.state {
        case .began:
            guard let i = pageIndex(at: p), slots[i].rect.contains(p) else { selectAnchor = nil; return }
            let r = slots[i].rect
            selectAnchor = (i, CGPoint(x: p.x - r.minX, y: p.y - r.minY))
            clearSelection()
        case .changed, .ended:
            guard let a = selectAnchor else { return }
            let r = slots[a.index].rect
            let q = CGPoint(x: min(max(p.x, r.minX), r.maxX) - r.minX, y: min(max(p.y, r.minY), r.maxY) - r.minY)
            select(pageIndex: a.index, from: a.point, to: q)
            if g.state == .ended { selectAnchor = nil }
        default:
            selectAnchor = nil
        }
    }

    private func pdfPage(for id: UUID) -> (PDFPage, CGPDFPage, CGSize)? {
        guard let nb = notebook, let store, let page = pages[id], case let .pdf(file, index) = page.background,
              let pdf = PDFCache.shared.page(at: store.assetURL(notebook: nb.id, file: file), index: index),
              let cg = pdf.pageRef else { return nil }
        return (pdf, cg, CGSize(width: page.size.width, height: page.size.height))
    }

    private func select(pageIndex i: Int, from a: CGPoint, to b: CGPoint) {
        let id = slots[i].id
        guard let (pdf, cg, size) = pdfPage(for: id) else { return }
        let toPDF = PageRenderer.pdfToDisplay(cg, size: size).inverted()
        guard let sel = pdf.selection(from: a.applying(toPDF), to: b.applying(toPDF)) else {
            clearSelection()
            return
        }
        selection = TextSelection(pageID: id, selection: sel, pdfPage: pdf)
        drawSelection()
        onSelectionChanged?(!(sel.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    private func selectionPageRects() -> [CGRect] {
        guard let s = selection, let (_, cg, size) = pdfPage(for: s.pageID) else { return [] }
        let toDisplay = PageRenderer.pdfToDisplay(cg, size: size)
        return s.selection.selectionsByLine().map { $0.bounds(for: s.pdfPage).applying(toDisplay) }.filter { !$0.isEmpty }
    }

    private func drawSelection() {
        guard let s = selection, let i = indexByID[s.pageID] else { selectionLayer.path = nil; return }
        let o = slots[i].rect.origin
        let path = UIBezierPath()
        for r in selectionPageRects() { path.append(UIBezierPath(rect: r.offsetBy(dx: o.x, dy: o.y))) }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        selectionLayer.path = path.cgPath
        CATransaction.commit()
    }

    /// Shows a search hit from an imported PDF.
    func show(selection sel: PDFSelection, pageID: UUID) {
        guard let pdf = sel.pages.first, let i = indexByID[pageID] else { go(to: pageID); return }
        selection = TextSelection(pageID: pageID, selection: sel, pdfPage: pdf)
        drawSelection()
        let rects = selectionPageRects()
        if let first = rects.first {
            let z = canvas.zoomScale
            let r = slots[i].rect
            let target = CGPoint(x: canvas.contentOffset.x, y: (r.minY + first.minY) * z - canvas.bounds.height * 0.35)
            if horizontal { go(to: pageID) } else { canvas.setContentOffset(clamp(target), animated: true) }
        } else {
            go(to: pageID)
        }
    }

    /// The current text selection as per-page rectangles in page coordinates.
    func selectionRects() -> [(UUID, [PageRect], String)] {
        guard let s = selection else { return [] }
        let rects = selectionPageRects().map { PageRect(x: $0.minX, y: $0.minY, w: $0.width, h: $0.height) }
        guard !rects.isEmpty else { return [] }
        let text = s.selection.selectionsByLine().compactMap(\.string).joined(separator: " ")
        return [(s.pageID, rects, text)]
    }

    func clearSelection() {
        guard selection != nil || selectionLayer.path != nil else { return }
        selection = nil
        selectionLayer.path = nil
        onSelectionChanged?(false)
    }

    /// Redraws a page's highlights.
    func setHighlights(_ highlights: [PageHighlight], pageID: UUID, size: PageDimensions) {
        guard var p = pages[pageID] else { return }
        p.highlights = highlights
        pages[pageID] = p
        if let i = indexByID[pageID], let info = renderInfo(pageID) { pageViews[pageID]?.update(info: info, frame: slots[i].rect) }
    }
}

// MARK: - Element view

/// A movable, resizable text box or image on a page.
final class ElementView: UIView, UITextViewDelegate {
    var element: PageElement { didSet { refresh() } }
    var image: UIImage? { didSet { imageView.image = image } }
    var scale: CGFloat = 1 { didSet { refresh() } }
    var onChange: ((PageElement) -> Void)?
    var onDelete: ((UUID) -> Void)?
    private(set) var isEditing = false

    private let textView = UITextView()
    private let imageView = UIImageView()
    private let handle = UIView()
    private let deleteButton = UIButton(type: .system)
    private var editable = false
    private var dragStart: PageRect?

    init(element: PageElement) {
        self.element = element
        super.init(frame: .zero)
        backgroundColor = .clear
        layer.borderColor = Ded.uiAccent.cgColor

        textView.backgroundColor = .clear
        textView.isScrollEnabled = false
        textView.isEditable = false
        textView.isSelectable = false
        textView.textContainerInset = UIEdgeInsets(top: ElementText.inset, left: ElementText.inset, bottom: ElementText.inset, right: ElementText.inset)
        textView.textContainer.lineFragmentPadding = 0
        textView.delegate = self
        imageView.contentMode = .scaleAspectFit
        addSubview(element.kind == .text ? textView : imageView)

        handle.backgroundColor = Ded.uiAccent
        handle.layer.cornerRadius = 7
        handle.isHidden = true
        addSubview(handle)
        deleteButton.setImage(UIImage(systemName: "xmark.circle.fill"), for: .normal)
        deleteButton.tintColor = UIColor(hex: 0xB0493E)
        deleteButton.isHidden = true
        deleteButton.addTarget(self, action: #selector(deleteTapped), for: .touchUpInside)
        addSubview(deleteButton)

        addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(moved(_:))))
        handle.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(resized(_:))))
        let tap = UITapGestureRecognizer(target: self, action: #selector(tappedSelf))
        addGestureRecognizer(tap)
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func refresh() {
        let f = element.frame
        bounds = CGRect(x: 0, y: 0, width: f.w * scale, height: f.h * scale)
        center = CGPoint(x: (f.x + f.w / 2) * scale, y: (f.y + f.h / 2) * scale)
        transform = CGAffineTransform(rotationAngle: CGFloat(element.rotation * .pi / 180))
        textView.frame = bounds
        imageView.frame = bounds
        if element.kind == .text && !isEditing {
            var attrs = ElementText.attributes(element)
            attrs[.font] = UIFont(descriptor: ElementText.font(element).fontDescriptor, size: CGFloat(element.fontSize) * scale)
            textView.attributedText = NSAttributedString(string: element.text.isEmpty ? " " : element.text, attributes: attrs)
            textView.textContainerInset = UIEdgeInsets(top: ElementText.inset * scale, left: ElementText.inset * scale,
                                                       bottom: ElementText.inset * scale, right: ElementText.inset * scale)
        }
        handle.frame = CGRect(x: bounds.width - 10, y: bounds.height - 10, width: 14, height: 14)
        deleteButton.frame = CGRect(x: -14, y: -14, width: 28, height: 28)
    }

    func setEditable(_ on: Bool) {
        editable = on
        isUserInteractionEnabled = on
        layer.borderWidth = on ? 1 : 0
        layer.borderColor = Ded.uiAccent.withAlphaComponent(0.5).cgColor
        handle.isHidden = !on
        deleteButton.isHidden = !on
        if !on { finishEditing() }
    }

    @objc private func tappedSelf() {
        guard editable, element.kind == .text else { return }
        beginTextEditing()
    }

    func beginTextEditing() {
        guard element.kind == .text else { return }
        isEditing = true
        textView.isEditable = true
        textView.isSelectable = true
        if element.text.isEmpty { textView.text = "" }
        textView.becomeFirstResponder()
    }

    func finishEditing() {
        guard isEditing else { return }
        isEditing = false
        textView.isEditable = false
        textView.isSelectable = false
        textView.resignFirstResponder()
        element.text = textView.text ?? ""
        if element.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            onDelete?(element.id)
        } else {
            onChange?(element)
        }
    }

    func textViewDidEndEditing(_ textView: UITextView) { finishEditing() }

    func textViewDidChange(_ textView: UITextView) {
        // Grow the box to fit the text.
        let fitting = textView.sizeThatFits(CGSize(width: bounds.width, height: .greatestFiniteMagnitude))
        let h = max(element.frame.h, Double(fitting.height / max(scale, 0.01)))
        if abs(h - element.frame.h) > 0.5 {
            var e = element
            e.frame.h = h
            e.text = textView.text ?? ""
            let wasEditing = isEditing
            isEditing = false
            element = e
            isEditing = wasEditing
        }
    }

    @objc private func deleteTapped() { onDelete?(element.id) }

    @objc private func moved(_ g: UIPanGestureRecognizer) {
        guard editable, !isEditing else { return }
        let t = g.translation(in: superview)
        switch g.state {
        case .began: dragStart = element.frame
        case .changed:
            guard let s = dragStart else { return }
            element.frame = PageRect(x: s.x + Double(t.x / scale), y: s.y + Double(t.y / scale), w: s.w, h: s.h)
        case .ended, .cancelled:
            dragStart = nil
            onChange?(element)
        default: break
        }
    }

    @objc private func resized(_ g: UIPanGestureRecognizer) {
        guard editable else { return }
        let t = g.translation(in: superview)
        switch g.state {
        case .began: dragStart = element.frame
        case .changed:
            guard let s = dragStart else { return }
            var w = max(30, s.w + Double(t.x / scale))
            var h = max(20, s.h + Double(t.y / scale))
            if element.kind != .text, let img = image, img.size.width > 0 {
                // Keep the picture's proportions.
                let aspect = Double(img.size.height / img.size.width)
                h = w * aspect
                if h < 20 { h = 20; w = h / aspect }
            }
            element.frame = PageRect(x: s.x, y: s.y, w: w, h: h)
        case .ended, .cancelled:
            dragStart = nil
            onChange?(element)
        default: break
        }
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        // Let the delete button and the resize handle stick out of the box.
        bounds.insetBy(dx: -16, dy: -16).contains(point)
    }
}

/// Hosts the canvas in SwiftUI.
struct NotebookCanvasRepresentable: UIViewRepresentable {
    let controller: NotebookCanvasController

    func makeUIView(context: Context) -> UIView { controller.view }
    func updateUIView(_ uiView: UIView, context: Context) {}
}
