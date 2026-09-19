//
//  RoomExecutionIndexTests.swift
//  Conduit
//
//  Pure-fold tests for the control surface's execution derivation and its
//  presentation policy, against the FROZEN contract
//  (docs/contracts/HUB_CONTROL_CONTRACT_V1.md). The Room timeline is the
//  authority (DESIGN §4): `RoomExecutionIndex` folds committed events into
//  per-execution projections, and `RoomControlPolicy` only decides which
//  REQUEST buttons to render — it never grants authority. Two properties
//  matter most:
//
//  - the fold takes the event with the HIGHEST room_seq as truth regardless
//    of arrival order (the projection sort is canonical);
//  - the open event-kind taxonomy means new authority kinds pass through
//    losslessly and unknown kinds simply contribute no fields.
//

import Foundation
import XCTest
@testable import Conduit

final class RoomExecutionIndexTests: XCTestCase {
    static let roomID = "10000000-0000-4000-8000-0000000000a1"
    static let executionID = "30000000-0000-4000-8000-0000000000f1"

    private func event(
        seq: Int,
        kind: String = "execution.transition",
        payload: [String: AnyCodable] = [:],
        occurredAt: String? = "2026-09-19T09:20:00.000Z"
    ) -> RoomEvent {
        RoomEvent(
            eventID: "evt-\(seq)",
            roomID: Self.roomID,
            roomSeq: seq,
            kind: RoomEventKind(rawValue: kind),
            producer: "hub:i3",
            payload: payload,
            link: [:],
            correlationID: "corr-1",
            causationID: nil,
            taskRef: nil,
            campaignID: nil,
            idempotencyKey: "hub:\(seq)",
            occurredAt: occurredAt,
            createdAt: occurredAt ?? "2026-09-19T09:20:00.000Z"
        )
    }

    // MARK: - Fold semantics

    func testHighestSeqWinsRegardlessOfArrivalOrder() {
        let running = event(seq: 3, payload: [
            "execution_id": .string(Self.executionID), "to_state": .string("running")
        ])
        let paused = event(seq: 7, payload: [
            "execution_id": .string(Self.executionID), "to_state": .string("paused")
        ])
        // Delivered out of order — the fold still resolves to seq 7.
        let projections = RoomExecutionIndex.projections(from: [paused, running])
        XCTAssertEqual(projections.count, 1)
        XCTAssertEqual(projections[0].state, "paused")
        XCTAssertEqual(projections[0].lastSeq, 7)
    }

    func testEventsWithoutExecutionIdentityAreIgnored() {
        let chat = event(seq: 1, kind: "message", payload: ["text": .string("hi")])
        let bound = event(seq: 2, kind: "execution.bound", payload: [
            "execution_id": .string(Self.executionID), "state": .string("queued")
        ])
        let projections = RoomExecutionIndex.projections(from: [chat, bound])
        XCTAssertEqual(projections.count, 1)
        XCTAssertEqual(projections[0].state, "queued")
    }

    func testSubjectTaskAndCorrelationPropagate() {
        // The transition payload names the actor `actor`; the fold carries
        // it as the projection's `subject` — the identity the op record and
        // the Room timeline agree on.
        let transition = event(seq: 5, payload: [
            "execution_id": .string(Self.executionID),
            "to_state": .string("running"),
            "actor": .string("device:hub-credential:cred-7")
        ])
        var withRef = transition
        // RoomEvent is immutable — rebuild with task_ref for this fixture.
        withRef = RoomEvent(
            eventID: transition.eventID, roomID: transition.roomID, roomSeq: transition.roomSeq,
            kind: transition.kind, producer: transition.producer, payload: transition.payload,
            link: transition.link, correlationID: transition.correlationID,
            causationID: transition.causationID, taskRef: "anvil:task-9",
            campaignID: transition.campaignID, idempotencyKey: transition.idempotencyKey,
            occurredAt: transition.occurredAt, createdAt: transition.createdAt
        )
        let projections = RoomExecutionIndex.projections(from: [withRef])
        XCTAssertEqual(projections[0].subject, "device:hub-credential:cred-7")
        XCTAssertEqual(projections[0].taskRef, "anvil:task-9")
        XCTAssertEqual(projections[0].correlationID, "corr-1")
        XCTAssertEqual(projections[0].lastTransitionAt, "2026-09-19T09:20:00.000Z")
    }

    func testServerAdvertisedActionsAreCaptured() {
        let transition = event(seq: 4, payload: [
            "execution_id": .string(Self.executionID),
            "to_state": .string("running"),
            "available_actions": .array([.string("acknowledge"), .string("cancel")])
        ])
        let projections = RoomExecutionIndex.projections(from: [transition])
        XCTAssertEqual(projections[0].advertisedActions, ["acknowledge", "cancel"])
    }

