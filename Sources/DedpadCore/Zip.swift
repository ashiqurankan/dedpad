import Foundation

/// Minimal ZIP support, so notebook archives need no third-party code.
/// Writes "stored" (uncompressed) entries; reads stored and — given an inflater — deflated ones.
public enum Zip {

    public struct Entry: Equatable, Sendable {
        public var path: String
        public var data: Data
        public init(path: String, data: Data) { self.path = path; self.data = data }
    }

    // MARK: CRC-32

    private static let crcTable: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    public static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            for b in buf { crc = crcTable[Int((crc ^ UInt32(b)) & 0xFF)] ^ (crc >> 8) }
        }
        return crc ^ 0xFFFF_FFFF
    }

    // MARK: Writing

    public static func archive(_ entries: [Entry], date: Date = Date()) -> Data {
        var out = Data()
        var central = Data()
        let (dosTime, dosDate) = dosDateTime(date)

        for entry in entries {
            let name = Data(entry.path.utf8)
            let crc = crc32(entry.data)
            let size = UInt32(truncatingIfNeeded: entry.data.count)
            let offset = UInt32(truncatingIfNeeded: out.count)

            // Local file header
            out.append(le32: 0x0403_4B50)
            out.append(le16: 20)          // version needed
            out.append(le16: 0x0800)      // UTF-8 names
            out.append(le16: 0)           // stored
            out.append(le16: dosTime)
            out.append(le16: dosDate)
            out.append(le32: crc)
            out.append(le32: size)
            out.append(le32: size)
            out.append(le16: UInt16(name.count))
            out.append(le16: 0)
            out.append(name)
            out.append(entry.data)

            // Central directory record
            central.append(le32: 0x0201_4B50)
            central.append(le16: 0x031E)  // made by: Unix, 3.0
            central.append(le16: 20)
            central.append(le16: 0x0800)
            central.append(le16: 0)
            central.append(le16: dosTime)
            central.append(le16: dosDate)
            central.append(le32: crc)
            central.append(le32: size)
            central.append(le32: size)
            central.append(le16: UInt16(name.count))
            central.append(le16: 0)       // extra
            central.append(le16: 0)       // comment
            central.append(le16: 0)       // disk
            central.append(le16: 0)       // internal attrs
            central.append(le32: entry.path.hasSuffix("/") ? 0x41ED_0010 : 0x81A4_0000) // external attrs (rw-r--r--)
            central.append(le32: offset)
            central.append(name)
        }

        let centralOffset = UInt32(truncatingIfNeeded: out.count)
        out.append(central)
        out.append(le32: 0x0605_4B50)
        out.append(le16: 0)
        out.append(le16: 0)
        out.append(le16: UInt16(truncatingIfNeeded: entries.count))
        out.append(le16: UInt16(truncatingIfNeeded: entries.count))
        out.append(le32: UInt32(truncatingIfNeeded: central.count))
        out.append(le32: centralOffset)
        out.append(le16: 0)
        return out
    }

    private static func dosDateTime(_ date: Date) -> (UInt16, UInt16) {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone.current
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let year = max(1980, c.year ?? 1980)
        let time = UInt16(((c.hour ?? 0) << 11) | ((c.minute ?? 0) << 5) | ((c.second ?? 0) / 2))
        let day = UInt16(((year - 1980) << 9) | ((c.month ?? 1) << 5) | (c.day ?? 1))
        return (time, day)
    }

    // MARK: Reading

    /// Raw DEFLATE decompressor: `(compressed, expectedSize) -> data`.
    public typealias Inflater = (Data, Int) throws -> Data

    public static func entries(in data: Data, inflate: Inflater? = nil) throws -> [Entry] {
        let bytes = [UInt8](data)
        guard bytes.count >= 22 else { throw DedpadError.invalidArchive("file is too small") }

        // Find the end-of-central-directory record (it may be followed by a comment).
        var eocd = -1
        var i = bytes.count - 22
        let lowest = max(0, bytes.count - 22 - 0xFFFF)
        while i >= lowest {
            if bytes.u32(i) == 0x0605_4B50 { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0 else { throw DedpadError.invalidArchive("not a ZIP file") }

        let count = Int(bytes.u16(eocd + 10))
        var p = Int(bytes.u32(eocd + 16))
        var result: [Entry] = []

        for _ in 0..<count {
            guard p + 46 <= bytes.count, bytes.u32(p) == 0x0201_4B50 else {
                throw DedpadError.invalidArchive("damaged directory")
            }
            let method = bytes.u16(p + 10)
            let compressed = Int(bytes.u32(p + 20))
            let size = Int(bytes.u32(p + 24))
            let nameLen = Int(bytes.u16(p + 28))
            let extraLen = Int(bytes.u16(p + 30))
            let commentLen = Int(bytes.u16(p + 32))
            let localOffset = Int(bytes.u32(p + 42))
            guard p + 46 + nameLen <= bytes.count else { throw DedpadError.invalidArchive("damaged name") }
            let name = String(decoding: bytes[(p + 46)..<(p + 46 + nameLen)], as: UTF8.self)
            p += 46 + nameLen + extraLen + commentLen

            guard localOffset + 30 <= bytes.count, bytes.u32(localOffset) == 0x0403_4B50 else {
                throw DedpadError.invalidArchive("damaged entry \(name)")
            }
            let start = localOffset + 30 + Int(bytes.u16(localOffset + 26)) + Int(bytes.u16(localOffset + 28))
            guard start + compressed <= bytes.count else { throw DedpadError.invalidArchive("truncated entry \(name)") }
            if name.hasSuffix("/") { continue }
            let raw = Data(bytes[start..<(start + compressed)])

            switch method {
            case 0:
                result.append(Entry(path: name, data: raw))
            case 8:
                guard let inflate else { throw DedpadError.invalidArchive("compressed entries are not supported here") }
                result.append(Entry(path: name, data: try inflate(raw, size)))
            default:
                throw DedpadError.invalidArchive("unsupported compression in \(name)")
            }
        }
        return result
    }
}

private extension Data {
    mutating func append(le16 v: UInt16) { append(UInt8(v & 0xFF)); append(UInt8(v >> 8)) }
    mutating func append(le32 v: UInt32) {
        append(UInt8(v & 0xFF)); append(UInt8((v >> 8) & 0xFF)); append(UInt8((v >> 16) & 0xFF)); append(UInt8(v >> 24))
    }
}

private extension Array where Element == UInt8 {
    func u16(_ i: Int) -> UInt16 { guard i + 1 < count else { return 0 }; return UInt16(self[i]) | UInt16(self[i + 1]) << 8 }
    func u32(_ i: Int) -> UInt32 {
        guard i + 3 < count else { return 0 }
        return UInt32(self[i]) | UInt32(self[i + 1]) << 8 | UInt32(self[i + 2]) << 16 | UInt32(self[i + 3]) << 24
    }
}
