//
//  RoomCenterTests.swift
//  Conduit
//
//  Orchestration acceptance for the I4 control flow against the FROZEN
//  contract (docs/contracts/HUB_CONTROL_CONTRACT_V1.md). The scripted Hub
//  answers BOTH seams (H1 reads + I4 mutations) so the test can assert the
//  exact call order and the exact wire traffic each path produces:
//
//    intent → biometric step-up → POST /api/v1/controls/executions/{id}/{op}
//    → (202 recorded? poll GET /api/v1/controls/operations/{opId} → applied)
//    → authority resync (snapshot + replay)
//
//  Proved here:
//  - a rejected step-up performs ZERO network I/O (fail closed);
//  - idempotency keys are minted per intent and stable across its retries;
//  - 202 `recorded` is polled to `applied` (bounded); a never-applying op
//    surfaces as `.recorded` with its operation id, never as applied;
//  - `control_capability_denied` and `insufficient_scope` surface as
//    different outcome kinds;
//  - a successful action triggers an authority re-read (resync), never a
//    client-side timeline write;
//  - APNs wakes resync only — never a POST;
//  - a missing credential fails closed without touching the network.
//

import Foundation
import XCTest
@testable import Conduit

/// In-memory RoomHubCredentialBackend — the unsigned test host has no
/// Keychain entitlements; same seam the seam's own tests use.
private final class InMemoryRoomHubBackend: RoomHubCredentialBackend {
    private var storage: [String: Data] = [:]
    func data(account: String) -> Data? { storage[account] }
    @discardableResult
    func save(_ data: Data, account: String) -> Bool {
        storage[account] = data
        return true
    }
    func delete(account: String) { storage[account] = nil }
}

/// One Hub serving read + control routes; `requests` is the ground truth for
/// ordering assertions (op before resync reads, reads only on wake).
private final class CombinedHub {
    struct RecordedRequest {
        let method: String
        let path: String
        let body: [String: AnyCodable]?
    }

    var requests: [RecordedRequest] = []
    /// Route overrides: path → (status, body). Unmatched POSTs 500.
    var postHandler: (String) -> (Int, Data)? = { _ in nil }
    /// GET /operations/{id} answers in FIFO order (for polling tests).
    var operationPollResponses: [(Int, Data)] = []
    var roomsList: Data
    var snapshot: Data
    var eventPage: Data

    init(roomsList: Data, snapshot: Data, eventPage: Data) {
        self.roomsList = roomsList
        self.snapshot = snapshot
        self.eventPage = eventPage
    }

    var transport: RoomTransport {
        RoomTransport { request in
            guard let url = request.url else { throw URLError(.badURL) }
            let body = request.httpBody
                .flatMap { try? JSONDecoder().decode([String: AnyCodable].self, from: $0) }
            self.requests.append(RecordedRequest(
                method: request.httpMethod ?? "",
                path: url.path(percentEncoded: true),
                body: body
            ))
            let path = url.path
            var status = 200
            var payload = Data()
            if request.httpMethod == "POST" {
                guard let fixture = self.postHandler(path) else {
                    status = 500
                    payload = Data()
                    return (payload, self.response(url: url, status: status))
                }
                status = fixture.0
                payload = fixture.1
            } else if path.contains("/api/v1/controls/operations/") {
                // Polled op records — FIFO so tests script recorded→applied.
                if !self.operationPollResponses.isEmpty {
                    let fixture = self.operationPollResponses.removeFirst()
                    status = fixture.0
                    payload = fixture.1
                } else {
                    status = 404
                    payload = Data()
                }
            } else if path == "/api/v1/rooms" {
                payload = self.roomsList
            } else if path.hasSuffix("/events") {
                payload = self.eventPage
            } else {
                payload = self.snapshot
            }
            return (payload, self.response(url: url, status: status))
        }
    }

    private func response(url: URL, status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
    }

    var postCount: Int { requests.filter { $0.method == "POST" }.count }
    var getCount: Int { requests.filter { $0.method == "GET" }.count }
}

final class RoomCenterTests: XCTestCase {
    static let roomID = "10000000-0000-4000-8000-0000000000a1"
    static let executionID = "30000000-0000-4000-8000-0000000000f1"
    static let operationID = "60000000-0000-4000-8000-0000000000c1"

