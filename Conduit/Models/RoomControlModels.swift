//
//  RoomControlModels.swift
//  Conduit
//
//  ANVIL Room control wire models — the client side of the Hub I4 mutable
//  seam, implemented against anvil-i17-i3's published contract
//  (cells/anvil-i17-i3/context/endpoint-contract-i4.md, v1 DRAFT):
//
//    POST /api/v1/executions/{execution_id}/capability-grants
//      {action, ttl_seconds?}            → 201 CapabilityGrant (Hub-minted)
//    POST /api/v1/executions/{execution_id}/{action}
//      {grant_id, request_id?}           → 200 ExecutionActionAck
//
//  Authority boundary (unchangeable): Conduit NEVER mints grants. It asks the
//  Hub for a grant bound to (execution_id, action, principal) — the principal
//  is derived server-side from the Hub credential — then invokes the action
//  by grant_id reference. Every grant field is server-owned and passed
//  through verbatim. The only client-minted value on the wire is
//  `request_id`, an opaque idempotency token — never authority.
//

import Foundation

/// The mutable action vocabulary (contract §Endpoints: the six legal path
/// verbs). `RoomControlAction` is RawRepresentable so a Hub action the client
/// doesn't know yet still round-trips in diagnostics without breaking decode —
/// but candidate UI actions are only ever the named statics.
struct RoomControlAction: RawRepresentable, Codable, Equatable, Hashable {
    let rawValue: String

    init(rawValue: String) { self.rawValue = rawValue }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        rawValue = try container.decode(String.self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    /// The contract's action family: {start, pause, resume, cancel, retry,
    /// acknowledge}. `pause` completes the A4 sequence (pause → resume →
    /// cancel).
    static let acknowledge = RoomControlAction(rawValue: "acknowledge")
    static let pause = RoomControlAction(rawValue: "pause")
    static let resume = RoomControlAction(rawValue: "resume")
    static let retry = RoomControlAction(rawValue: "retry")
    static let cancel = RoomControlAction(rawValue: "cancel")
    static let start = RoomControlAction(rawValue: "start")

    var isDestructive: Bool { self == .cancel }
}

/// The Hub-minted capability grant (contract §Model): bound to
/// (execution_id, action, principal), persisted server-side in
/// `anvil.capability_grants`. Every field is authority-owned — Conduit stores
/// and echoes `grant_id`, never constructs one. `scope_hash` is advisory only;
/// the durable grant row is authoritative.
struct CapabilityGrant: Codable, Equatable {
    let grantID: String
    let executionID: String
    let action: RoomControlAction
    /// `device:hub-credential:<credentialId>` — derived by the Hub from the
    /// caller's credential; Conduit cannot choose or widen it.
    let principal: String
    let issuedAt: String
    let expiresAt: String
    let scopeHash: String?

    enum CodingKeys: String, CodingKey {
        case grantID = "grant_id"
        case executionID = "execution_id"
        case action
        case principal
        case issuedAt = "issued_at"
        case expiresAt = "expires_at"
        case scopeHash = "scope_hash"
    }
}

/// `POST /api/v1/executions/{execution_id}/capability-grants` request body —
/// the execution is the path subject; the body carries the action and an
/// optional TTL (contract default 300s, max 3600s).
struct ExecutionGrantRequest: Codable, Equatable {
    let action: RoomControlAction
    let ttlSeconds: Int?

    enum CodingKeys: String, CodingKey {
        case action
        case ttlSeconds = "ttl_seconds"
    }
}

/// `POST /api/v1/executions/{execution_id}/{action}` request body. The grant
/// is referenced by server-minted id only — the client never sends grant
/// material it constructed. `request_id` is the caller's opaque per-intent
/// idempotency token, stable across retries of one intent.
struct ExecutionActionRequest: Codable, Equatable {
    let grantID: String
    let requestID: String?

    enum CodingKeys: String, CodingKey {
        case grantID = "grant_id"
        case requestID = "request_id"
    }
}

/// The mutable endpoint's acknowledgement (contract §Endpoints). `state` is
/// the authority's execution-state vocabulary kept as a raw string — Conduit
/// never maps it into its own state machine. `duplicate: true` means the same
/// (execution, action, grant) was already committed — the returned
/// `room_seq`/`event_id` are the ORIGINAL commit. `retry` additionally returns
/// `retry_execution_id` naming the new attempt. Optional fields tolerate
/// absence: the authoritative record of the action is the Room timeline the
/// client re-reads after success.
struct ExecutionActionAck: Codable, Equatable {
    let executionID: String
    let state: String?
    let substate: String?
    let roomSeq: Int?
    let eventID: String?
    let duplicate: Bool?
    let retryExecutionID: String?

    enum CodingKeys: String, CodingKey {
        case executionID = "execution_id"
        case state
        case substate
        case roomSeq = "room_seq"
        case eventID = "event_id"
        case duplicate
        case retryExecutionID = "retry_execution_id"
    }

