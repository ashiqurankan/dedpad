import XCTest
@testable import DedpadCore

final class ModelTests: XCTestCase {

    func testColorHexRoundTrip() {
        XCTAssertEqual(RGBA(hex: "#687B62")?.hex, "#687B62")
        XCTAssertEqual(RGBA(hex: "fff")?.hex, "#FFFFFF")
        XCTAssertEqual(RGBA(hex: "#00000080")?.a ?? 0, 128.0 / 255, accuracy: 0.001)
        XCTAssertNil(RGBA(hex: "nope"))
        XCTAssertTrue(RGBA(0x171916).isDark)
        XCTAssertFalse(RGBA(0xF7F7F5).isDark)
    }

    func testNotebookJSONRoundTrip() throws {
        var nb = Notebook(title: "Physics", details: "Term 1", categories: ["School"])
        nb.pages.append(Page(size: PageSizePreset.a4.dimensions, paper: PaperSpec(style: .cornell), background: .pdf(file: "lecture.pdf", pageIndex: 3), typedNotes: "Newton"))
        nb.pages.append(Page(size: PageDimensions(width: 300, height: 200), background: .image(file: "photo.jpg")))
        let data = try LibraryStore.makeEncoder().encode(nb)
        let back = try LibraryStore.makeDecoder().decode(Notebook.self, from: data)
        XCTAssertEqual(back.id, nb.id)
        XCTAssertEqual(back.pages.count, 3)
        XCTAssertEqual(back.pages[1].background, .pdf(file: "lecture.pdf", pageIndex: 3))
        XCTAssertEqual(back.pages[1].paper?.style, .cornell)
        XCTAssertEqual(back.pages[2].background, .image(file: "photo.jpg"))
        XCTAssertEqual(back.categories, ["School"])
        XCTAssertEqual(back.cover, nb.cover)
    }

    func testDecodesSparseAndUnknownValues() throws {
        let json = """
        {"title":"Old","settings":{"paper":{"style":"futuristic"}},"cover":{"pattern":"lasers"}}
        """
        let nb = try LibraryStore.makeDecoder().decode(Notebook.self, from: Data(json.utf8))
        XCTAssertEqual(nb.title, "Old")
        XCTAssertEqual(nb.settings.paper.style, .ruled)
        XCTAssertEqual(nb.cover.pattern, CoverPattern.none)
        XCTAssertEqual(nb.pages.count, 1, "a notebook always has a page")
    }

    func testRejectsNewerFormat() {
        let json = #"{"formatVersion": 99, "title": "Future"}"#
        XCTAssertThrowsError(try LibraryStore.makeDecoder().decode(Notebook.self, from: Data(json.utf8))) { error in
            XCTAssertEqual(error as? DedpadError, .unsupportedVersion(99))
        }
    }

    func testOrientationAndPageSize() {
        let s = NotebookSettings(pageSize: .a4, orientation: .landscape)
        XCTAssertEqual(s.pageDimensions.width, 842)
        XCTAssertEqual(s.pageDimensions.height, 595)
    }
}

final class PageOperationTests: XCTestCase {

    func testInsertDuplicateDeleteMove() {
        var nb = Notebook(title: "T")
        let first = nb.pages[0].id
        nb.pages[0].paper = PaperSpec(style: .dotted)
        let i = nb.insertPage(after: 0)
        XCTAssertEqual(i, 1)
        XCTAssertEqual(nb.pages[1].paper?.style, .dotted, "new pages inherit the previous page's paper")
        let dup = nb.duplicatePage(at: 0)
        XCTAssertEqual(dup?.0.id, first)
        XCTAssertNotEqual(dup?.1.id, first)
        XCTAssertEqual(nb.pages.count, 3)
        nb.movePage(from: 0, to: 2)
        XCTAssertEqual(nb.pages[2].id, first)
        nb.deletePage(at: 0); nb.deletePage(at: 0); nb.deletePage(at: 0)
        XCTAssertEqual(nb.pages.count, 1, "never left without a page")
    }

