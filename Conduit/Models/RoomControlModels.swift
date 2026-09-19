//
//  RoomControlModels.swift
//  Conduit
//
//  ANVIL Room control wire models — the client side of the Hub I4 mutable
//  seam, implemented against the FROZEN contract
//  (docs/contracts/HUB_CONTROL_CONTRACT_V1.md @ a552616, hub main f5e109e8):
//
//    POST /api/v1/controls/executions/{executionId}/cancel      → 200 op record (applied)
//    POST /api/v1/controls/executions/{executionId}/acknowledge → 200 op record (applied)
//    POST /api/v1/controls/executions/{executionId}/retry       → 202 op record (recorded)
//    POST /api/v1/controls/executions/{executionId}/resume      → 202 op record (recorded)
//    POST /api/v1/controls/executions/start                    → 201 op record (applied)
//    GET  /api/v1/controls/operations/{operationId}             → 200 op record
//    GET  /api/v1/controls/operations?executionId?&op?&status?&limit?
//                                                        → 200 { operations: [...] }
//
//  Authority boundary (unchangeable): Conduit NEVER mints authority. The Hub
//  instance's bound ANVIL subject holds the durable capability grant; the
//  client presents only transport auth (Bearer + scope). There is no
//  grant-mint endpoint and no grant_id anywhere on the wire — the entire
//  grant-mint flow of the v1 DRAFT is deleted.
//
//  Idempotency: `idempotencyKey` (1–64 chars) is REQUIRED in every POST body,
//  minted once per user gesture. Same key replays the stored result
//  byte-identical (200 + "replayed": true); same key + different op/target →
//  409 `idempotency_key_conflict`. Replay skips the capability check.
//
//  Async ops: retry/resume return 202 `recorded` — the intent is durably
//  recorded and projected for the execution authority to consume. The client
//  polls GET /operations/{operationId} for the recorded→applied transition;
//  `recorded` is "authorized and queued", never "the agent is running again".
//
//  Field convention: Hub-owned API is camelCase.
//

import Foundation

/// The mutable op vocabulary (contract §1). `RoomControlAction` is
/// RawRepresentable so a Hub op the client doesn't know yet still round-trips
/// in diagnostics without breaking decode — but candidate UI actions are
/// only ever the named statics. Five ops; there is no `pause` in V1.
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

    static let acknowledge = RoomControlAction(rawValue: "acknowledge")
    static let resume = RoomControlAction(rawValue: "resume")
    static let retry = RoomControlAction(rawValue: "retry")
    static let cancel = RoomControlAction(rawValue: "cancel")
    static let start = RoomControlAction(rawValue: "start")

    var isDestructive: Bool { self == .cancel }

    /// The op value the server records for this action (contract §3.3).
    /// `start` records as `execution_start`; the rest record as themselves.
    var recordOpValue: String {
        self == .start ? "execution_start" : rawValue
    }

    /// Whether the action targets one existing execution (`start` does not —
    /// it dispatches through the manual-run pipeline with trigger/project).
    var targetsExecution: Bool { self != .start }
}

/// The attention kinds a public `acknowledge` call may carry (contract
/// §2.2). `finish_execution_call` is daemon-side only — a public request with
/// this kind returns 409 `control_precondition_failed`.
enum AttentionKind: String, Codable, Equatable, CaseIterable {
    case terminal
    case idle
    case finishExecutionCall = "finish_execution_call"

    /// Kinds the UI may offer for a user-driven acknowledge.
    static var userSelectable: [AttentionKind] { [.terminal, .idle] }
}

/// Op lifecycle state (contract §3.3, §4).
enum ControlOperationStatus: String, Codable, Equatable {
    case recorded
    case applied
}

/// POST body shared by the execution-targeted ops (cancel/retry/resume):
/// `{idempotencyKey (REQUIRED), correlationId?}`. Property names are
/// wire-exact camelCase per the frozen contract.
struct TargetedOperationRequest: Codable, Equatable {
    let idempotencyKey: String
    let correlationId: String?
}

/// POST /controls/executions/{executionId}/acknowledge body (contract §2.2):
/// `{attentionKind, idempotencyKey, correlationId?}`.
struct AcknowledgeAttentionRequest: Codable, Equatable {
    let attentionKind: AttentionKind
    let idempotencyKey: String
    let correlationId: String?
}

/// POST /controls/executions/start body (contract §2.3): dispatches through
/// the manual-run pipeline. `actor` defaults server-side to the calling
/// credential ID when omitted or empty.
struct StartApprovedExecutionRequest: Codable, Equatable {
    let trigger: String
    let projectSlug: String
    let idempotencyKey: String
    let input: AnyCodable?
    let actor: String?
    let expectedVersionId: String?
    let correlationId: String?

