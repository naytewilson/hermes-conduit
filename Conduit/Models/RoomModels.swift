//
//  RoomModels.swift
//  Conduit
//
//  ANVIL Room read/projection wire models — the client side of the Hub H1
//  read seam (`feat/room-projection-v1-20260915` @ 078ff5a2).
//
//  These are AUTHORITY-MINTED projections passed through unchanged: every
//  identity field (`room_id`, `event_id`, `room_seq`, `correlation_id`,
//  `causation_id`, `task_ref`, `idempotency_key`, evidence references inside
//  `payload`/`link`) is server-owned. Conduit never mints, renumbers, or
//  substitutes them — `room_seq` is the canonical replay cursor and
//  (room_id, room_seq) is the projection dedupe key. Wire field names are
//  the Foundation Interop V1 snake_case vocabulary, mapped explicitly in
//  CodingKeys so a rename here can never silently break the contract.
//

import Foundation

enum RoomStatus: String, Codable, Equatable {
    case active
    case archived
    case closed
}

/// `room_events.kind` is an OPEN taxonomy owned by the authority: the Hub
/// adds kinds as the Nervous System integration lands (`dispatch.received`,
/// `execution.bound`, `execution.transition`, `sieve.projection`, …) and a
/// closed client enum would fail the whole page decode on the first new
/// kind — marking a healthy projection stale. The raw wire value is kept
/// verbatim so unknown kinds decode, persist, and re-encode losslessly;
/// known kinds are named statics for call sites.
struct RoomEventKind: RawRepresentable, Codable, Equatable, Hashable {
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        rawValue = try container.decode(String.self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    static let message = RoomEventKind(rawValue: "message")
    static let handoff = RoomEventKind(rawValue: "handoff")
    static let approval = RoomEventKind(rawValue: "approval")
    static let evidenceRef = RoomEventKind(rawValue: "evidence_ref")
    static let execution = RoomEventKind(rawValue: "execution")
    static let system = RoomEventKind(rawValue: "system")
    // I1 spine + I3 convergence + I2 projection kinds (DESIGN-I1-I7 §2–§5).
    static let dispatchReceived = RoomEventKind(rawValue: "dispatch.received")
    static let executionBound = RoomEventKind(rawValue: "execution.bound")
    static let executionRebound = RoomEventKind(rawValue: "execution.rebound")
    static let executionTransition = RoomEventKind(rawValue: "execution.transition")
    static let sieveProjection = RoomEventKind(rawValue: "sieve.projection")
}

/// Projection of `anvil.rooms`. `latestSeq` is the committed high-water
/// room_seq (0 for an empty room).
struct ProjectedRoom: Codable, Equatable {
    let roomID: String
    let projectRef: String?
    let status: RoomStatus
    let correlationID: String
    let latestSeq: Int
    let createdAt: String
    let updatedAt: String

    enum CodingKeys: String, CodingKey {
        case roomID = "room_id"
        case projectRef = "project_ref"
        case status
        case correlationID = "correlation_id"
        case latestSeq = "latest_seq"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

/// Active `anvil.room_participants` period. `agentID` is the durable
/// `anvil.agents.public_id` — a participant is an agent, never a session.
struct RoomParticipant: Codable, Equatable {
    let participantID: String
    let agentID: String
    let role: String
    let joinedSeq: Int?
    let ackedSeq: Int
    let joinedAt: String

    enum CodingKeys: String, CodingKey {
        case participantID = "participant_id"
        case agentID = "agent_id"
        case role
        case joinedSeq = "joined_seq"
        case ackedSeq = "acked_seq"
        case joinedAt = "joined_at"
    }
}

/// One committed `anvil.room_events` row. `roomSeq` is authority-assigned,
/// per-room monotonic (gaps are legal), and is the replay cursor. `payload`
/// and `link` are opaque authority envelopes — kept as unstructured JSON so
/// evidence references inside them pass through verbatim.
struct RoomEvent: Codable, Equatable {
    let eventID: String
    let roomID: String
    let roomSeq: Int
    let kind: RoomEventKind
    let producer: String
    let payload: [String: AnyCodable]
    let link: [String: AnyCodable]
    let correlationID: String
    let causationID: String?
    let taskRef: String?
    let campaignID: String?
    let idempotencyKey: String
    let occurredAt: String?
    let createdAt: String

    enum CodingKeys: String, CodingKey {
        case eventID = "event_id"
        case roomID = "room_id"
        case roomSeq = "room_seq"
        case kind
        case producer
        case payload
        case link
        case correlationID = "correlation_id"
        case causationID = "causation_id"
        case taskRef = "task_ref"
        case campaignID = "campaign_id"
        case idempotencyKey = "idempotency_key"
        case occurredAt = "occurred_at"
        case createdAt = "created_at"
    }

    /// The projection dedupe identity: (room_id, room_seq).
    var dedupeKey: RoomEventKey {
        RoomEventKey(roomID: roomID, roomSeq: roomSeq)
    }
}

/// (room_id, room_seq) — the projection dedupe key.
struct RoomEventKey: Hashable, Codable {
    let roomID: String
    let roomSeq: Int

    enum CodingKeys: String, CodingKey {
        case roomID = "room_id"
        case roomSeq = "room_seq"
    }
}

extension ProjectedRoom: Identifiable {
    var id: String { roomID }
}

extension RoomParticipant: Identifiable {
    var id: String { participantID }
}

extension RoomEvent: Identifiable {
    var id: String { eventID }
}

/// `GET /api/v1/rooms` — the Rooms readable by the bound ANVIL subject.
struct RoomList: Codable, Equatable {
    let rooms: [ProjectedRoom]
}

/// `GET /api/v1/rooms/{roomId}` — projected Room record + active participants.
struct RoomSnapshot: Codable, Equatable {
    let room: ProjectedRoom
    let participants: [RoomParticipant]
}

/// `GET /api/v1/rooms/{roomId}/events?after=N&limit=M` — deterministic
/// replay page: committed events with room_seq > `after`, ascending.
/// Re-issue `nextCursor` as `after` to continue; `hasMore` reports whether
/// the committed high-water is still ahead of the emitted tail.
struct RoomEventPage: Codable, Equatable {
    static let defaultLimit = 500
    static let maximumLimit = 500

    let room: ProjectedRoom
    let events: [RoomEvent]
    let latestSeq: Int
    let nextCursor: Int
    let hasMore: Bool

    enum CodingKeys: String, CodingKey {
        case room
        case events
        case latestSeq = "latest_seq"
        case nextCursor = "next_cursor"
        case hasMore = "has_more"
    }
}

/// Hub RFC problem document (`application/problem+json`). Field names match
/// the Hub Problem schema verbatim — note `requestId` is camelCase there
/// while the Room payloads are snake_case.
struct RoomProblem: Codable, Equatable {
    let type: String?
    let title: String?
    let status: Int
    let detail: String?
    let code: String
    let requestID: String?

    enum CodingKeys: String, CodingKey {
        case type
        case title
        case status
        case detail
        case code
        case requestID = "requestId"
    }
}