    private var hub: CombinedHub!
    private var backend: InMemoryRoomHubBackend!
    private var credentialStore: RoomHubCredentialStore!
    private var defaults: UserDefaults!
    private var suiteName: String!
    private let dashboardID = UUID()
    private var biometricResults: [Bool] = []
    private var biometricReasons: [String] = []
    private var mintedKeys: [String] = []

    override func setUp() {
        super.setUp()
        suiteName = "RoomCenterTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        backend = InMemoryRoomHubBackend()
        credentialStore = RoomHubCredentialStore(backend: backend)
        hub = CombinedHub(
            roomsList: Self.roomsListBody,
            snapshot: Self.snapshotBody,
            eventPage: Self.emptyPageBody
        )
        biometricResults = []
        biometricReasons = []
        mintedKeys = []
        credentialStore.save(
            RoomHubCredential(hubBaseURL: "https://hub.test", token: "room-token"),
            dashboardID: dashboardID
        )
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    @MainActor private func makeCenter(
        pollAttempts: Int = 5,
        pollInterval: TimeInterval = 0
    ) -> RoomCenter {
        RoomCenter(
            credentialStore: credentialStore,
            transport: hub.transport,
            replayStore: RoomReplayStore(defaults: defaults, storageKey: "test.roomReplay"),
            controlJournal: RoomControlJournal(defaults: defaults, storageKey: "test.roomControls"),
            authenticate: { [weak self] reason in
                self?.biometricReasons.append(reason)
                return self?.biometricResults.isEmpty == false
                    ? self!.biometricResults.removeFirst()
                    : true
            },
            idempotencyKeyMint: { [weak self] in
                let key = "mint-\(self?.mintedKeys.count ?? 0)"
                self?.mintedKeys.append(key)
                return key
            },
            operationPollMaxAttempts: pollAttempts,
            operationPollInterval: pollInterval
        )
    }

    // MARK: - Read surface

    func testRefreshRoomsLoadsAndCachesPerDashboard() async {
        let center = await makeCenter()
        await center.refreshRooms(dashboardID: dashboardID)

        let state = await center.roomsState(for: dashboardID)
        XCTAssertEqual(state.phase, .loaded)
        XCTAssertEqual(state.rooms.count, 1)
        XCTAssertEqual(state.rooms[0].roomID, Self.roomID)
        XCTAssertEqual(hub.requests.map(\.path), ["/api/v1/rooms"])
    }

    func testRefreshRoomsWithoutCredentialIsUnconfigured() async {
        let other = UUID()
        let center = await makeCenter()
        await center.refreshRooms(dashboardID: other)

        let otherState = await center.roomsState(for: other)
        XCTAssertEqual(otherState.phase, .unconfigured)
        XCTAssertTrue(hub.requests.isEmpty)
    }

    func testSyncRoomAppliesEventsIntoProjection() async {
        hub.eventPage = Self.transitionPageBody
        let center = await makeCenter()
        await center.syncRoom(dashboardID: dashboardID, roomID: Self.roomID)

        let projection = await center.projection(dashboardID: dashboardID, roomID: Self.roomID)
        XCTAssertEqual(projection.freshness, .live)
        XCTAssertEqual(projection.events.count, 1)
        XCTAssertEqual(projection.events[0].kind, .executionTransition)
        XCTAssertEqual(projection.cursor, 8)
    }

    // MARK: - Control flow

    @MainActor
    func testProductionShapeIdempotencyKeyFitsFrozenContractLimit() async {
        let productionUUID = "12345678-1234-1234-1234-123456789abc"
        let center = RoomCenter(
            credentialStore: credentialStore,
            transport: hub.transport,
            replayStore: RoomReplayStore(
                defaults: defaults,
                storageKey: "test.productionShape.roomReplay"
            ),
            controlJournal: RoomControlJournal(
                defaults: defaults,
                storageKey: "test.productionShape.roomControls"
            ),
            authenticate: { _ in true },
            clock: { Date(timeIntervalSince1970: 1_789_813_200) },
            idempotencyKeyMint: { productionUUID },
            operationPollMaxAttempts: 1,
            operationPollInterval: 0
        )
        let intent = await center.makeIntent(
            dashboardID: dashboardID,
            roomID: Self.roomID,
            executionID: Self.executionID,
            action: .cancel
        )

        XCTAssertEqual(intent.idempotencyKey, "conduit:\(productionUUID)")
        XCTAssertLessThanOrEqual(intent.idempotencyKey.utf8.count, 64)
        XCTAssertFalse(intent.idempotencyKey.contains(dashboardID.uuidString.lowercased()))
    }

    func testAmbiguousFailureReusesSameIntentAndKeyAfterRestart() async {
        var posts = 0
        hub.postHandler = { path in
            guard path.hasSuffix("/resume") else { return nil }
            posts += 1
            return posts == 1
                ? (500, Self.problemBody(status: 500, code: "internal_error"))
                : (200, Self.opRecordBody(op: "resume", status: "applied", replayed: true))
        }

        let firstCenter = await makeCenter()
        let first = await firstCenter.makeIntent(
            dashboardID: dashboardID,
            roomID: Self.roomID,
            executionID: Self.executionID,
            action: .resume,
            correlationID: "corr-restart"
        )
        let firstOutcome = await firstCenter.perform(first)
        XCTAssertEqual(firstOutcome.kind, .failed)
        XCTAssertEqual(posts, 1)

        hub.requests = []
        let secondCenter = await makeCenter()
        let recovered = await secondCenter.makeIntent(
            dashboardID: dashboardID,
            roomID: Self.roomID,
            executionID: Self.executionID,
            action: .resume,
            // Correlation is descriptive lineage, not idempotency target
            // identity. Recovery must still reuse the original intent/key if
            // the refreshed projection reports a changed value.
            correlationID: "corr-after-restart"
        )
        XCTAssertEqual(recovered.id, first.id)
        XCTAssertEqual(recovered.idempotencyKey, first.idempotencyKey)
        XCTAssertEqual(recovered.correlationID, "corr-restart")

        let replay = await secondCenter.perform(recovered)
        XCTAssertEqual(replay.kind, .duplicateRejected)
        XCTAssertEqual(posts, 2)
        XCTAssertEqual(
            hub.requests.first?.body?["idempotencyKey"]?.stringValue,
            first.idempotencyKey
        )
        XCTAssertEqual(
            hub.requests.first?.body?["correlationId"]?.stringValue,
            "corr-restart"
        )
    }

    func testRecordedOperationResumesByGETAfterRestartWithoutSecondPOST() async {
        hub.postHandler = { path in
            guard path.hasSuffix("/retry") else { return nil }
            return (202, Self.opRecordBody(op: "retry", status: "recorded"))
        }

        let firstCenter = await makeCenter(pollAttempts: 0)
        let first = await firstCenter.makeIntent(
            dashboardID: dashboardID,
            roomID: Self.roomID,
            executionID: Self.executionID,
            action: .retry,
            correlationID: "corr-recorded"
        )
        let recorded = await firstCenter.perform(first)
        XCTAssertEqual(recorded.kind, .recorded)
        XCTAssertEqual(hub.postCount, 1)

        hub.requests = []
        hub.operationPollResponses = [
            (200, Self.opRecordBody(op: "retry", status: "applied"))
        ]
        let secondCenter = await makeCenter(pollAttempts: 0)
        let recovered = await secondCenter.makeIntent(
            dashboardID: dashboardID,
            roomID: Self.roomID,
            executionID: Self.executionID,
            action: .retry,
            correlationID: "corr-recorded"
        )
        XCTAssertEqual(recovered.id, first.id)
        XCTAssertEqual(recovered.idempotencyKey, first.idempotencyKey)

        let applied = await secondCenter.perform(recovered)
        XCTAssertEqual(applied.kind, .applied)
        XCTAssertEqual(hub.postCount, 0)
        XCTAssertEqual(
            hub.requests.first?.path,
            "/api/v1/controls/operations/\(Self.operationID)"
        )

        let thirdCenter = await makeCenter(pollAttempts: 0)
        let fresh = await thirdCenter.makeIntent(
            dashboardID: dashboardID,
            roomID: Self.roomID,
            executionID: Self.executionID,
            action: .retry,
            correlationID: "corr-recorded"
        )
        XCTAssertNotEqual(fresh.id, first.id)
        XCTAssertNotEqual(fresh.idempotencyKey, first.idempotencyKey)
    }

    func testBiometricRejectionPerformsZeroNetworkIO() async {
        biometricResults = [false]
        let center = await makeCenter()
        let intent = await center.makeIntent(
            dashboardID: dashboardID, roomID: Self.roomID,
            executionID: Self.executionID, action: .resume
        )

        let outcome = await center.perform(intent)

        XCTAssertEqual(outcome.kind, .biometricRejected)
        // The ENTIRE mutable flow is gated: not even the op POST ran.
        XCTAssertTrue(hub.requests.isEmpty)
        XCTAssertEqual(biometricReasons.count, 1)
    }

    func testSuccessfulActionPostsOpThenResyncs() async {
        hub.postHandler = { path in
            if path.hasSuffix("/cancel") {
                return (200, Self.opRecordBody(op: "cancel", status: "applied"))
            }
            return nil
        }
        let center = await makeCenter()
        let intent = await center.makeIntent(
            dashboardID: dashboardID,
            roomID: Self.roomID,
            executionID: Self.executionID,
            action: .cancel,
            correlationID: "corr-control"
        )

        let outcome = await center.perform(intent)

        XCTAssertEqual(outcome.kind, .applied)
        XCTAssertEqual(outcome.subject, "device:hub-credential:cred-7")
        XCTAssertEqual(outcome.detail, Self.operationID)

        let methods = hub.requests.map { "\($0.method) \($0.path)" }
        // Op POST → snapshot+events resync. The resync re-reads authority;
        // the client never writes timeline state itself. No grant-mint call
        // exists on the frozen wire.
        XCTAssertEqual(
            methods[0],
            "POST /api/v1/controls/executions/\(Self.executionID)/cancel"
        )
        XCTAssertFalse(methods.contains { $0.contains("capability-grants") })
        XCTAssertTrue(methods.dropFirst().allSatisfy { $0.hasPrefix("GET ") })
        XCTAssertEqual(hub.requests[0].body?["idempotencyKey"]?.stringValue, intent.idempotencyKey)
        XCTAssertEqual(hub.requests[0].body?["correlationId"]?.stringValue, "corr-control")
    }

    func testRetriedIntentReusesIdempotencyKey() async {
        var actionCalls = 0
        hub.postHandler = { path in
            if path.hasSuffix("/resume") {
                actionCalls += 1
                // First attempt: a 500 — the Hub may not have applied it, so
                // a manual retry of the SAME intent must present the SAME
                // idempotency key. Second: the Hub reports the replay.
                return actionCalls == 1
                    ? (500, Self.problemBody(status: 500, code: "internal_error"))
                    : (200, Self.opRecordBody(op: "resume", status: "applied", replayed: true))
            }
            return nil
        }
        let center = await makeCenter()
        let intent = await center.makeIntent(
            dashboardID: dashboardID, roomID: Self.roomID,
            executionID: Self.executionID, action: .resume
        )

        _ = await center.perform(intent)
        _ = await center.perform(intent)

        let actionKeys = hub.requests
            .filter { $0.method == "POST" }
            .compactMap { $0.body?["idempotencyKey"]?.stringValue }
        XCTAssertEqual(actionCalls, 2)
        XCTAssertEqual(actionKeys, [intent.idempotencyKey, intent.idempotencyKey])
        let finalOutcome = await center.controlOutcomes[intent.id]
        XCTAssertEqual(finalOutcome?.kind, .duplicateRejected)
    }

    func testRecordedOpIsPolledToApplied() async {
        // 202 `recorded`: the op is queued with the execution authority.
        // The center polls GET /operations/{id} until it turns applied.
        hub.postHandler = { path in
            if path.hasSuffix("/retry") {
                return (202, Self.opRecordBody(op: "retry", status: "recorded"))
            }
            return nil
        }
        hub.operationPollResponses = [
            (200, Self.opRecordBody(op: "retry", status: "recorded")),
            (200, Self.opRecordBody(op: "retry", status: "applied")),
        ]
        let center = await makeCenter(pollAttempts: 5)
        let intent = await center.makeIntent(
            dashboardID: dashboardID, roomID: Self.roomID,
            executionID: Self.executionID, action: .retry
        )

        let outcome = await center.perform(intent)

        XCTAssertEqual(outcome.kind, .applied)
        let polls = hub.requests.filter {
            $0.method == "GET" && $0.path == "/api/v1/controls/operations/\(Self.operationID)"
        }
        XCTAssertEqual(polls.count, 2)
    }

    func testRecordedOpThatNeverAppliesSurfacesRecorded() async {
        // The op stays `recorded` through every poll attempt: the outcome
        // is `.recorded` with the operation id — never presented as applied.
        hub.postHandler = { path in
            if path.hasSuffix("/retry") {
                return (202, Self.opRecordBody(op: "retry", status: "recorded"))
            }
            return nil
        }
        hub.operationPollResponses = [
            (200, Self.opRecordBody(op: "retry", status: "recorded")),
            (200, Self.opRecordBody(op: "retry", status: "recorded")),
        ]
        let center = await makeCenter(pollAttempts: 2)
        let intent = await center.makeIntent(
            dashboardID: dashboardID, roomID: Self.roomID,
            executionID: Self.executionID, action: .retry
        )

        let outcome = await center.perform(intent)

        XCTAssertEqual(outcome.kind, .recorded)
        XCTAssertEqual(outcome.detail, Self.operationID)
        let polls = hub.requests.filter {
            $0.method == "GET" && $0.path == "/api/v1/controls/operations/\(Self.operationID)"
        }
        XCTAssertEqual(polls.count, 2)
    }

    func testForbiddenCodesSurfaceSeparately() async {
        // 403 `control_capability_denied` (the bound subject's grant check
        // failed) and `insufficient_scope` (the Bearer lacks the API scope)
        // are different failures — never collapsed.
        for (code, expected) in [
            ("control_capability_denied", RoomControlOutcome.Kind.capabilityDenied),
            ("insufficient_scope", RoomControlOutcome.Kind.insufficientScope),
        ] {
            hub.requests = []
            hub.postHandler = { _ in
                (403, Self.problemBody(status: 403, code: code))
            }
            let center = await makeCenter()
            let intent = await center.makeIntent(
                dashboardID: dashboardID, roomID: Self.roomID,
                executionID: Self.executionID, action: .cancel
            )

            let outcome = await center.perform(intent)
            XCTAssertEqual(outcome.kind, expected, "code: \(code)")
            // Denied at the op POST — nothing else ran.
            XCTAssertEqual(hub.postCount, 1)
        }
    }

    func testPreconditionFailedTriggersResync() async {
        hub.postHandler = { _ in
            (409, Self.problemBody(status: 409, code: "control_precondition_failed"))
        }
        let center = await makeCenter()
        let intent = await center.makeIntent(
            dashboardID: dashboardID, roomID: Self.roomID,
            executionID: Self.executionID, action: .resume
        )

        let outcome = await center.perform(intent)
        XCTAssertEqual(outcome.kind, .preconditionFailed)
        // The timeline moved underneath — the client re-reads authority.
        XCTAssertTrue(hub.requests.contains { $0.method == "GET" })
    }

    func testMissingCredentialFailsClosed() async {
        let other = UUID()
        let center = await makeCenter()
        let intent = await center.makeIntent(
            dashboardID: other, roomID: Self.roomID,
            executionID: Self.executionID, action: .cancel
        )

        let outcome = await center.perform(intent)
        XCTAssertEqual(outcome.kind, .unconfigured)
        XCTAssertTrue(hub.requests.isEmpty)
        // No credential → fail closed before even the biometric prompt.
        XCTAssertTrue(biometricReasons.isEmpty)
    }

    // MARK: - Wake-only

    func testWakeResyncsAndNeverMutates() async {
        let center = await makeCenter()
        await center.handleWake(
            RoomWakeTarget(roomID: Self.roomID, dashboardID: dashboardID),
            activeDashboardID: dashboardID
        )
        XCTAssertFalse(hub.requests.isEmpty)
        XCTAssertEqual(hub.postCount, 0)
        let wakeProjection = await center.projection(dashboardID: dashboardID, roomID: Self.roomID)
        XCTAssertEqual(wakeProjection.freshness, .live)

        // Unconfigured dashboards fail closed — a wake is not a credential.
        hub.requests = []
        let other = UUID()
        await center.handleWake(
            RoomWakeTarget(roomID: Self.roomID, dashboardID: other),
            activeDashboardID: other
        )
        XCTAssertEqual(hub.postCount, 0)
        XCTAssertEqual(hub.getCount, 0)
    }

    // MARK: - Dashboard scoping

    func testDashboardStateIsScopedPerDashboard() async {
        let other = UUID()
        credentialStore.save(
            RoomHubCredential(hubBaseURL: "https://hub.test", token: "other-token"),
            dashboardID: other
        )
        let center = await makeCenter()
        await center.refreshRooms(dashboardID: dashboardID)

        let primary = await center.roomsState(for: dashboardID)
        let secondary = await center.roomsState(for: other)
        XCTAssertEqual(primary.phase, .loaded)
        XCTAssertEqual(secondary.phase, .idle)
    }

    // MARK: - Fixtures

    private static var roomsListBody: Data {
        Data(#"""
        {"rooms":[
          {"room_id":"\#(roomID)","project_ref":"anvil/core","status":"active",
           "correlation_id":"10000000-0000-4000-8000-0000000000d1","latest_seq":8,
           "created_at":"2026-09-19T09:00:00.000Z","updated_at":"2026-09-19T09:30:00.000Z"}
        ]}
        """#.utf8)
    }

    private static var snapshotBody: Data {
        Data(#"""
        {"room":{"room_id":"\#(roomID)","project_ref":"anvil/core","status":"active",
          "correlation_id":"10000000-0000-4000-8000-0000000000d1","latest_seq":8,
          "created_at":"2026-09-19T09:00:00.000Z","updated_at":"2026-09-19T09:30:00.000Z"},
         "participants":[]}
        """#.utf8)
    }

    private static var emptyPageBody: Data {
        Data(#"""
        {"room":{"room_id":"\#(roomID)","project_ref":"anvil/core","status":"active",
          "correlation_id":"10000000-0000-4000-8000-0000000000d1","latest_seq":8,
          "created_at":"2026-09-19T09:00:00.000Z","updated_at":"2026-09-19T09:30:00.000Z"},
         "events":[],"latest_seq":8,"next_cursor":8,"has_more":false}
        """#.utf8)
    }

    /// One `execution.transition` event — the I3 convergence kind — inside
    /// a replay page. Proves the open-taxonomy kind decode end to end.
    private static var transitionPageBody: Data {
        Data(#"""
        {"room":{"room_id":"\#(roomID)","project_ref":"anvil/core","status":"active",
          "correlation_id":"10000000-0000-4000-8000-0000000000d1","latest_seq":8,
          "created_at":"2026-09-19T09:00:00.000Z","updated_at":"2026-09-19T09:30:00.000Z"},
         "events":[
          {"event_id":"20000000-0000-4000-8000-0000000000a9","room_id":"\#(roomID)",
           "room_seq":8,"kind":"execution.transition","producer":"hub:i3",
           "payload":{"execution_id":"\#(executionID)","from_state":"running","to_state":"running",
                      "substate":null,"reason":"still running",
                      "actor":"device:hub-credential:cred-7"},
           "link":{},"correlation_id":"10000000-0000-4000-8000-0000000000d1",
           "causation_id":"paseo:evt-77","task_ref":null,"campaign_id":null,
           "idempotency_key":"hub:91","occurred_at":"2026-09-19T09:20:00.000Z",
           "created_at":"2026-09-19T09:20:01.000Z"}
         ],
         "latest_seq":8,"next_cursor":8,"has_more":false}
        """#.utf8)
    }

    private static func opRecordBody(op: String, status: String, replayed: Bool = false) -> Data {
        let replayedField = replayed ? "\"replayed\":true," : ""
        return Data(#"""
        {"operation":{
          "operationId":"\#(operationID)","op":"\#(op)","status":"\#(status)",
          \#(replayedField)"idempotencyKey":"conduit:dash-1:intent-9",
          "executionId":"\#(executionID)","capability":"control.\#(op)",
          "subject":"device:hub-credential:cred-7","correlationId":null,
          "effect":null,
          "createdAt":"2026-09-19T10:00:00.000Z","updatedAt":"2026-09-19T10:00:01.000Z"
        }}
        """#.utf8)
    }

    private static func problemBody(status: Int, code: String) -> Data {
        Data(#"""
        {"type":"https://paseo.sh/problems/\#(code.replacingOccurrences(of: "_", with: "-"))",
         "title":"\#(code)","status":\#(status),"detail":"detail for \#(code)",
         "code":"\#(code)","requestId":"req-\#(status)"}
        """#.utf8)
    }
}
