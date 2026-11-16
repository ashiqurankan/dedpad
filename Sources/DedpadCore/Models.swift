import Foundation

// MARK: - Page geometry

public struct PageDimensions: Hashable, Sendable, Codable {
    public var width: Double
    public var height: Double
    public init(width: Double, height: Double) { self.width = width; self.height = height }

    public var landscape: PageDimensions { PageDimensions(width: max(width, height), height: min(width, height)) }
    public var portrait: PageDimensions { PageDimensions(width: min(width, height), height: max(width, height)) }
    public var isLandscape: Bool { width > height }
}

/// Page sizes in PDF points (1/72 in).
public enum PageSizePreset: String, CaseIterable, Codable, Sendable, Identifiable {
    case a4, a5, letter, b5, screen, square

    public var id: String { rawValue }

    public var name: String {
        switch self {
        case .a4: return "A4"
        case .a5: return "A5"
        case .letter: return "US Letter"
        case .b5: return "B5"
        case .screen: return "iPad screen"
        case .square: return "Square"
        }
    }

    public var dimensions: PageDimensions {
        switch self {
        case .a4: return PageDimensions(width: 595, height: 842)
        case .a5: return PageDimensions(width: 420, height: 595)
        case .letter: return PageDimensions(width: 612, height: 792)
        case .b5: return PageDimensions(width: 499, height: 709)
        case .screen: return PageDimensions(width: 615, height: 820)
        case .square: return PageDimensions(width: 700, height: 700)
        }
    }
}

public enum PageOrientation: String, CaseIterable, Codable, Sendable, Identifiable {
    case portrait, landscape
    public var id: String { rawValue }
    public var name: String { self == .portrait ? "Portrait" : "Landscape" }
}

public enum PageMode: String, CaseIterable, Codable, Sendable, Identifiable {
    /// Pages with fixed boundaries, created by the user.
    case fixed
    /// One long vertical canvas that grows as you write.
    case continuous
    public var id: String { rawValue }
    public var name: String { self == .fixed ? "Fixed pages" : "Continuous" }
}

public enum PageNumberPosition: String, CaseIterable, Codable, Sendable, Identifiable {
    case none, bottomCenter, bottomOuter, topOuter
    public var id: String { rawValue }
    public var name: String {
        switch self {
        case .none: return "Off"
        case .bottomCenter: return "Bottom centre"
        case .bottomOuter: return "Bottom corner"
        case .topOuter: return "Top corner"
        }
    }
}

// MARK: - Paper

/// What a page looks like underneath the handwriting.
public struct PaperSpec: Hashable, Sendable, Codable {
    public var style: PaperStyle
    public var background: RGBA
    public var lineColor: RGBA
    public var accentColor: RGBA
    /// Line / grid / dot spacing in points.
    public var spacing: Double
    /// Outer page margin in points.
    public var margin: Double

    public init(
        style: PaperStyle = .ruled,
        background: RGBA = DedPalette.paper,
        lineColor: RGBA = DedPalette.paperLine,
        accentColor: RGBA = DedPalette.marginLine,
        spacing: Double? = nil,
        margin: Double = 36
    ) {
        self.style = style
        self.background = background
        self.lineColor = lineColor
        self.accentColor = accentColor
        self.spacing = spacing ?? style.defaultSpacing
        self.margin = margin
    }

    /// Switches style and resets spacing to the new style's default.
    public func with(style: PaperStyle) -> PaperSpec {
        var s = self
        s.style = style
        s.spacing = style.defaultSpacing
        return s
    }

    enum CodingKeys: String, CodingKey { case style, background, lineColor, accentColor, spacing, margin }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let styleRaw = try c.decodeIfPresent(String.self, forKey: .style) ?? PaperStyle.ruled.rawValue
        style = PaperStyle(rawValue: styleRaw) ?? .ruled
        background = try c.decodeIfPresent(RGBA.self, forKey: .background) ?? DedPalette.paper
        lineColor = try c.decodeIfPresent(RGBA.self, forKey: .lineColor) ?? DedPalette.paperLine
        accentColor = try c.decodeIfPresent(RGBA.self, forKey: .accentColor) ?? DedPalette.marginLine
        spacing = try c.decodeIfPresent(Double.self, forKey: .spacing) ?? style.defaultSpacing
        margin = try c.decodeIfPresent(Double.self, forKey: .margin) ?? 36
    }
}

// MARK: - Covers