    static func == (lhs: StartApprovedExecutionRequest, rhs: StartApprovedExecutionRequest) -> Bool {
        lhs.trigger == rhs.trigger
            && lhs.projectSlug == rhs.projectSlug
            && lhs.idempotencyKey == rhs.idempotencyKey
            && lhs.input == rhs.input
            && lhs.actor == rhs.actor
            && lhs.expectedVersionId == rhs.expectedVersionId
            && lhs.correlationId == rhs.correlationId
    }
}

/// The op record (contract §3.3) — the Hub's durable, replayable account of
/// one control op. camelCase throughout; `replayed` is present only on
/// idempotent replay (HTTP 200). `executionId` is null for `start`.
struct ControlOperationRecord: Codable, Equatable {
    let operationId: String
    let op: String
    let status: ControlOperationStatus
    let replayed: Bool?
    let idempotencyKey: String
    let executionId: String?
    let capability: String?
    let subject: String?
    let correlationId: String?
    let effect: AnyCodable?
    let createdAt: String
    let updatedAt: String

    /// Whether the server reports this response as an idempotent replay of
    /// an already-recorded op — success-adjacent, rendered distinctly.
    var isReplay: Bool { replayed == true }

    /// Whether the op is durably recorded but its effect is owned downstream
    /// (retry/resume → 202). Not "the agent is running again".
    var isRecorded: Bool { status == .recorded }

    /// The client action this record answers, when the op value is one of
    /// the five known ops.
    var action: RoomControlAction? {
        if op == "execution_start" { return .start }
        let candidate = RoomControlAction(rawValue: op)
        return [.acknowledge, .resume, .retry, .cancel].contains(candidate) ? candidate : nil
    }
}

/// GET /controls/operations?… response (contract §3.2).
struct ControlOperationList: Codable, Equatable {
    let operations: [ControlOperationRecord]
}

// MARK: - Execution derivation from the Room timeline

/// The controllable-execution projection of one execution_id, folded from
/// the Room event stream. The Room log is the convergence record (DESIGN
/// §4): Conduit derives execution state FROM the timeline rather than
/// trusting any payload as live authority — the freshest sync is what makes
/// this projection true.
struct RoomExecutionProjection: Equatable, Identifiable {
    let executionID: String
    /// Latest reported state verb (queued/running/failed/…), raw.
    var state: String?
    /// Latest transition's room_seq — the position in the authority log.
    var lastSeq: Int
    var lastTransitionAt: String?
    /// The bound subject on the most recent control op, when the authority
    /// recorded one (the op record's `subject`).
    var subject: String?
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
/// contract: the transition payload is
/// `{execution_id, from_state, to_state, substate, reason, actor}`, so
/// extraction reads those spellings first and ignores events that carry no
/// execution identity. Pure — no I/O — so the fold is exhaustively testable.
enum RoomExecutionIndex {
    /// Payload keys consulted for each field, in priority order.
    private static let executionIDKeys = ["execution_id", "executionId"]
    private static let stateKeys = ["to_state", "state", "status", "to"]
    /// The transition payload names the actor `actor`.
    private static let principalKeys = ["actor", "granting_principal", "principal", "requested_by", "subject"]
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
            if let subject = firstString(in: event.payload, keys: principalKeys), !subject.isEmpty {
                projection.subject = subject
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
/// frozen contract's preconditions (§2). This is a PRESENTATION policy only —
/// authority is never inferred from a button. Every tap still runs biometric
/// step-up → Hub arbitration; a state the policy misjudges surfaces the
/// Hub's denial verbatim. Server-advertised `available_actions`, when
/// present, replace this map entirely.
///
/// Notes on the frozen preconditions: cancel is valid from spawning/running;
/// retry/resume from failed; acknowledge needs only an existing execution.
/// `start` is NOT a per-execution action in V1 — it dispatches through the
/// manual-run pipeline with trigger/projectSlug, so it never appears here.
enum RoomControlPolicy {
    /// Candidate actions for one execution, in display order.
    static func candidates(for execution: RoomExecutionProjection) -> [RoomControlAction] {
        if let advertised = execution.advertisedActions {
            return advertised.map { RoomControlAction(rawValue: $0) }
        }
        switch execution.state {
        case "spawning", "running":
            return [.acknowledge, .cancel]
        case "tool_wait", "requires_attention":
            return [.acknowledge, .cancel]
        case "failed", "cancelled":
            return [.retry, .resume]
        default:
            // queued / paused / parked / handed_off / succeeded / unknown:
            // no frozen op is valid from these states — show nothing rather
            // than imply authority the Hub never advertised.
            return []
        }
    }
}