    func testContinuousGrowth() {
        var nb = Notebook(title: "Scroll", settings: NotebookSettings(mode: .continuous))
        let h0 = nb.pages[0].size.height
        XCTAssertFalse(nb.growPageIfNeeded(at: 0, contentBottom: 100))
        XCTAssertTrue(nb.growPageIfNeeded(at: 0, contentBottom: h0 - 10))
        XCTAssertGreaterThan(nb.pages[0].size.height, h0)
        var fixed = Notebook(title: "Fixed")
        XCTAssertFalse(fixed.growPageIfNeeded(at: 0, contentBottom: 10_000))
    }

    func testOrientationSkipsPDFPages() {
        var nb = Notebook(title: "x")
        nb.pages.append(Page(size: PageDimensions(width: 500, height: 700), background: .pdf(file: "a.pdf", pageIndex: 0)))
        nb.setOrientation(.landscape, pages: Set(nb.pages.map(\.id)))
        XCTAssertTrue(nb.pages[0].size.isLandscape)
        XCTAssertFalse(nb.pages[1].size.isLandscape)
    }
}

final class TemplateTests: XCTestCase {

    func testEveryTemplateRendersInBothOrientations() {
        for style in PaperStyle.allCases {
            for size in [PageSizePreset.a4.dimensions, PageSizePreset.a4.dimensions.landscape, PageSizePreset.a5.dimensions] {
                let prims = PaperLayout.primitives(for: PaperSpec(style: style), size: size)
                if style != .blank { XCTAssertFalse(prims.isEmpty, "\(style) produced nothing") }
                for p in prims {
                    switch p {
                    case let .line(x1, y1, x2, y2, _, _):
                        for v in [x1, y1, x2, y2] { XCTAssertTrue(v.isFinite) }
                        XCTAssertTrue(y1 >= -1 && y2 <= size.height + 1, "\(style) line off page")
                    case let .rect(x, y, w, h, _, _, _):
                        XCTAssertTrue(w >= 0 && h >= 0, "\(style) negative rect")
                        XCTAssertTrue(x >= -1 && y >= -1 && x + w <= size.width + 1 && y + h <= size.height + 1, "\(style) rect off page")
                    default: break
                    }
                }
            }
        }
    }

    func testCategoriesCoverAllStyles() {
        let grouped = PaperCategory.allCases.flatMap { PaperStyle.styles(in: $0) }
        XCTAssertEqual(Set(grouped), Set(PaperStyle.allCases))
    }

    func testCoverPresetsAreUnique() {
        XCTAssertEqual(Set(CoverPresets.all.map(\.id)).count, CoverPresets.all.count)
        for c in CoverCollection.allCases { XCTAssertFalse(CoverPresets.presets(in: c).isEmpty) }
    }
}

final class QueryTests: XCTestCase {

    func make(_ title: String, _ modified: TimeInterval, folder: UUID? = nil, archived: Bool = false, opened: TimeInterval? = nil, cats: [String] = []) -> Notebook {
        var nb = Notebook(title: title, createdAt: Date(timeIntervalSince1970: modified), folderID: folder, categories: cats)
        nb.modifiedAt = Date(timeIntervalSince1970: modified)
        nb.isArchived = archived
        nb.lastOpenedAt = opened.map { Date(timeIntervalSince1970: $0) }
        return nb
    }