public enum CoverPattern: String, CaseIterable, Codable, Sendable, Identifiable {
    case none, stripes, pinstripe, dots, grid, diagonal, linen, waves, arcs, checks, frame
    public var id: String { rawValue }
    public var name: String {
        switch self {
        case .none: return "Plain"
        case .stripes: return "Stripes"
        case .pinstripe: return "Pinstripe"
        case .dots: return "Dots"
        case .grid: return "Grid"
        case .diagonal: return "Diagonal"
        case .linen: return "Linen"
        case .waves: return "Waves"
        case .arcs: return "Arcs"
        case .checks: return "Checks"
        case .frame: return "Frame"
        }
    }
}

public enum CoverFont: String, CaseIterable, Codable, Sendable, Identifiable {
    case display, sans, serif, italic, mono
    public var id: String { rawValue }
    public var name: String {
        switch self {
        case .display: return "Manrope"
        case .sans: return "DM Sans"
        case .serif: return "Serif"
        case .italic: return "Italic"
        case .mono: return "Mono"
        }
    }
}

public enum CoverTitlePlacement: String, CaseIterable, Codable, Sendable, Identifiable {
    case top, center, bottom, label, hidden
    public var id: String { rawValue }
    public var name: String {
        switch self {
        case .top: return "Top"
        case .center: return "Centre"
        case .bottom: return "Bottom"
        case .label: return "Label"
        case .hidden: return "Hidden"
        }
    }
}

public struct CoverDesign: Hashable, Sendable, Codable {
    /// Preset identifier, if the cover came from the gallery.
    public var presetID: String?
    public var color: RGBA
    public var pattern: CoverPattern
    public var patternColor: RGBA
    public var titleColor: RGBA
    public var titleFont: CoverFont
    public var titlePlacement: CoverTitlePlacement
    /// File name of an uploaded cover image inside the notebook's `assets` folder.
    public var imageFile: String?
    /// Darkens an uploaded image slightly so the title stays readable.
    public var imageDim: Double

    public init(
        presetID: String? = nil,
        color: RGBA = DedPalette.brand,
        pattern: CoverPattern = .none,
        patternColor: RGBA = RGBA(0xFFFFFF, alpha: 0.18),
        titleColor: RGBA = .white,
        titleFont: CoverFont = .display,
        titlePlacement: CoverTitlePlacement = .bottom,
        imageFile: String? = nil,
        imageDim: Double = 0.15
    ) {
        self.presetID = presetID
        self.color = color
        self.pattern = pattern
        self.patternColor = patternColor
        self.titleColor = titleColor
        self.titleFont = titleFont
        self.titlePlacement = titlePlacement
        self.imageFile = imageFile
        self.imageDim = imageDim
    }

    enum CodingKeys: String, CodingKey {
        case presetID, color, pattern, patternColor, titleColor, titleFont, titlePlacement, imageFile, imageDim
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        presetID = try c.decodeIfPresent(String.self, forKey: .presetID)
        color = try c.decodeIfPresent(RGBA.self, forKey: .color) ?? DedPalette.brand
        pattern = CoverPattern(rawValue: try c.decodeIfPresent(String.self, forKey: .pattern) ?? "") ?? .none
        patternColor = try c.decodeIfPresent(RGBA.self, forKey: .patternColor) ?? RGBA(0xFFFFFF, alpha: 0.18)
        titleColor = try c.decodeIfPresent(RGBA.self, forKey: .titleColor) ?? .white
        titleFont = CoverFont(rawValue: try c.decodeIfPresent(String.self, forKey: .titleFont) ?? "") ?? .display
        titlePlacement = CoverTitlePlacement(rawValue: try c.decodeIfPresent(String.self, forKey: .titlePlacement) ?? "") ?? .bottom
        imageFile = try c.decodeIfPresent(String.self, forKey: .imageFile)
        imageDim = try c.decodeIfPresent(Double.self, forKey: .imageDim) ?? 0.15
    }
}

// MARK: - Notebook settings

public struct NotebookSettings: Hashable, Sendable, Codable {
    public var pageSize: PageSizePreset
    public var orientation: PageOrientation
    public var mode: PageMode
    public var paper: PaperSpec
    public var pageNumbers: PageNumberPosition

    public init(
        pageSize: PageSizePreset = .a4,
        orientation: PageOrientation = .portrait,
        mode: PageMode = .fixed,
        paper: PaperSpec = PaperSpec(),
        pageNumbers: PageNumberPosition = .bottomCenter
    ) {
        self.pageSize = pageSize
        self.orientation = orientation
        self.mode = mode
        self.paper = paper
        self.pageNumbers = pageNumbers
    }

    /// Size of a newly created page.
    public var pageDimensions: PageDimensions {
        orientation == .portrait ? pageSize.dimensions.portrait : pageSize.dimensions.landscape
    }

