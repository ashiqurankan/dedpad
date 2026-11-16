import Foundation

/// dedpad's open handwriting format (`<page>.ink.json`).
///
/// PencilKit's own data is kept for perfect fidelity on iPad, and this file is written next to it
/// so handwriting can be read anywhere: a Ded Notes web viewer, scripts, other apps. It is also
/// enough to rebuild a drawing if the PencilKit file is ever lost.
public struct InkPage: Codable, Equatable, Sendable {
    public static let format = "dedpad-ink"

    public var format: String
    public var version: Int
    /// Page size in points; stroke coordinates are page points with a top-left origin.
    public var width: Double
    public var height: Double
    public var strokes: [InkStroke]

    public init(width: Double, height: Double, strokes: [InkStroke]) {
        self.format = InkPage.format
        self.version = 1
        self.width = width
        self.height = height
        self.strokes = strokes
    }

    public func encoded() throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return try e.encode(self)
    }

    public static func decode(_ data: Data) throws -> InkPage {
        let page = try JSONDecoder().decode(InkPage.self, from: data)
        guard page.format == format else { throw DedpadError.invalidBackup("not a dedpad ink file") }
        return page
    }

    /// Bounding box of all points (nil if there is no ink).
    public var bounds: PageRect? {
        var minX = Double.infinity, minY = Double.infinity, maxX = -Double.infinity, maxY = -Double.infinity
        for s in strokes {
            for p in s.points {
                let (x, y) = s.transformed(p.x, p.y)
                minX = min(minX, x - p.width / 2); maxX = max(maxX, x + p.width / 2)
                minY = min(minY, y - p.width / 2); maxY = max(maxY, y + p.width / 2)
            }
        }
        guard minX.isFinite else { return nil }
        return PageRect(x: minX, y: minY, w: maxX - minX, h: maxY - minY)
    }
}

public struct InkStroke: Codable, Equatable, Sendable {
    /// pen, pencil, marker, monoline, fountainPen, watercolor, crayon
    public var tool: String
    public var color: RGBA
    /// Affine transform [a, b, c, d, tx, ty] applied to the points.
    public var transform: [Double]
    public var points: [InkPoint]

    public init(tool: String, color: RGBA, transform: [Double] = [1, 0, 0, 1, 0, 0], points: [InkPoint]) {
        self.tool = tool
        self.color = color
        self.transform = transform.count == 6 ? transform : [1, 0, 0, 1, 0, 0]
        self.points = points
    }

    public func transformed(_ x: Double, _ y: Double) -> (Double, Double) {
        let t = transform
        return (t[0] * x + t[2] * y + t[4], t[1] * x + t[3] * y + t[5])
    }
}

/// One sampled point. Encoded compactly as an array:
/// `[x, y, t, width, height, opacity, force, azimuth, altitude]`.
public struct InkPoint: Codable, Equatable, Sendable {
    public var x: Double, y: Double
    /// Seconds since the stroke began.
    public var t: Double
    public var width: Double, height: Double
    public var opacity: Double
    public var force: Double
    public var azimuth: Double
    public var altitude: Double

    public init(x: Double, y: Double, t: Double, width: Double, height: Double, opacity: Double = 1,
                force: Double = 1, azimuth: Double = 0, altitude: Double = .pi / 2) {
        self.x = x; self.y = y; self.t = t; self.width = width; self.height = height
        self.opacity = opacity; self.force = force; self.azimuth = azimuth; self.altitude = altitude
    }

    public init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        func next(_ d: Double) throws -> Double { c.isAtEnd ? d : try c.decode(Double.self) }
        x = try next(0); y = try next(0); t = try next(0)
        width = try next(2); height = try next(width); opacity = try next(1)
        force = try next(1); azimuth = try next(0); altitude = try next(.pi / 2)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.unkeyedContainer()
        for v in [x, y, t, width, height, opacity, force, azimuth, altitude] {
            try c.encode((v * 1000).rounded() / 1000)
        }
    }
}

/// Stable content fingerprints (FNV-1a, 64-bit) used for change detection and sync.
public enum ContentHash {
    public static func fnv64(_ data: Data) -> String {
        var h: UInt64 = 0xCBF2_9CE4_8422_2325
        data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            for b in buf { h ^= UInt64(b); h = h &* 0x0000_0100_0000_01B3 }
        }
        return String(h, radix: 16)
    }

    public static func fnv64(_ string: String) -> String { fnv64(Data(string.utf8)) }

    /// Fingerprint of a page: its metadata plus its drawing bytes.
    public static func page(_ page: Page, drawing: Data?) -> String {
        var p = page
        p.modifiedAt = Date(timeIntervalSince1970: 0)
        p.recognizedText = ""    // derived data, not a user edit
        let meta = (try? sortedEncoder.encode(p)) ?? Data()
        return fnv64(meta + (drawing ?? Data()))
    }

    /// Fingerprint of notebook-level metadata (title, cover, settings, folder…), excluding pages and dates.
    public static func notebookMeta(_ nb: Notebook) -> String {
        var n = nb
        n.pages = []
        n.modifiedAt = Date(timeIntervalSince1970: 0)
        n.lastOpenedAt = nil
        return fnv64((try? sortedEncoder.encode(n)) ?? Data())
    }

    private static let sortedEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        e.dateEncodingStrategy = .secondsSince1970
        return e
    }()
}