    func testFilterSortSearch() {
        let folder = UUID()
        let list = [
            make("Biology", 30, folder: folder, cats: ["School"]),
            make("art", 10, opened: 5),
            make("Café plans", 20, opened: 50),
            make("Old", 40, archived: true),
        ]
        XCTAssertEqual(LibraryQuery.apply(list, filter: .all).map(\.title), ["Biology", "Café plans", "art"])
        XCTAssertEqual(LibraryQuery.apply(list, filter: .all, sort: .name).map(\.title), ["art", "Biology", "Café plans"])
        XCTAssertEqual(LibraryQuery.apply(list, filter: .folder(folder)).map(\.title), ["Biology"])
        XCTAssertEqual(LibraryQuery.apply(list, filter: .archived).map(\.title), ["Old"])
        XCTAssertEqual(LibraryQuery.apply(list, filter: .recent).map(\.title), ["Café plans", "art"])
        XCTAssertEqual(LibraryQuery.apply(list, filter: .all, search: "cafe").map(\.title), ["Café plans"])
        XCTAssertEqual(LibraryQuery.apply(list, filter: .category("school")).map(\.title), ["Biology"])
        XCTAssertEqual(LibraryQuery.categories(in: list), ["School"])
        XCTAssertEqual(LibraryQuery.parseCategories(" a, B ,a,, b"), ["a", "B"])
    }
}

final class StorageTests: XCTestCase {
    var dir: URL!
    var store: LibraryStore!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("dedpad-tests-\(UUID().uuidString)")
        store = LibraryStore(root: dir)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    func seeded() throws -> Notebook {
        var nb = Notebook(title: "Seed", categories: ["x"])
        nb.insertPage(after: 0)
        let asset = try store.addAsset(Data("%PDF-fake".utf8), notebook: nb.id, preferredName: "doc", ext: "pdf")
        nb.pages.append(Page(size: PageSizePreset.letter.dimensions, background: .pdf(file: asset, pageIndex: 0)))
        nb.cover.imageFile = try store.addAsset(Data([1, 2, 3]), notebook: nb.id, preferredName: "cover", ext: "jpg")
        try store.save(nb)
        try store.writeDrawing(Data("ink-0".utf8), notebook: nb.id, page: nb.pages[0])
        try store.writeDrawing(Data("ink-2".utf8), notebook: nb.id, page: nb.pages[2])
        return nb
    }

    func testSaveLoadDuplicateDelete() throws {
        let nb = try seeded()
        XCTAssertEqual(store.loadNotebooks().notebooks.map(\.id), [nb.id])
        let copy = try store.duplicate(nb)
        XCTAssertNotEqual(copy.id, nb.id)
        XCTAssertEqual(store.readDrawing(notebook: copy.id, page: copy.pages[2]), Data("ink-2".utf8))
        XCTAssertEqual(store.loadNotebooks().notebooks.count, 2)
        try store.delete(id: nb.id)
        XCTAssertEqual(store.loadNotebooks().notebooks.map(\.id), [copy.id])
    }

    func testCorruptNotebookIsSkipped() throws {
        _ = try seeded()
        let bad = store.directory(for: UUID())
        try FileManager.default.createDirectory(at: bad, withIntermediateDirectories: true)
        try Data("{oops".utf8).write(to: bad.appendingPathComponent("notebook.json"))
        let r = store.loadNotebooks()
        XCTAssertEqual(r.notebooks.count, 1)
        XCTAssertEqual(r.failures.count, 1)
    }

    func testAssetNamesDoNotCollide() throws {
        let id = UUID()
        let a = try store.addAsset(Data([1]), notebook: id, preferredName: "scan", ext: "pdf")
        let b = try store.addAsset(Data([2]), notebook: id, preferredName: "scan", ext: "pdf")
        XCTAssertEqual(a, "scan.pdf")
        XCTAssertEqual(b, "scan-2.pdf")
        XCTAssertEqual(LibraryStore.safeFileName("a/b:c?.pdf"), "a-b-c--pdf")
        XCTAssertEqual(LibraryStore.safeFileName("///"), "dedpad")
    }

    func testPruneAssets() throws {
        var nb = try seeded()
        nb.cover.imageFile = nil
        store.pruneAssets(of: nb)
        let left = try FileManager.default.contentsOfDirectory(atPath: store.assetsDirectory(for: nb.id).path)
        XCTAssertEqual(left, ["doc.pdf"])
    }