    enum CodingKeys: String, CodingKey { case pageSize, orientation, mode, paper, pageNumbers }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pageSize = PageSizePreset(rawValue: try c.decodeIfPresent(String.self, forKey: .pageSize) ?? "") ?? .a4
        orientation = PageOrientation(rawValue: try c.decodeIfPresent(String.self, forKey: .orientation) ?? "") ?? .portrait
        mode = PageMode(rawValue: try c.decodeIfPresent(String.self, forKey: .mode) ?? "") ?? .fixed
        paper = try c.decodeIfPresent(PaperSpec.self, forKey: .paper) ?? PaperSpec()
        pageNumbers = PageNumberPosition(rawValue: try c.decodeIfPresent(String.self, forKey: .pageNumbers) ?? "") ?? .bottomCenter
    }
}

// MARK: - Pages

/// What sits underneath a page's handwriting besides the paper pattern.
public enum PageBackground: Hashable, Sendable, Codable {
    /// Just the paper template.
    case paper
    /// A page of an imported PDF stored in the notebook's `assets` folder.
    case pdf(file: String, pageIndex: Int)
    /// An imported image stored in the notebook's `assets` folder, drawn on top of the paper.
    case image(file: String)

    enum CodingKeys: String, CodingKey { case kind, file, pageIndex }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decodeIfPresent(String.self, forKey: .kind) ?? "paper" {
        case "pdf":
            self = .pdf(file: try c.decode(String.self, forKey: .file), pageIndex: try c.decodeIfPresent(Int.self, forKey: .pageIndex) ?? 0)
        case "image":
            self = .image(file: try c.decode(String.self, forKey: .file))
        default:
            self = .paper
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .paper:
            try c.encode("paper", forKey: .kind)
        case let .pdf(file, index):
            try c.encode("pdf", forKey: .kind)
            try c.encode(file, forKey: .file)
            try c.encode(index, forKey: .pageIndex)
        case let .image(file):
            try c.encode("image", forKey: .kind)
            try c.encode(file, forKey: .file)
        }
    }

    public var assetFile: String? {
        switch self {
        case .paper: return nil
        case let .pdf(file, _): return file
        case let .image(file): return file
        }
    }
}

public struct Page: Identifiable, Hashable, Sendable, Codable {
    public var id: UUID
    public var size: PageDimensions
    /// Overrides the notebook's default paper for this page.
    public var paper: PaperSpec?
    public var background: PageBackground
    /// Typed text that belongs to the page (exported to TXT / Markdown).
    public var typedNotes: String
    /// Text boxes, images and stickers placed on the page (under the ink).
    public var elements: [PageElement]
    /// Text highlights on PDF pages, in page coordinates.
    public var highlights: [PageHighlight]
    public var isBookmarked: Bool
    /// Handwriting recognised on the device, used for search.
    public var recognizedText: String
    public var createdAt: Date
    public var modifiedAt: Date

    public init(
        id: UUID = UUID(),
        size: PageDimensions,
        paper: PaperSpec? = nil,
        background: PageBackground = .paper,
        typedNotes: String = "",
        elements: [PageElement] = [],
        highlights: [PageHighlight] = [],
        isBookmarked: Bool = false,
        recognizedText: String = "",
        createdAt: Date = Date(),
        modifiedAt: Date = Date()
    ) {
        self.id = id
        self.size = size
        self.paper = paper
        self.background = background
        self.typedNotes = typedNotes
        self.elements = elements
        self.highlights = highlights
        self.isBookmarked = isBookmarked
        self.recognizedText = recognizedText
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
    }

    /// File name of the page's PencilKit drawing inside `drawings/`.
    public var drawingFileName: String { "\(id.uuidString).drawing" }
    /// File name of the page's open ink JSON inside `drawings/`.
    public var inkFileName: String { "\(id.uuidString).ink.json" }

    /// Every asset file the page refers to.
    public var assetFiles: [String] {
        var out: [String] = []
        if let f = background.assetFile { out.append(f) }
        out += elements.compactMap(\.imageFile)
        return out
    }

