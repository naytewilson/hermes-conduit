//
//  RoomControlModels.swift
//  Conduit
//
//  ANVIL Room control wire models — the client side of the Hub I4 mutable
//  seam (DESIGN-I1-I7 §5). The endpoint contract is anvil-i17-i3's to publish;
//  the shapes here implement the design-doc contract verbatim so integration
//  is a field-level diff, not a redesign:
//
//    POST /api/v1/execution-grants            → CapabilityGrant (Hub-minted)
//    POST /api/v1/executions/{id}/actions     → ExecutionActionAck
//
//  Authority boundary (unchangeable): Conduit NEVER mints grants. It asks the
//  Hub for a grant scoped to (execution_id, action, principal), then invokes
//  the action by grant_id. Every grant field is server-owned and passed
//  through verbatim — Conduit cannot widen, extend, or reinterpret one. The
//  only client-minted value on the wire is `idempotency_key`, which is a
//  dedupe token, never authority.
//

import Foundation

/// The mutable action vocabulary. `RoomControlAction` is RawRepresentable so
/// a Hub action the client doesn't know yet still round-trips in diagnostics
/// without breaking decode — but candidate UI actions are only ever the
/// named statics.
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

    /// The I4 action family (DESIGN §5). `pause` is required by terminal
    /// acceptance A4 (pause → resume → cancel) alongside the five named
    /// endpoints.
    static let acknowledge = RoomControlAction(rawValue: "acknowledge")
    static let pause = RoomControlAction(rawValue: "pause")
    static let resume = RoomControlAction(rawValue: "resume")
    static let retry = RoomControlAction(rawValue: "retry")
    static let cancel = RoomControlAction(rawValue: "cancel")
    static let start = RoomControlAction(rawValue: "start")

    var isDestructive: Bool { self == .cancel }
}

/// The Hub-minted capability grant (DESIGN §5): scoped to
/// (execution_id, action, principal), persisted server-side in Neo
/// `capability_grants`. Every field is authority-owned — Conduit stores and
/// echoes `grant_id`, never constructs one.
struct CapabilityGrant: Codable, Equatable {
    let grantID: String
    let executionID: String
    let action: RoomControlAction
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

/// `POST /api/v1/execution-grants` request body. For existing-execution
/// actions the subject is `execution_id`; for `start` (no execution exists
/// yet) the subject is `room_id` and the Hub mints the execution id into the
/// returned grant.
struct ExecutionGrantRequest: Codable, Equatable {
    let action: RoomControlAction
    let executionID: String?
    let roomID: String?

    enum CodingKeys: String, CodingKey {
        case action
        case executionID = "execution_id"
        case roomID = "room_id"
    }
}

/// `POST /api/v1/executions/{execution_id}/actions` request body. The grant
/// is referenced by server-minted id only — the client never sends grant
/// material it constructed. `idempotency_key` is stable per user intent:
/// retries of one intent reuse it so a re-sent request can never duplicate
/// the semantic effect.
struct ExecutionActionRequest: Codable, Equatable {
    let action: RoomControlAction
    let grantID: String
    let idempotencyKey: String

    enum CodingKeys: String, CodingKey {
        case action
        case grantID = "grant_id"
        case idempotencyKey = "idempotency_key"
    }
}

/// The mutable endpoint's acknowledgement. `status` is the server-owned
/// outcome vocabulary (`applied`, `duplicate_rejected`, …) kept as a raw
/// string — Conduit never maps it into its own state machine. Optional
/// fields are tolerated absent: the authoritative record of the action is
/// the Room timeline the client re-reads after success.
struct ExecutionActionAck: Codable, Equatable {
    let executionID: String
    let action: RoomControlAction
    let status: String
    let state: String?
    let roomSeq: Int?
    let correlationID: String?
    let duplicateRejected: Bool?

    enum CodingKeys: String, CodingKey {
        case executionID = "execution_id"
        case action
        case status
        case state
        case roomSeq = "room_seq"
        case correlationID = "correlation_id"
        case duplicateRejected = "duplicate_rejected"
    }

    /// Whether the server reports this request as a deduped replay of an
    /// already-applied intent — success-adjacent, rendered distinctly.
    var isDuplicateReplay: Bool {
        duplicateRejected == true || status == "duplicate_rejected"
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
    /// authority recorded one.
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
/// contract: the I3 convergence machine's exact payload shape lands with its
/// endpoint publication, so extraction reads several key spellings and
/// ignores events that carry no execution identity. Pure — no I/O — so the
/// fold is exhaustively testable.
enum RoomExecutionIndex {
    /// Payload keys consulted for each field, in priority order.
    private static let executionIDKeys = ["execution_id", "executionId"]
    private static let stateKeys = ["to_state", "state", "status", "to"]
    private static let principalKeys = ["granting_principal", "principal", "actor", "requested_by"]
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

/// Which controls to render for a derived execution state. This is a
/// PRESENTATION policy only — authority is never inferred from a button.
/// Every tap still runs biometric step-up → grant request → Hub arbitration;
/// a state the policy misjudges surfaces the Hub's denial verbatim.
/// Server-advertised `available_actions`, when present, replace this map
/// entirely.
enum RoomControlPolicy {
    /// Candidate actions for one execution, in display order.
    static func candidates(for execution: RoomExecutionProjection) -> [RoomControlAction] {
        if let advertised = execution.advertisedActions {
            return advertised.map { RoomControlAction(rawValue: $0) }
        }
        switch execution.state {
        case "queued":
            return [.cancel]
        case "running":
            return [.pause, .acknowledge, .cancel]
        case "tool_wait", "requires_attention":
            return [.acknowledge, .pause, .cancel]
        case "paused", "parked":
            return [.resume, .cancel]
        case "handed_off":
            return [.cancel]
        case "failed", "cancelled":
            return [.retry]
        case "succeeded":
            return []
        case "agent_interrupted", "orphaned":
            return [.retry, .acknowledge]
        default:
            // Unknown/unpublished state: show nothing rather than imply
            // authority the Hub never advertised.
            return []
        }
    }
}