    func testZipRoundTrip() throws {
        let entries = [Zip.Entry(path: "a.txt", data: Data("hello".utf8)), Zip.Entry(path: "dir/ü.bin", data: Data((0..<255).map { UInt8($0) }))]
        let zip = Zip.archive(entries)
        XCTAssertEqual(try Zip.entries(in: zip), entries)
        XCTAssertEqual(Zip.crc32(Data("123456789".utf8)), 0xCBF4_3926)
        XCTAssertThrowsError(try Zip.entries(in: Data("not a zip at all, definitely not".utf8)))
    }

    func testArchiveAndBackupRoundTrip() throws {
        let nb = try seeded()
        let zip = try Portability.archive(nb, store: store)
        let restored = try Portability.importArchive(zip, into: store)
        XCTAssertNotEqual(restored.id, nb.id)
        XCTAssertEqual(restored.pages.map(\.id), nb.pages.map(\.id))
        XCTAssertEqual(store.readDrawing(notebook: restored.id, page: restored.pages[0]), Data("ink-0".utf8))
        XCTAssertEqual(try Data(contentsOf: store.assetURL(notebook: restored.id, file: "doc.pdf")), Data("%PDF-fake".utf8))

        let json = try Portability.jsonBackup(nb, store: store)
        let fromJSON = try Portability.importJSONBackup(json, into: store)
        XCTAssertEqual(store.readDrawing(notebook: fromJSON.id, page: fromJSON.pages[2]), Data("ink-2".utf8))
        XCTAssertEqual(fromJSON.cover.imageFile, "cover.jpg")
        XCTAssertThrowsError(try Portability.importJSONBackup(Data("{}".utf8), into: store))
    }

    func testLibraryBackupRestore() throws {
        let nb = try seeded()
        try store.saveIndex(LibraryIndex(folders: [Folder(name: "Uni")]))
        let backup = try Portability.libraryBackup([nb], index: store.loadIndex(), store: store)

        let other = LibraryStore(root: dir.appendingPathComponent("other"))
        let report = try Portability.restoreLibrary(backup, into: other, existing: [])
        XCTAssertEqual(report.added, 1)
        XCTAssertEqual(report.foldersAdded, 1)
        let loaded = other.loadNotebooks().notebooks
        XCTAssertEqual(loaded.map(\.id), [nb.id])
        XCTAssertEqual(other.readDrawing(notebook: nb.id, page: nb.pages[0]), Data("ink-0".utf8))

        let again = try Portability.restoreLibrary(backup, into: other, existing: loaded)
        XCTAssertEqual(again.skipped, 1)
        XCTAssertEqual(again.foldersAdded, 0)
    }

    func testTextExports() {
        var nb = Notebook(title: "Notes", details: "About things")
        nb.pages[0].typedNotes = "Hello"
        XCTAssertTrue(Portability.markdown(nb).contains("## Page 1"))
        XCTAssertTrue(Portability.markdown(nb).contains("Hello"))
        XCTAssertTrue(Portability.plainText(nb).hasPrefix("Notes\n====="))
    }

    func testSVG() {
        let stroke = VectorStroke(points: [.init(x: 0, y: 0, width: 2), .init(x: 10, y: 10, width: 2), .init(x: 20, y: 5, width: 8), .init(x: 30, y: 5, width: 8)], color: RGBA(0x252722))
        let svg = SVGWriter.document(size: PageSizePreset.a5.dimensions, paper: PaperSpec(style: .cornell), strokes: [stroke], title: "A & B")
        XCTAssertTrue(svg.contains("<svg"))
        XCTAssertTrue(svg.contains("A &amp; B"))
        XCTAssertTrue(svg.contains("<path"))
        XCTAssertEqual(SVGWriter.n(1.50), "1.5")
        XCTAssertEqual(SVGWriter.n(2.0), "2")
    }
}

