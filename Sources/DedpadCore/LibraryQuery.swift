import Foundation

public enum LibraryFilter: Hashable, Sendable {
    case all
    case recent
    case favorites
    case unfiled
    case folder(UUID)
    case category(String)
    case archived
    case trash
}

public enum NotebookSort: String, CaseIterable, Sendable, Identifiable, Codable {
    case modified, created, name, opened
    public var id: String { rawValue }
    public var name: String {
        switch self {
        case .modified: return "Date modified"
        case .created: return "Date created"
        case .name: return "Name"
        case .opened: return "Last opened"
        }
    }
}

public enum LibraryQuery {
    /// How many notebooks the "Recent" list shows.
    public static let recentLimit = 12
    /// Days a notebook stays in Recently Deleted.
    public static let trashDays = 30

    public static func apply(
        _ notebooks: [Notebook],
        filter: LibraryFilter,
        search: String = "",
        sort: NotebookSort = .modified,
        ascending: Bool = false
    ) -> [Notebook] {
        if filter == .trash {
            return notebooks.filter { $0.isDeleted && matches($0, search) }
                .sorted { ($0.deletedAt ?? .distantPast) > ($1.deletedAt ?? .distantPast) }
        }
        let notebooks = notebooks.filter { !$0.isDeleted }
        var list: [Notebook]
        switch filter {
        case .trash: list = []
        case .all: list = notebooks.filter { !$0.isArchived }
        case .favorites: list = notebooks.filter { !$0.isArchived && $0.isFavorite }
        case .unfiled: list = notebooks.filter { !$0.isArchived && $0.folderID == nil }
        case let .folder(id): list = notebooks.filter { !$0.isArchived && $0.folderID == id }
        case let .category(c): list = notebooks.filter { !$0.isArchived && $0.categories.contains { $0.caseInsensitiveCompare(c) == .orderedSame } }
        case .archived: list = notebooks.filter { $0.isArchived }
        case .recent:
            return Array(
                notebooks
                    .filter { !$0.isArchived && $0.lastOpenedAt != nil && matches($0, search) }
                    .sorted { ($0.lastOpenedAt ?? .distantPast) > ($1.lastOpenedAt ?? .distantPast) }
                    .prefix(recentLimit)
            )
        }
        list = list.filter { matches($0, search) }
        return sorted(list, by: sort, ascending: ascending)
    }

    public static func sorted(_ list: [Notebook], by sort: NotebookSort, ascending: Bool) -> [Notebook] {
        list.sorted { a, b in
            let ordered: Bool
            switch sort {
            case .name:
                let r = a.displayTitle.localizedStandardCompare(b.displayTitle)
                if r == .orderedSame { return a.id.uuidString < b.id.uuidString }
                // Names read naturally A→Z by default, so "ascending" flips the date-style default.
                return ascending ? r == .orderedDescending : r == .orderedAscending
            case .created:
                if a.createdAt == b.createdAt { return a.id.uuidString < b.id.uuidString }
                ordered = a.createdAt < b.createdAt
            case .modified:
                if a.modifiedAt == b.modifiedAt { return a.id.uuidString < b.id.uuidString }
                ordered = a.modifiedAt < b.modifiedAt
            case .opened:
                let x = a.lastOpenedAt ?? .distantPast, y = b.lastOpenedAt ?? .distantPast
                if x == y { return a.id.uuidString < b.id.uuidString }
                ordered = x < y
            }
            return ascending ? ordered : !ordered
        }
    }

    /// Case- and diacritic-insensitive match on title, description, categories and page text
    /// (typed notes, text boxes and recognised handwriting).
    public static func matches(_ nb: Notebook, _ search: String) -> Bool {
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return true }
        let opts: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        let terms = q.split(separator: " ").map(String.init)
        let haystack = ([nb.displayTitle, nb.details] + nb.categories + nb.pages.map(\.searchableText)).joined(separator: " ")
        return terms.allSatisfy { haystack.range(of: $0, options: opts) != nil }
    }

    /// True when the search matched inside page content rather than the title.
    public static func matchesOnlyInPages(_ nb: Notebook, _ search: String) -> Bool {
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return false }
        let meta = ([nb.displayTitle, nb.details] + nb.categories).joined(separator: " ")
        return meta.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) == nil && matches(nb, q)
    }

    /// Notebooks that have been in Recently Deleted longer than `trashDays`.
    public static func expiredTrash(_ notebooks: [Notebook], now: Date = Date()) -> [Notebook] {
        let limit = now.addingTimeInterval(-Double(trashDays) * 86_400)
        return notebooks.filter { ($0.deletedAt ?? .distantFuture) < limit }
    }

    /// One search hit inside a notebook's pages.
    public struct PageHit: Equatable, Sendable {
        public var pageIndex: Int
        public var snippet: String
        public var source: String
    }

    /// Finds `query` in typed notes, text boxes and recognised handwriting.
    public static func pageHits(in nb: Notebook, query: String) -> [PageHit] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        var hits: [PageHit] = []
        for (i, page) in nb.pages.enumerated() {
            let sources: [(String, String)] = [("Notes", page.typedNotes), ("Handwriting", page.recognizedText)]
                + page.elements.filter { $0.kind == .text }.map { ("Text box", $0.text) }
            for (name, text) in sources {
                if let r = text.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) {
                    hits.append(PageHit(pageIndex: i, snippet: snippet(text, around: r), source: name))
                }
            }
        }
        return hits
    }

    static func snippet(_ text: String, around r: Range<String.Index>, radius: Int = 40) -> String {
        let start = text.index(r.lowerBound, offsetBy: -radius, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(r.upperBound, offsetBy: radius, limitedBy: text.endIndex) ?? text.endIndex
        var s = String(text[start..<end]).replacingOccurrences(of: "\n", with: " ")
        if start != text.startIndex { s = "…" + s }
        if end != text.endIndex { s += "…" }
        return s
    }

    /// Every category in use, sorted, case-insensitively unique.
    public static func categories(in notebooks: [Notebook]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for nb in notebooks where !nb.isArchived && !nb.isDeleted {
            for c in nb.categories {
                let t = c.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !t.isEmpty, seen.insert(t.lowercased()).inserted else { continue }
                out.append(t)
            }
        }
        return out.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// Splits a comma-separated field into clean, unique categories.
    public static func parseCategories(_ text: String) -> [String] {
        var seen = Set<String>()
        return text.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }
}
