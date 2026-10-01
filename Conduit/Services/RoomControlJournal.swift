//
//  RoomControlJournal.swift
//  Conduit
//
//  Durable restart boundary for I4 control intents.
//
//  Hub V1 makes idempotency correctness a client obligation: one user
//  gesture gets one idempotencyKey, and an ambiguous retry after process
//  death must reuse that exact key. This journal is connection state, not a
//  credential. It stores no bearer/capability material.
//
//  An entry remains durable until the Hub operation is known applied AND the
//  Room projection has successfully resynchronized. If the app dies anywhere
//  earlier, the next equivalent gesture recovers the same intent/key and
//  either replays the same POST or resumes GET /operations/{id}.
//
//  STORAGE CONTRACT (P1-3): the journal is a single JSON file in Application
//  Support, committed with an explicit crash-durability protocol — encode to
//  a temp file in the same directory, fsync, then atomic rename. The network
//  POST becomes reachable only after this commit succeeds. Any encoding or
//  write failure FAILS CLOSED: the mutating API throws and the in-memory
//  state is left untouched, so the mutation path is unreachable.
//
//  LOAD CONTRACT (P1-1): absent / healthy / unreadable / incompatible are
//  four distinct states. An unreadable or incompatible payload POISONS the
//  journal: it blocks every mutation, retains the raw evidence bytes, and
//  requires an explicit operator reset (or a real migration). It never
//  silently degrades into an empty journal.
//
//  DELETION CONTRACT (P1-2): dashboard removal retires only RESOLVED
//  (applied) entries. Pending/recorded intents are safety state for external
//  side effects and OUTLIVE dashboard credential/configuration deletion —
//  re-adding the dashboard recovers them. Abandoning unresolved intents is a
//  separate explicit destructive API, never a side effect of deletion.
//

import Foundation

struct RoomControlJournal {
    static let schemaVersion = 1
    static let defaultFileName = "roomControlJournal.v1.json"
    /// I4 shipped this UserDefaults key before the crash-durable file journal.
    /// Upgrade must migrate it before an empty file-backed journal can exist,
    /// otherwise an ambiguous pre-upgrade mutation could mint a second key.
    static let legacyStorageKey = "conduit.roomControlJournal.v1"

    enum Phase: String, Codable, Equatable {
        case pending
        case recorded
        case applied
    }

    struct Entry: Codable, Equatable {
        var intent: RoomControlIntent
        var operationID: String?
        var phase: Phase
        var updatedAt: Date
    }

    /// How the persisted payload loaded. ABSENT (first run) and HEALTHY are
    /// usable; UNREADABLE (bytes present but undecodable) and INCOMPATIBLE
    /// (unsupported schema version) poison the journal.
    enum LoadState: Equatable {
        case absent
        case healthy
        case unreadable
        case incompatible(foundVersion: Int)
        /// A valid legacy payload exists, but committing its crash-durable
        /// file migration failed. Mutations remain blocked and the legacy
        /// bytes stay in UserDefaults so the next launch can retry safely.
        case migrationFailed
    }

    enum JournalError: Error, Equatable {
        /// The journal is poisoned (unreadable/incompatible payload).
        /// Mutations are blocked until an explicit operator reset.
        case poisoned
        /// resetPoisonedJournal was called on a usable journal.
        case notPoisoned
        /// The crash-durable commit failed. In-memory state is untouched —
        /// the mutation path is unreachable. Never silently proceeds.
        case persistenceFailed(reason: String)
    }

    private struct Payload: Codable, Equatable {
        let version: Int
        var entries: [String: Entry]
        var order: [String]
    }

    private let directoryURL: URL
    private let fileURL: URL
    private let legacyDefaults: UserDefaults
    private let legacyStorageKey: String
    private var payload: Payload
    private(set) var loadState: LoadState
    /// Raw evidence retained while the journal is poisoned. Never discarded
    /// silently — only an explicit reset with preservingEvidence: false
    /// drops it.
    private(set) var poisonEvidence: Data?

    /// True when the persisted payload was unreadable or incompatible.
    /// Every mutating API throws `.poisoned` while this holds.
    var isPoisoned: Bool {
        switch loadState {
        case .unreadable, .incompatible, .migrationFailed: return true
        case .absent, .healthy: return false
        }
    }