final class ProductionCoreTests: XCTestCase {
    var dir: URL!
    var store: LibraryStore!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("dedpad-prod-\(UUID().uuidString)")
        store = LibraryStore(root: dir)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    func testTrashFilterAndExpiry() {
        var a = Notebook(title: "Kept")
        var b = Notebook(title: "Binned")
        b.deletedAt = Date(timeIntervalSinceNow: -40 * 86_400)
        a.lastOpenedAt = Date()
        var c = Notebook(title: "Fresh bin")
        c.deletedAt = Date()
        let all = [a, b, c]
        XCTAssertEqual(LibraryQuery.apply(all, filter: .all).map(\.title), ["Kept"])
        XCTAssertEqual(LibraryQuery.apply(all, filter: .recent).map(\.title), ["Kept"])
        XCTAssertEqual(LibraryQuery.apply(all, filter: .trash).map(\.title), ["Fresh bin", "Binned"])
        XCTAssertEqual(LibraryQuery.expiredTrash(all).map(\.title), ["Binned"])
    }

    func testSearchFindsPageContent() {
        var nb = Notebook(title: "Biology")
        nb.pages[0].recognizedText = "mitochondria is the powerhouse"
        nb.pages[0].elements = [PageElement(kind: .text, frame: PageRect(x: 0, y: 0, w: 10, h: 10), text: "Krebs cycle")]
        XCTAssertTrue(LibraryQuery.matches(nb, "powerhouse"))
        XCTAssertTrue(LibraryQuery.matches(nb, "krebs"))
        XCTAssertTrue(LibraryQuery.matchesOnlyInPages(nb, "krebs"))
        XCTAssertFalse(LibraryQuery.matchesOnlyInPages(nb, "bio"))
        let hits = LibraryQuery.pageHits(in: nb, query: "cycle")
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits[0].source, "Text box")
    }

    func testAssetsIncludeElements() {
        var nb = Notebook(title: "x")
        nb.pages[0].elements = [PageElement(kind: .image, frame: PageRect(x: 0, y: 0, w: 1, h: 1), imageFile: "sticker.png")]
        nb.cover.imageFile = "cover.jpg"
        XCTAssertEqual(Set(nb.referencedAssets), ["sticker.png", "cover.jpg"])
    }

    func testRecoversFromDamagedNotebookFile() throws {
        var nb = Notebook(title: "Precious")
        try store.save(nb)
        nb.title = "Precious v2"
        try store.save(nb)      // v1 becomes the .bak
        try Data("{garbage".utf8).write(to: store.notebookFile(for: nb.id))
        let r = store.loadNotebooksReport()
        XCTAssertEqual(r.recovered, [nb.id])
        XCTAssertEqual(r.notebooks.first?.title, "Precious")
        XCTAssertEqual(try store.loadNotebook(id: nb.id).title, "Precious", "good copy is written back")
    }

    func testDrawingBackup() throws {
        let nb = Notebook(title: "d")
        try store.writeDrawing(Data("one".utf8), notebook: nb.id, page: nb.pages[0])
        try store.writeDrawing(Data("two".utf8), notebook: nb.id, page: nb.pages[0])
        XCTAssertEqual(store.readDrawing(notebook: nb.id, page: nb.pages[0]), Data("two".utf8))
        XCTAssertEqual(store.readDrawingBackup(notebook: nb.id, page: nb.pages[0]), Data("one".utf8))
    }

    func testSnapshotsAndRestore() throws {
        var nb = Notebook(title: "History")
        try store.save(nb)
        try store.writeDrawing(Data("v1".utf8), notebook: nb.id, page: nb.pages[0])
        try store.makeSnapshot(of: nb, date: Date(timeIntervalSince1970: 1_000_000))
        nb.insertPage(after: 0)
        try store.save(nb)
        try store.writeDrawing(Data("v2".utf8), notebook: nb.id, page: nb.pages[0])
        try store.makeSnapshot(of: nb, date: Date(timeIntervalSince1970: 2_000_000))
        let snaps = store.snapshots(for: nb.id)
        XCTAssertEqual(snaps.map(\.pageCount), [2, 1])
        let restored = try store.restoreSnapshot(notebook: nb.id, name: snaps[1].name)
        XCTAssertNotEqual(restored.id, nb.id)
        XCTAssertEqual(restored.pages.count, 1)
        XCTAssertEqual(store.readDrawing(notebook: restored.id, page: restored.pages[0]), Data("v1".utf8))
        // Pruning keeps only the newest versions.
        for i in 0..<(LibraryStore.snapshotLimit + 3) {
            try store.makeSnapshot(of: nb, date: Date(timeIntervalSince1970: 3_000_000 + Double(i) * 10))
        }
        XCTAssertEqual(store.snapshots(for: nb.id).count, LibraryStore.snapshotLimit)
        // Duplicates and archives don't carry history.
        let copy = try store.duplicate(nb)
        XCTAssertTrue(store.snapshots(for: copy.id).isEmpty)
    }

    func testInkRoundTripIsCompact() throws {
        let stroke = InkStroke(tool: "pen", color: RGBA(0x252722), transform: [1, 0, 0, 1, 5, 5],
                               points: [InkPoint(x: 1, y: 2, t: 0, width: 3, height: 3, force: 0.5),
                                        InkPoint(x: 10, y: 12, t: 0.1, width: 4, height: 4)])
        let page = InkPage(width: 595, height: 842, strokes: [stroke])
        let data = try page.encoded()
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("[1,2,0,3,3,1,0.5"))
        XCTAssertEqual(try InkPage.decode(data).encoded(), data, "stable round trip")
        XCTAssertEqual(try InkPage.decode(data).strokes[0].points[0].force, 0.5)
        XCTAssertEqual(page.bounds?.x ?? 0, 4.5, accuracy: 0.001)
        XCTAssertThrowsError(try InkPage.decode(Data(#"{"format":"x","version":1,"width":1,"height":1,"strokes":[]}"#.utf8)))
    }

    func testArchiveCarriesInk() throws {
        let nb = Notebook(title: "ink")
        try store.save(nb)
        try store.writeInk(Data("{}".utf8), notebook: nb.id, page: nb.pages[0])
        let restored = try Portability.importArchive(try Portability.archive(nb, store: store), into: store)
        XCTAssertEqual(store.readInk(notebook: restored.id, page: restored.pages[0]), Data("{}".utf8))
        let fromJSON = try Portability.importJSONBackup(try Portability.jsonBackup(nb, store: store), into: store)
        XCTAssertEqual(store.readInk(notebook: fromJSON.id, page: fromJSON.pages[0]), Data("{}".utf8))
    }

    func testHashesIgnoreDerivedData() {
        var p = Page(size: PageSizePreset.a4.dimensions)
        let h1 = ContentHash.page(p, drawing: Data("ink".utf8))
        p.recognizedText = "words"
        p.modifiedAt = Date(timeIntervalSinceNow: 100)
        XCTAssertEqual(ContentHash.page(p, drawing: Data("ink".utf8)), h1)
        XCTAssertNotEqual(ContentHash.page(p, drawing: Data("more ink".utf8)), h1)
        var nb = Notebook(title: "a")
        let m1 = ContentHash.notebookMeta(nb)
        nb.pages.append(nb.makePage())
        XCTAssertEqual(ContentHash.notebookMeta(nb), m1)
        nb.title = "b"
        XCTAssertNotEqual(ContentHash.notebookMeta(nb), m1)
    }

    // MARK: Sync merge

    private func hashes(_ nb: Notebook, _ ink: [UUID: String]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: nb.pages.map { ($0.id.uuidString, ContentHash.page($0, drawing: Data((ink[$0.id] ?? "").utf8))) })
    }

    func testMergeTakesOneSidedChangesAndKeepsConflicts() {
        var base = Notebook(title: "Shared")
        base.pages = [Page(size: PageSizePreset.a4.dimensions), Page(size: PageSizePreset.a4.dimensions), Page(size: PageSizePreset.a4.dimensions)]
        let p = base.pages.map(\.id)
        let baseInk: [UUID: String] = [p[0]: "a", p[1]: "b", p[2]: "c"]
        let syncBase = SyncBase(revision: 1, pageHashes: hashes(base, baseInk), metaHash: ContentHash.notebookMeta(base))

        // Local: edits page 0, deletes page 2, adds page L.
        var local = base
        local.pages.removeLast()
        let newLocal = Page(size: PageSizePreset.a4.dimensions)
        local.pages.append(newLocal)
        var localInk = baseInk
        localInk[p[0]] = "a-local"
        localInk[p[2]] = nil

        // Remote: edits page 0 too, edits page 1, renames notebook, adds page R at the front.
        var remote = base
        remote.title = "Renamed elsewhere"
        let newRemote = Page(size: PageSizePreset.a4.dimensions)
        remote.pages.insert(newRemote, at: 0)
        var remoteInk = baseInk
        remoteInk[p[0]] = "a-remote"
        remoteInk[p[1]] = "b-remote"

        let r = SyncMerge.merge(base: syncBase, local: local, localHashes: hashes(local, localInk),
                                remote: remote, remoteHashes: hashes(remote, remoteInk))
        let ids = r.notebook.pages.map(\.id)
        XCTAssertEqual(r.notebook.title, "Renamed elsewhere", "untouched-locally metadata follows remote")
        XCTAssertEqual(r.conflicts, 1)
        XCTAssertEqual(ids.first, newRemote.id, "remote insertion position is respected")
        XCTAssertEqual(ids[1], p[0], "local version of the conflicting page stays")
        XCTAssertTrue(r.notebook.pages[2].typedNotes.contains("Conflict copy"))
        XCTAssertEqual(r.fromRemote[ids[2]], p[0], "conflict copy pulls remote content")
        XCTAssertEqual(r.fromRemote[p[1]], p[1], "one-sided remote edit is pulled")
        XCTAssertTrue(ids.contains(newLocal.id))
        XCTAssertFalse(ids.contains(p[2]), "local deletion of an untouched page sticks")
        XCTAssertEqual(r.notebook.id, local.id)
    }

    func testMergeKeepsLocallyEditedPageDeletedRemotely() {
        let base = Notebook(title: "x")
        let id = base.pages[0].id
        let syncBase = SyncBase(revision: 1, pageHashes: hashes(base, [id: "a"]), metaHash: ContentHash.notebookMeta(base))
        var remote = base
        remote.pages = [Page(size: PageSizePreset.a4.dimensions)]
        let r = SyncMerge.merge(base: syncBase, local: base, localHashes: hashes(base, [id: "edited"]),
                                remote: remote, remoteHashes: hashes(remote, [:]))
        XCTAssertTrue(r.notebook.pages.map(\.id).contains(id))
        XCTAssertEqual(r.notebook.pages.count, 2)
        XCTAssertEqual(r.conflicts, 0)
    }
}