    /// All searchable text on the page.
    public var searchableText: String {
        ([typedNotes, recognizedText] + elements.compactMap { $0.kind == .text ? $0.text : nil })
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    enum CodingKeys: String, CodingKey {
        case id, size, paper, background, typedNotes, elements, highlights, isBookmarked, recognizedText, createdAt, modifiedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        size = try c.decodeIfPresent(PageDimensions.self, forKey: .size) ?? PageSizePreset.a4.dimensions
        paper = try c.decodeIfPresent(PaperSpec.self, forKey: .paper)
        background = try c.decodeIfPresent(PageBackground.self, forKey: .background) ?? .paper
        typedNotes = try c.decodeIfPresent(String.self, forKey: .typedNotes) ?? ""
        elements = try c.decodeIfPresent([PageElement].self, forKey: .elements) ?? []
        highlights = try c.decodeIfPresent([PageHighlight].self, forKey: .highlights) ?? []
        isBookmarked = try c.decodeIfPresent(Bool.self, forKey: .isBookmarked) ?? false
        recognizedText = try c.decodeIfPresent(String.self, forKey: .recognizedText) ?? ""
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        modifiedAt = try c.decodeIfPresent(Date.self, forKey: .modifiedAt) ?? createdAt
    }
}

/// A rectangle in page points (top-left origin).
public struct PageRect: Hashable, Sendable, Codable {
    public var x: Double, y: Double, w: Double, h: Double
    public init(x: Double, y: Double, w: Double, h: Double) { self.x = x; self.y = y; self.w = w; self.h = h }
}

/// A text box, image or sticker on a page.
public struct PageElement: Identifiable, Hashable, Sendable, Codable {
    public enum Kind: String, Codable, Sendable { case text, image, sticker }

    public var id: UUID
    public var kind: Kind
    public var frame: PageRect
    /// Rotation in degrees.
    public var rotation: Double
    public var text: String
    public var fontSize: Double
    public var bold: Bool
    public var color: RGBA
    /// Image or sticker file in the notebook's `assets` folder.
    public var imageFile: String?

    public init(
        id: UUID = UUID(), kind: Kind, frame: PageRect, rotation: Double = 0, text: String = "",
        fontSize: Double = 16, bold: Bool = false, color: RGBA = DedPalette.text, imageFile: String? = nil
    ) {
        self.id = id; self.kind = kind; self.frame = frame; self.rotation = rotation; self.text = text
        self.fontSize = fontSize; self.bold = bold; self.color = color; self.imageFile = imageFile
    }

    enum CodingKeys: String, CodingKey { case id, kind, frame, rotation, text, fontSize, bold, color, imageFile }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        kind = Kind(rawValue: try c.decodeIfPresent(String.self, forKey: .kind) ?? "") ?? .text
        frame = try c.decodeIfPresent(PageRect.self, forKey: .frame) ?? PageRect(x: 40, y: 40, w: 200, h: 60)
        rotation = try c.decodeIfPresent(Double.self, forKey: .rotation) ?? 0
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        fontSize = try c.decodeIfPresent(Double.self, forKey: .fontSize) ?? 16
        bold = try c.decodeIfPresent(Bool.self, forKey: .bold) ?? false
        color = try c.decodeIfPresent(RGBA.self, forKey: .color) ?? DedPalette.text
        imageFile = try c.decodeIfPresent(String.self, forKey: .imageFile)
    }
}

/// A highlight over text on a PDF page (one rect per line).
public struct PageHighlight: Identifiable, Hashable, Sendable, Codable {
    public var id: UUID
    public var rects: [PageRect]
    public var color: RGBA
    public var text: String
    public init(id: UUID = UUID(), rects: [PageRect], color: RGBA = RGBA(0xF3E7A6, alpha: 0.6), text: String = "") {
        self.id = id; self.rects = rects; self.color = color; self.text = text
    }
}

// MARK: - Notebook

public struct Notebook: Identifiable, Hashable, Sendable, Codable {
    /// Bumped whenever the on-disk format changes; older files are migrated on load.
    public static let currentFormatVersion = 1

    public var formatVersion: Int
    public var id: UUID
    public var title: String
    public var details: String
    public var createdAt: Date
    public var modifiedAt: Date
    public var lastOpenedAt: Date?
    public var folderID: UUID?
    public var categories: [String]
    public var isArchived: Bool
    public var isFavorite: Bool
    /// Set when the notebook is in Recently Deleted.
    public var deletedAt: Date?
    public var cover: CoverDesign
    public var settings: NotebookSettings
    public var pages: [Page]

    public init(
        id: UUID = UUID(),
        title: String,
        details: String = "",
        createdAt: Date = Date(),
        folderID: UUID? = nil,
        categories: [String] = [],
        cover: CoverDesign = CoverDesign(),
        settings: NotebookSettings = NotebookSettings(),
        pages: [Page]? = nil
    ) {
        self.formatVersion = Notebook.currentFormatVersion
        self.id = id
        self.title = title
        self.details = details
        self.createdAt = createdAt
        self.modifiedAt = createdAt
        self.lastOpenedAt = nil
        self.folderID = folderID
        self.categories = categories
        self.isArchived = false
        self.isFavorite = false
        self.deletedAt = nil
        self.cover = cover
        self.settings = settings
        self.pages = pages ?? [Page(size: settings.pageDimensions)]
    }

