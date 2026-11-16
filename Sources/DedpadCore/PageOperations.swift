import Foundation

/// Page management that does not touch disk; callers persist drawings separately.
public extension Notebook {

    /// Inserts a new page after `index` (or at the end) and returns its index.
    @discardableResult
    mutating func insertPage(after index: Int?, page: Page? = nil, now: Date = Date()) -> Int {
        var p = page ?? makePage()
        // Keep the paper of the page we insert after, so a planner stays a planner.
        if page == nil, let index, pages.indices.contains(index) {
            p.paper = pages[index].paper
            if case .paper = pages[index].background { p.size = pages[index].size }
            if settings.mode == .continuous { p.size = settings.pageDimensions }
        }
        let at = index.map { min(max($0 + 1, 0), pages.count) } ?? pages.count
        pages.insert(p, at: at)
        touch(now)
        return at
    }

    /// Duplicates the page metadata; returns `(old, new)` so the caller can copy the drawing.
    @discardableResult
    mutating func duplicatePage(at index: Int, now: Date = Date()) -> (Page, Page)? {
        guard pages.indices.contains(index) else { return nil }
        var copy = pages[index]
        copy.id = UUID()
        copy.createdAt = now
        copy.modifiedAt = now
        pages.insert(copy, at: index + 1)
        touch(now)
        return (pages[index], copy)
    }

    /// Removes a page. A notebook always keeps at least one page.
    @discardableResult
    mutating func deletePage(at index: Int, now: Date = Date()) -> Page? {
        guard pages.indices.contains(index) else { return nil }
        let removed = pages.remove(at: index)
        if pages.isEmpty { pages.append(makePage()) }
        touch(now)
        return removed
    }

    mutating func movePage(from: Int, to: Int, now: Date = Date()) {
        guard pages.indices.contains(from), to >= 0, to < pages.count, from != to else { return }
        let p = pages.remove(at: from)
        pages.insert(p, at: to)
        touch(now)
    }

    /// Sets the paper for some pages (nil → back to the notebook default).
    mutating func setPaper(_ paper: PaperSpec?, pages ids: Set<UUID>, now: Date = Date()) {
        for i in pages.indices where ids.contains(pages[i].id) {
            pages[i].paper = paper
            pages[i].modifiedAt = now
        }
        touch(now)
    }

    /// Rotates paper pages to the given orientation (PDF and image pages keep their shape).
    mutating func setOrientation(_ o: PageOrientation, pages ids: Set<UUID>, now: Date = Date()) {
        for i in pages.indices where ids.contains(pages[i].id) {
            guard case .paper = pages[i].background else { continue }
            pages[i].size = o == .portrait ? pages[i].size.portrait : pages[i].size.landscape
            pages[i].modifiedAt = now
        }
        touch(now)
    }

    /// Continuous mode: make sure a page is at least `minHeight` tall, growing in half-page steps.
    @discardableResult
    mutating func growPageIfNeeded(at index: Int, contentBottom: Double, now: Date = Date()) -> Bool {
        guard settings.mode == .continuous, pages.indices.contains(index) else { return false }
        let base = settings.pageDimensions.height
        let threshold = pages[index].size.height - base * 0.25
        guard contentBottom > threshold else { return false }
        var h = pages[index].size.height
        while contentBottom > h - base * 0.25 { h += base / 2 }
        pages[index].size.height = h
        touch(now)
        return true
    }

    /// Recently opened marker.
    mutating func markOpened(_ date: Date = Date()) { lastOpenedAt = date }
}