final class ShapeRecognizerTests: XCTestCase {
    typealias P = ShapeRecognizer.Point

    private func wobble(_ pts: [P], amount: Double = 1.5) -> [P] {
        pts.enumerated().map { i, p in P(p.x + sin(Double(i) * 1.7) * amount, p.y + cos(Double(i) * 1.3) * amount) }
    }

    private func densify(_ corners: [P], step: Double = 4) -> [P] {
        var out: [P] = []
        for (a, b) in zip(corners, corners.dropFirst()) {
            let n = max(1, Int(hypot(b.x - a.x, b.y - a.y) / step))
            for i in 0..<n { let t = Double(i) / Double(n); out.append(P(a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t)) }
        }
        out.append(corners.last!)
        return out
    }

    func testLineSnapsToHorizontal() {
        let pts = wobble(densify([P(10, 100), P(210, 104)]))
        guard case let .line(a, b)? = ShapeRecognizer.recognize(pts) else { return XCTFail("expected line") }
        XCTAssertEqual(a.y, b.y, accuracy: 0.001, "near-horizontal line is levelled")
    }

    func testRectangle() {
        let pts = wobble(densify([P(0, 0), P(200, 0), P(200, 120), P(0, 120), P(2, 3)]))
        let s = ShapeRecognizer.recognize(pts)
        guard case let .polygon(c)? = s else { return XCTFail("expected rectangle, got \(String(describing: s))") }
        XCTAssertEqual(c.count, 4)
    }