    static func defaultStorageDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("Conduit", isDirectory: true)
    }

    init(
        storageDirectory: URL? = nil,
        fileName: String = Self.defaultFileName,
        legacyDefaults: UserDefaults = .standard,
        legacyStorageKey: String = Self.legacyStorageKey
    ) {
        let directory = storageDirectory ?? Self.defaultStorageDirectory()
        self.directoryURL = directory
        self.fileURL = directory.appendingPathComponent(fileName)
        self.legacyDefaults = legacyDefaults
        self.legacyStorageKey = legacyStorageKey
        self.payload = Payload(version: Self.schemaVersion, entries: [:], order: [])
        self.loadState = .absent
        self.poisonEvidence = nil

        // The file-backed journal is authoritative once present.
        if FileManager.default.fileExists(atPath: fileURL.path) {
            guard let data = try? Data(contentsOf: fileURL) else {
                self.loadState = .unreadable
                return
            }
            guard let stored = try? JSONDecoder().decode(Payload.self, from: data) else {
                self.loadState = .unreadable
                self.poisonEvidence = data
                return
            }
            guard stored.version == Self.schemaVersion else {
                self.loadState = .incompatible(foundVersion: stored.version)
                self.poisonEvidence = data
                return
            }
            self.payload = stored
            self.loadState = .healthy
            return
        }

        // Upgrade migration from the original UserDefaults journal. A valid
        // legacy payload MUST be committed to the crash-durable file before
        // the legacy key is retired or mutable controls become reachable.
        guard let legacyData = legacyDefaults.data(forKey: legacyStorageKey) else {
            return
        }
        guard let stored = try? JSONDecoder().decode(Payload.self, from: legacyData) else {
            self.loadState = .unreadable
            self.poisonEvidence = legacyData
            return
        }
        guard stored.version == Self.schemaVersion else {
            self.loadState = .incompatible(foundVersion: stored.version)
            self.poisonEvidence = legacyData
            return
        }

        self.payload = stored
        do {
            try persist(stored)
            self.loadState = .healthy
            legacyDefaults.removeObject(forKey: legacyStorageKey)
        } catch {
            // Fail closed. Keep the exact legacy payload both in
            // UserDefaults (for automatic retry next launch) and as operator
            // evidence in this session.
            self.loadState = .migrationFailed
            self.poisonEvidence = legacyData
        }
    }

    func entry(intentID: UUID) -> Entry? {
        payload.entries[intentID.uuidString]
    }

    /// Unresolved (pending/recorded) entries for a dashboard — the intents
    /// dashboard deletion must NOT retire.
    func unresolvedEntries(dashboardID: UUID) -> [Entry] {
        payload.entries.values.filter {
            $0.intent.dashboardID == dashboardID && $0.phase != .applied
        }
    }

    /// Returns an unresolved/recovery entry for the same semantic operator
    /// intent, or persists the newly minted intent before any network I/O.
    ///
    /// Matching deliberately excludes intent UUID and idempotencyKey. Those
    /// are the durable identities we are trying to recover.
    ///
    /// THROWS `.poisoned` when the journal is poisoned (mutable controls are
    /// blocked) and `.persistenceFailed` when the crash-durable commit
    /// fails — in both cases the mutation path is unreachable.
    mutating func recoverOrInsert(_ candidate: RoomControlIntent, at: Date) throws -> RoomControlIntent {
        guard !isPoisoned else { throw JournalError.poisoned }
        if let existing = payload.order.reversed().compactMap({ payload.entries[$0] }).first(where: {
            Self.sameSemanticIntent($0.intent, candidate)
        }) {
            return existing.intent
        }

        var next = payload
        let key = candidate.id.uuidString
        next.entries[key] = Entry(
            intent: candidate,
            operationID: nil,
            phase: .pending,
            updatedAt: at
        )
        next.order.removeAll { $0 == key }
        next.order.append(key)
        try persist(next)
        payload = next
        return candidate
    }

    mutating func recordOperation(
        intentID: UUID,
        operationID: String,
        status: ControlOperationStatus,
        at: Date
    ) throws {
        guard !isPoisoned else { throw JournalError.poisoned }
        let key = intentID.uuidString
        guard var entry = payload.entries[key] else { return }
        var next = payload
        entry.operationID = operationID
        entry.phase = status == .applied ? .applied : .recorded
        entry.updatedAt = at
        next.entries[key] = entry
        try persist(next)
        payload = next
    }

    mutating func remove(intentID: UUID) throws {
        guard !isPoisoned else { throw JournalError.poisoned }
        let key = intentID.uuidString
        guard payload.entries[key] != nil else { return }
        var next = payload
        next.entries.removeValue(forKey: key)
        next.order.removeAll { $0 == key }
        try persist(next)
        payload = next
    }

    /// Dashboard removal retires only RESOLVED (applied) entries. Unresolved
    /// (pending/recorded) intents are safety state for external side effects:
    /// they outlive dashboard credential/configuration deletion, so this can
    /// never yank an entry from under an in-flight `perform` — the returning
    /// `recordOperation` always finds its entry, and re-adding the dashboard
    /// recovers the same idempotency identity.
    mutating func clearDashboard(_ dashboardID: UUID) throws {
        guard !isPoisoned else { throw JournalError.poisoned }
        let keys = payload.entries.compactMap { key, entry in
            (entry.intent.dashboardID == dashboardID && entry.phase == .applied) ? key : nil
        }
        guard !keys.isEmpty else { return }
        var next = payload
        for key in keys { next.entries.removeValue(forKey: key) }
        next.order.removeAll { keys.contains($0) }
        try persist(next)
        payload = next
    }

    /// Explicit, destructive abandonment of a dashboard's unresolved control
    /// intents. This is NEVER a side effect of dashboard removal.
    ///
    /// Consequence, stated plainly: abandoned intents lose replay protection.
    /// A later equivalent gesture mints a NEW idempotency key, and an
    /// ambiguous in-flight mutation may then apply twice. Call only as a
    /// deliberate operator choice.
    mutating func abandonUnresolvedIntents(dashboardID: UUID) throws {
        guard !isPoisoned else { throw JournalError.poisoned }
        let keys = payload.entries.compactMap { key, entry in
            (entry.intent.dashboardID == dashboardID && entry.phase != .applied) ? key : nil
        }
        guard !keys.isEmpty else { return }
        var next = payload
        for key in keys { next.entries.removeValue(forKey: key) }
        next.order.removeAll { keys.contains($0) }
        try persist(next)
        payload = next
    }

    /// Explicit operator reset of a poisoned journal. Requires the journal to
    /// actually be poisoned (throws `.notPoisoned` otherwise) so a healthy
    /// ledger can never be wiped by accident. The reset itself is committed
    /// with the same crash-durable protocol — if it fails, the journal stays
    /// poisoned. Returns the raw evidence bytes when `preservingEvidence` is
    /// true; when false, the evidence is discarded as the operator asked.
    @discardableResult
    mutating func resetPoisonedJournal(preservingEvidence: Bool) throws -> Data? {
        guard isPoisoned else { throw JournalError.notPoisoned }
        let evidence = preservingEvidence ? poisonEvidence : nil
        let next = Payload(version: Self.schemaVersion, entries: [:], order: [])
        try persist(next)
        payload = next
        loadState = .healthy
        legacyDefaults.removeObject(forKey: legacyStorageKey)
        // The evidence is handed to the caller via the return value, never
        // retained internally: after reset the journal is healthy and empty.
        poisonEvidence = nil
        return evidence
    }

    private static func sameSemanticIntent(
        _ lhs: RoomControlIntent,
        _ rhs: RoomControlIntent
    ) -> Bool {
        lhs.dashboardID == rhs.dashboardID
            && lhs.roomID == rhs.roomID
            && lhs.executionID == rhs.executionID
            && lhs.action == rhs.action
            && lhs.attentionKind == rhs.attentionKind
            && lhs.trigger == rhs.trigger
            && lhs.projectSlug == rhs.projectSlug
        // correlationID is descriptive lineage, not Hub idempotency target
        // identity. If a refreshed projection carries a different/absent
        // correlation value after restart, the same op+target must still
        // recover the original key rather than risk a second mutation.
    }

    /// Crash-durable commit: encode → temp file in the same directory →
    /// fsync → atomic rename. Throws `.persistenceFailed` on ANY failure
    /// without touching in-memory state — callers stage into `next` and
    /// assign only after this returns, so a failed commit fails closed.
    private func persist(_ next: Payload) throws {
        let data: Data
        do {
            data = try JSONEncoder().encode(next)
        } catch {
            throw JournalError.persistenceFailed(reason: "encode failed: \(error)")
        }
        do {
            let fm = FileManager.default
            try fm.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            let tmpURL = fileURL.appendingPathExtension("tmp")
            if fm.fileExists(atPath: tmpURL.path) {
                // Stale temp from a crashed write — it was never renamed
                // into place, so it is safe to drop.
                try fm.removeItem(at: tmpURL)
            }
            try data.write(to: tmpURL)
            let handle = try FileHandle(forWritingTo: tmpURL)
            // fsync: the bytes are crash-durable before the rename.
            try handle.synchronize()
            try handle.close()
            // POSIX rename(2): atomic within the same directory, and it
            // REPLACES an existing destination — unlike
            // FileManager.moveItem, which refuses to overwrite and would
            // break every commit after the first.
            let renamed = tmpURL.withUnsafeFileSystemRepresentation { tmpRep in
                fileURL.withUnsafeFileSystemRepresentation { dstRep in
                    rename(tmpRep, dstRep)
                }
            }
            guard renamed == 0 else {
                let code = errno
                try? fm.removeItem(at: tmpURL)
                throw JournalError.persistenceFailed(
                    reason: "atomic rename failed: \(String(cString: strerror(code)))"
                )
            }
            // NOTE: a directory fsync after the rename would harden the
            // crash contract further, but Swift cannot call the variadic
            // POSIX open(2) needed to obtain a directory fd. The payload
            // fsync + atomic rename above is the required contract.
        } catch let journalError as JournalError {
            throw journalError
        } catch {
            throw JournalError.persistenceFailed(reason: "write failed: \(error)")
        }
    }
}