    /// Whether the server reports this request as a deduped replay of an
    /// already-committed intent — success-adjacent, rendered distinctly.
    var isDuplicateReplay: Bool {
        duplicate == true
    }
}

// MARK: - Execution derivation from the Room timeline

/// The controllable-execution projection of one execution_id, folded from
/// the Room event stream. The Room log is the convergence record (DESIGN
/// §4): Conduit derives execution state FROM the timeline rather than
/// trusting any payload as live authority — the freshest sync is what makes
/// this projection true.
struct RoomExecutionProjection: Equatable, Identifiable {
    let executionID: String
    /// Latest reported state verb (queued/running/paused/tool_wait/…), raw.
    var state: String?
    /// Latest transition's room_seq — the position in the authority log.
    var lastSeq: Int
    var lastTransitionAt: String?
    /// The granting principal on the most recent control action, when the
    /// authority recorded one (`actor` in the contract's transition payload).
    var principal: String?
    var taskRef: String?
    var correlationID: String?
    /// Actions the authority advertised as valid on the latest transition,
    /// when it publishes them (`available_actions`/`allowed_actions`).
    var advertisedActions: [String]?

    var id: String { executionID }

    /// Terminal states carry no candidate controls; everything else may.
    var isTerminal: Bool {
        guard let state else { return false }
        return ["succeeded", "failed", "cancelled"].contains(state)
    }
}

/// Folds committed room events into per-execution projections. Tolerant by
/// contract: the transition payload per i3's contract is
/// `{execution_id, from_state, to_state, substate, reason, actor, grant_id}`,
/// so extraction reads those spellings first and ignores events that carry
/// no execution identity. Pure — no I/O — so the fold is exhaustively
/// testable.
enum RoomExecutionIndex {
    /// Payload keys consulted for each field, in priority order.
    private static let executionIDKeys = ["execution_id", "executionId"]
    private static let stateKeys = ["to_state", "state", "status", "to"]
    /// The contract's transition payload names the principal `actor`.
    private static let principalKeys = ["actor", "granting_principal", "principal", "requested_by"]
    private static let actionListKeys = ["available_actions", "allowed_actions", "actions"]

    /// Folds `events` (expected ascending room_seq, but order-tolerant: the
    /// last write is the event with the HIGHEST room_seq, not the last
    /// arrival) into the current projection per execution.
    static func projections(from events: [RoomEvent]) -> [RoomExecutionProjection] {
        var byID: [String: RoomExecutionProjection] = [:]
        var seqs: [String: Int] = [:]
        for event in events.sorted(by: { $0.roomSeq < $1.roomSeq }) {
            guard let executionID = firstString(in: event.payload, keys: executionIDKeys),
                  !executionID.isEmpty else { continue }
            let seq = seqs[executionID] ?? -1
            guard event.roomSeq >= seq else { continue }
            seqs[executionID] = event.roomSeq

            var projection = byID[executionID]
                ?? RoomExecutionProjection(executionID: executionID, lastSeq: event.roomSeq)
            projection.lastSeq = event.roomSeq
            if let state = firstString(in: event.payload, keys: stateKeys), !state.isEmpty {
                projection.state = state
            }
            if let principal = firstString(in: event.payload, keys: principalKeys), !principal.isEmpty {
                projection.principal = principal
            }
            if let at = event.occurredAt ?? Optional(event.createdAt) {
                projection.lastTransitionAt = at
            }
            if let taskRef = event.taskRef {
                projection.taskRef = taskRef
            }
            if !event.correlationID.isEmpty {
                projection.correlationID = event.correlationID
            }
            if let advertised = firstStringList(in: event.payload, keys: actionListKeys) {
                projection.advertisedActions = advertised
            }
            byID[executionID] = projection
        }
        return byID.values.sorted { $0.lastSeq > $1.lastSeq }
    }

    private static func firstString(in payload: [String: AnyCodable], keys: [String]) -> String? {
        for key in keys {
            if let value = payload[key]?.stringValue { return value }
        }
        return nil
    }

    private static func firstStringList(in payload: [String: AnyCodable], keys: [String]) -> [String]? {
        for key in keys {
            if case .array(let items) = payload[key] {
                let strings = items.compactMap(\.stringValue)
                if !strings.isEmpty { return strings }
            }
        }
        return nil
    }
}

/// Which controls to render for a derived execution state, mirroring the
/// contract's action-semantics table. This is a PRESENTATION policy only —
/// authority is never inferred from a button. Every tap still runs biometric
/// step-up → grant mint → Hub arbitration; a state the policy misjudges
/// surfaces the Hub's denial verbatim. Server-advertised `available_actions`,
/// when present, replace this map entirely.
enum RoomControlPolicy {
    /// Candidate actions for one execution, in display order. Mirrors the
    /// contract's "valid from" column per action.
    static func candidates(for execution: RoomExecutionProjection) -> [RoomControlAction] {
        if let advertised = execution.advertisedActions {
            return advertised.map { RoomControlAction(rawValue: $0) }
        }
        switch execution.state {
        case "queued":
            // start: begin dispatch of the bound execution.
            return [.start, .cancel]
        case "running":
            return [.pause, .acknowledge, .cancel]
        case "tool_wait", "requires_attention":
            // resume is valid from running+tool_wait per the contract.
            return [.acknowledge, .resume, .pause, .cancel]
        case "paused", "parked":
            return [.resume, .cancel]
        case "handed_off":
            return [.cancel]
        case "failed", "cancelled":
            return [.retry]
        case "succeeded":
            return []
        default:
            // Unknown/unpublished state: show nothing rather than imply
            // authority the Hub never advertised.
            return []
        }
    }
}