    /// The paper used by a page (its own override, or the notebook default).
    public func paper(for page: Page) -> PaperSpec { page.paper ?? settings.paper }

    public var displayTitle: String {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? "Untitled notebook" : t
    }

    /// A new blank page using the notebook's defaults.
    public func makePage() -> Page { Page(size: settings.pageDimensions) }

    public mutating func touch(_ date: Date = Date()) { modifiedAt = date }

    public var isDeleted: Bool { deletedAt != nil }

    /// Every asset file referenced by pages, elements and the cover.
    public var referencedAssets: [String] {
        var names = pages.flatMap(\.assetFiles)
        if let c = cover.imageFile { names.append(c) }
        var seen = Set<String>()
        return names.filter { seen.insert($0).inserted }
    }

    enum CodingKeys: String, CodingKey {
        case formatVersion, id, title, details, createdAt, modifiedAt, lastOpenedAt, folderID, categories
        case isArchived, isFavorite, deletedAt, cover, settings, pages
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let version = try c.decodeIfPresent(Int.self, forKey: .formatVersion) ?? 1
        guard version <= Notebook.currentFormatVersion else {
            throw DedpadError.unsupportedVersion(version)
        }
        formatVersion = Notebook.currentFormatVersion
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        details = try c.decodeIfPresent(String.self, forKey: .details) ?? ""
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        modifiedAt = try c.decodeIfPresent(Date.self, forKey: .modifiedAt) ?? createdAt
        lastOpenedAt = try c.decodeIfPresent(Date.self, forKey: .lastOpenedAt)
        folderID = try c.decodeIfPresent(UUID.self, forKey: .folderID)
        categories = try c.decodeIfPresent([String].self, forKey: .categories) ?? []
        isArchived = try c.decodeIfPresent(Bool.self, forKey: .isArchived) ?? false
        isFavorite = try c.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
        deletedAt = try c.decodeIfPresent(Date.self, forKey: .deletedAt)
        cover = try c.decodeIfPresent(CoverDesign.self, forKey: .cover) ?? CoverDesign()
        settings = try c.decodeIfPresent(NotebookSettings.self, forKey: .settings) ?? NotebookSettings()
        pages = try c.decodeIfPresent([Page].self, forKey: .pages) ?? []
        if pages.isEmpty { pages = [Page(size: settings.pageDimensions)] }
    }
}

// MARK: - Library

public struct Folder: Identifiable, Hashable, Sendable, Codable {
    public var id: UUID
    public var name: String
    public var createdAt: Date
    public init(id: UUID = UUID(), name: String, createdAt: Date = Date()) {
        self.id = id; self.name = name; self.createdAt = createdAt
    }
}

/// `library.json`: things that are not owned by a single notebook.
public struct LibraryIndex: Sendable, Codable, Equatable {
    public var formatVersion: Int
    public var folders: [Folder]
    /// Page templates the user saved from the studio.
    public var savedPapers: [SavedPaper]

    public init(folders: [Folder] = [], savedPapers: [SavedPaper] = []) {
        self.formatVersion = 1
        self.folders = folders
        self.savedPapers = savedPapers
    }

    enum CodingKeys: String, CodingKey { case formatVersion, folders, savedPapers }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try c.decodeIfPresent(Int.self, forKey: .formatVersion) ?? 1
        folders = try c.decodeIfPresent([Folder].self, forKey: .folders) ?? []
        savedPapers = try c.decodeIfPresent([SavedPaper].self, forKey: .savedPapers) ?? []
    }
}

public struct SavedPaper: Identifiable, Hashable, Sendable, Codable {
    public var id: UUID
    public var name: String
    public var paper: PaperSpec
    public init(id: UUID = UUID(), name: String, paper: PaperSpec) {
        self.id = id; self.name = name; self.paper = paper
    }
}

public enum DedpadError: Error, LocalizedError, Equatable {
    case unsupportedVersion(Int)
    case notFound(String)
    case invalidArchive(String)
    case invalidBackup(String)

    public var errorDescription: String? {
        switch self {
        case let .unsupportedVersion(v): return "This notebook was made by a newer dedpad (format \(v)). Update the app to open it."
        case let .notFound(what): return "\(what) could not be found."
        case let .invalidArchive(why): return "That archive could not be read: \(why)"
        case let .invalidBackup(why): return "That backup could not be read: \(why)"
        }
    }
}
