import Foundation

/// What the sync engine remembers about a notebook after the last successful sync.
public struct SyncBase: Codable, Equatable, Sendable {
    /// Remote revision the local copy was last in step with.
    public var revision: Int
    /// Page fingerprints at that revision.
    public var pageHashes: [String: String]
    public var metaHash: String
    /// Assets already uploaded.
    public var uploadedAssets: Set<String>
    public var syncedAt: Date

    public init(revision: Int = 0, pageHashes: [String: String] = [:], metaHash: String = "",
                uploadedAssets: Set<String> = [], syncedAt: Date = Date()) {
        self.revision = revision
        self.pageHashes = pageHashes
        self.metaHash = metaHash
        self.uploadedAssets = uploadedAssets
        self.syncedAt = syncedAt
    }
}

/// Local sync bookkeeping, persisted as `sync-state.json` (this is the offline queue).
public struct SyncState: Codable, Equatable, Sendable {
    public var deviceID: String
    public var accountID: String?
    public var bases: [String: SyncBase]
    /// Notebooks changed locally since their last sync.
    public var dirty: Set<String>
    public var lastSync: Date?

    public init(deviceID: String = UUID().uuidString) {
        self.deviceID = deviceID
        self.accountID = nil
        self.bases = [:]
        self.dirty = []
        self.lastSync = nil
    }
}

/// Three-way merge of a notebook, page by page.
///
/// * A page changed on only one side takes that side's version.
/// * A page changed on both sides keeps the local page and adds the remote one right after it,
///   marked as a conflict copy, so no handwriting is ever lost.
/// * Deletions win only over pages the other side did not touch.
/// * Notebook details (title, cover, settings) follow whichever side changed them, local first.
public enum SyncMerge {

    public struct Result: Equatable {
        public var notebook: Notebook
        /// Pages whose content must be taken from the remote copy (including conflict copies,
        /// keyed by their new local id → remote page id).
        public var fromRemote: [UUID: UUID]
        public var conflicts: Int
    }

    public static func merge(
        base: SyncBase,
        local: Notebook, localHashes: [String: String],
        remote: Notebook, remoteHashes: [String: String],
        now: Date = Date()
    ) -> Result {
        let localMetaChanged = ContentHash.notebookMeta(local) != base.metaHash
        var merged = localMetaChanged ? local : remote
        merged.id = local.id
        merged.lastOpenedAt = local.lastOpenedAt
        if !localMetaChanged {
            // Keep purely local state.
            merged.folderID = remote.folderID
        }

        let localByID = Dictionary(local.pages.map { ($0.id.uuidString, $0) }, uniquingKeysWith: { a, _ in a })
        let remoteByID = Dictionary(remote.pages.map { ($0.id.uuidString, $0) }, uniquingKeysWith: { a, _ in a })

        var pages: [Page] = []
        var fromRemote: [UUID: UUID] = [:]
        var conflicts = 0

        func changed(_ id: String, _ hashes: [String: String]) -> Bool { hashes[id] != base.pageHashes[id] }

        // Walk the local order first.
        for lp in local.pages {
            let id = lp.id.uuidString
            if let rp = remoteByID[id] {
                let lc = changed(id, localHashes), rc = changed(id, remoteHashes)
                if rc && !lc {
                    pages.append(rp)
                    fromRemote[rp.id] = rp.id
                } else if rc && lc && localHashes[id] != remoteHashes[id] {
                    pages.append(lp)
                    var copy = rp
                    copy.id = UUID()
                    let note = "Conflict copy from another device"
                    copy.typedNotes = copy.typedNotes.isEmpty ? note : "\(note)\n\n\(copy.typedNotes)"
                    pages.append(copy)
                    fromRemote[copy.id] = rp.id
                    conflicts += 1
                } else {
                    pages.append(lp)
                }
            } else if base.pageHashes[id] != nil {
                // Deleted remotely: keep only if edited locally since.
                if changed(id, localHashes) { pages.append(lp) }
            } else {
                pages.append(lp)   // new local page
            }
        }

        // Then remote pages the local copy doesn't have.
        for (ri, rp) in remote.pages.enumerated() {
            let id = rp.id.uuidString
            guard localByID[id] == nil else { continue }
            if base.pageHashes[id] != nil && !changed(id, remoteHashes) { continue }   // deleted locally
            // Insert after its remote predecessor when we have it.
            var at = pages.count
            if ri > 0 {
                let prev = remote.pages[ri - 1].id
                if let i = pages.firstIndex(where: { $0.id == prev }) { at = i + 1 }
            } else {
                at = 0
            }
            pages.insert(rp, at: at)
            fromRemote[rp.id] = rp.id
        }

        if pages.isEmpty { pages = [local.makePage()] }
        merged.pages = pages
        merged.modifiedAt = max(local.modifiedAt, remote.modifiedAt, now)
        merged.deletedAt = local.deletedAt ?? remote.deletedAt
        return Result(notebook: merged, fromRemote: fromRemote, conflicts: conflicts)
    }
}