    func testUnknownAuthorityKindsDecodeLosslessly() throws {
        // A kind i3 adds next week must not break decode, persist, or
        // re-encode — and contributes no fields to the fold unless it
        // carries an execution identity.
        let wire = Data(#"""
        {"event_id":"evt-x","room_id":"\#(Self.roomID)","room_seq":9,
         "kind":"sieve.projection.future-variant","producer":"hub:i3",
         "payload":{"execution_id":"\#(Self.executionID)","state":"running"},
         "link":{},"correlation_id":"corr-1","causation_id":null,
         "task_ref":null,"campaign_id":null,"idempotency_key":"hub:9",
         "occurred_at":"2026-09-19T09:25:00.000Z","created_at":"2026-09-19T09:25:01.000Z"}
        """#.utf8)
        let decoded = try JSONDecoder().decode(RoomEvent.self, from: wire)
        XCTAssertEqual(decoded.kind.rawValue, "sieve.projection.future-variant")
        let reencoded = try JSONEncoder().encode(decoded)
        let roundTripped = try JSONDecoder().decode(RoomEvent.self, from: reencoded)
        XCTAssertEqual(roundTripped.kind.rawValue, "sieve.projection.future-variant")
        // It still folds by execution identity.
        let projections = RoomExecutionIndex.projections(from: [decoded])
        XCTAssertEqual(projections.first?.state, "running")
    }

    // MARK: - Presentation policy (frozen §2 preconditions)

    func testActiveExecutionOffersAcknowledgeAndCancel() {
        // Cancel is valid from spawning/running; acknowledge needs only an
        // existing execution. Both render as requests the Hub can deny.
        for state in ["spawning", "running", "tool_wait", "requires_attention"] {
            var projection = RoomExecutionProjection(executionID: Self.executionID, lastSeq: 6)
            projection.state = state
            XCTAssertEqual(
                RoomControlPolicy.candidates(for: projection),
                [.acknowledge, .cancel],
                "state: \(state)"
            )
        }
    }

    func testFailedExecutionOffersRetryAndResume() {
        // retry/resume are valid from failed — 202 `recorded`, queued with
        // the execution authority, never "running again".
        var projection = RoomExecutionProjection(executionID: Self.executionID, lastSeq: 9)
        projection.state = "failed"
        XCTAssertEqual(RoomControlPolicy.candidates(for: projection), [.retry, .resume])
    }

    func testTerminalSucceededOffersNothing() {
        var succeeded = RoomExecutionProjection(executionID: Self.executionID, lastSeq: 9)
        succeeded.state = "succeeded"
        XCTAssertTrue(RoomControlPolicy.candidates(for: succeeded).isEmpty)
        XCTAssertTrue(succeeded.isTerminal)
    }

    func testQueuedExecutionOffersNoPerExecutionControls() {
        // Frozen contract: `start` is a separate manual-run-shaped op with
        // trigger/projectSlug — it is NOT an action on an existing queued
        // execution, so no per-execution buttons render from `queued`.
        var projection = RoomExecutionProjection(executionID: Self.executionID, lastSeq: 1)
        projection.state = "queued"
        XCTAssertTrue(RoomControlPolicy.candidates(for: projection).isEmpty)
    }

    func testServerAdvertisedActionsOverrideTheLocalMap() {
        var projection = RoomExecutionProjection(executionID: Self.executionID, lastSeq: 4)
        projection.state = "running"
        projection.advertisedActions = ["acknowledge"]
        // The authority's advertisement replaces the presentation map.
        XCTAssertEqual(RoomControlPolicy.candidates(for: projection), [.acknowledge])
    }

    func testUnknownStateRendersNoControls() {
        var projection = RoomExecutionProjection(executionID: Self.executionID, lastSeq: 1)
        projection.state = "state_from_the_future"
        // Never imply authority the Hub did not advertise.
        XCTAssertTrue(RoomControlPolicy.candidates(for: projection).isEmpty)
    }

    func testAllFiveRequiredActionsAreNamed() {
        // The frozen V1 op family: five ops, no `pause`.
        XCTAssertEqual(RoomControlAction.resume.rawValue, "resume")
        XCTAssertEqual(RoomControlAction.cancel.rawValue, "cancel")
        XCTAssertEqual(RoomControlAction.retry.rawValue, "retry")
        XCTAssertEqual(RoomControlAction.acknowledge.rawValue, "acknowledge")
        XCTAssertEqual(RoomControlAction.start.rawValue, "start")
        // `start` records under its own op value; the rest record as-is.
        XCTAssertEqual(RoomControlAction.start.recordOpValue, "execution_start")
        XCTAssertEqual(RoomControlAction.cancel.recordOpValue, "cancel")
        XCTAssertTrue(RoomControlAction.cancel.isDestructive)
        XCTAssertFalse(RoomControlAction.resume.isDestructive)
        // RawRepresentable round-trips unknown future ops for diagnostics —
        // they just never become candidate UI actions.
        XCTAssertEqual(RoomControlAction(rawValue: "pause").rawValue, "pause")
    }
}