    func testTriangle() {
        let pts = wobble(densify([P(100, 0), P(200, 170), P(0, 170), P(98, 4)]))
        let s = ShapeRecognizer.recognize(pts)
        guard case let .polygon(c)? = s else { return XCTFail("expected triangle, got \(String(describing: s))") }
        XCTAssertEqual(c.count, 3)
    }

    func testCircle() {
        let pts = (0...80).map { i -> P in
            let t = Double(i) / 80 * 2 * .pi
            return P(150 + 60 * cos(t) + sin(Double(i)) * 1.2, 150 + 60 * sin(t))
        }
        let s = ShapeRecognizer.recognize(pts)
        guard case let .ellipse(c, rx, ry, _)? = s else { return XCTFail("expected circle, got \(String(describing: s))") }
        XCTAssertEqual(c.x, 150, accuracy: 3)
        XCTAssertEqual(rx, ry, accuracy: 0.001)
        XCTAssertEqual(s?.name, "circle")
    }

    func testOvershootCircleAndEllipse() {
        let pts = (0...100).map { i -> P in
            let t = Double(i) / 85 * 2 * .pi       // goes ~18% past the start
            return P(300 + 120 * cos(t) + sin(Double(i) * 0.7) * 2, 200 + 60 * sin(t))
        }
        let s = ShapeRecognizer.recognize(pts)
        guard case let .ellipse(_, rx, ry, rot)? = s else { return XCTFail("expected ellipse, got \(String(describing: s))") }
        XCTAssertEqual(rx, 120, accuracy: 10); XCTAssertEqual(ry, 60, accuracy: 8); XCTAssertEqual(rot, 0)
    }

