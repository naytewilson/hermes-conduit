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

import Foundation

struct RoomControlJournal {
    static let schemaVersion = 1
    static let defaultStorageKey = "conduit.roomControlJournal.v1"
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

    private struct Payload: Codable, Equatable {
        let version: Int
        var entries: [String: Entry]
        var order: [String]
    }

    private let defaults: UserDefaults
    private let storageKey: String
    private var payload: Payload

    init(
        defaults: UserDefaults = .standard,
        storageKey: String = RoomControlJournal.defaultStorageKey
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
        guard let data = defaults.data(forKey: storageKey),
              let stored = try? JSONDecoder().decode(Payload.self, from: data),
              stored.version == Self.schemaVersion else {
            payload = Payload(version: Self.schemaVersion, entries: [:], order: [])
            return
        }
        payload = stored
    }

    func entry(intentID: UUID) -> Entry? {
        payload.entries[intentID.uuidString]
    }

    /// Returns an unresolved/recovery entry for the same semantic operator
    /// intent, or persists the newly minted intent before any network I/O.
    ///
    /// Matching deliberately excludes intent UUID and idempotencyKey. Those
    /// are the durable identities we are trying to recover.
    mutating func recoverOrInsert(_ candidate: RoomControlIntent, at: Date) -> RoomControlIntent {
        if let existing = payload.order.reversed().compactMap({ payload.entries[$0] }).first(where: {
            Self.sameSemanticIntent($0.intent, candidate)
        }) {
            return existing.intent
        }

        let key = candidate.id.uuidString
        payload.entries[key] = Entry(
            intent: candidate,
            operationID: nil,
            phase: .pending,
            updatedAt: at
        )
        payload.order.removeAll { $0 == key }
        payload.order.append(key)
        persist()
        return candidate
    }

    mutating func recordOperation(
        intentID: UUID,
        operationID: String,
        status: ControlOperationStatus,
        at: Date
    ) {
        let key = intentID.uuidString
        guard var entry = payload.entries[key] else { return }
        entry.operationID = operationID
        entry.phase = status == .applied ? .applied : .recorded
        entry.updatedAt = at
        payload.entries[key] = entry
        persist()
    }

    mutating func remove(intentID: UUID) {
        let key = intentID.uuidString
        guard payload.entries.removeValue(forKey: key) != nil else { return }
        payload.order.removeAll { $0 == key }
        persist()
    }

    mutating func clearDashboard(_ dashboardID: UUID) {
        let keys = payload.entries.compactMap { key, entry in
            entry.intent.dashboardID == dashboardID ? key : nil
        }
        guard !keys.isEmpty else { return }
        for key in keys { payload.entries.removeValue(forKey: key) }
        payload.order.removeAll { keys.contains($0) }
        persist()
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
            && lhs.correlationID == rhs.correlationID
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(payload) else { return }
        defaults.set(data, forKey: storageKey)
    }
}