    func testOpenTriangleStillTriangle() {
        // Ends 30 pt short of the start.
        let pts = wobble(densify([P(100, 0), P(200, 170), P(0, 170), P(85, 26)]))
        let s = ShapeRecognizer.recognize(pts)
        guard case let .polygon(c)? = s else { return XCTFail("expected triangle, got \(String(describing: s))") }
        XCTAssertEqual(c.count, 3)
    }

    func testRotatedSquare() {
        let pts = wobble(densify([P(100, 0), P(200, 100), P(100, 200), P(0, 100), P(97, 3)]))
        guard case let .polygon(c)? = ShapeRecognizer.recognize(pts) else { return XCTFail("expected square") }
        XCTAssertEqual(c.count, 4)
    }

    func testLShapePolyline() {
        let pts = wobble(densify([P(0, 0), P(0, 150), P(120, 152)]))
        guard case let .polyline(c)? = ShapeRecognizer.recognize(pts) else { return XCTFail("expected polyline") }
        XCTAssertEqual(c.count, 3)
        XCTAssertEqual(c[1].y, c[2].y, accuracy: 0.001)
    }

    func testScribbleNotSnapped() {
        let pts = (0...200).map { i -> P in P(Double(i) * 2, sin(Double(i) * 0.9) * 25 + Double(i % 7) * 4) }
        XCTAssertNil(ShapeRecognizer.recognize(pts))
    }

    func testTinyStrokeIgnored() {
        XCTAssertNil(ShapeRecognizer.recognize([P(0, 0), P(2, 2)]))
    }
}
