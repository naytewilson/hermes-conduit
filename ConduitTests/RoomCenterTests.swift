//
//  RoomCenterTests.swift
//  Conduit
//
//  Orchestration acceptance for the I4 control flow. The scripted Hub
//  answers BOTH seams (H1 reads + I4 mutations) so the test can assert the
//  exact call order and the exact wire traffic each path produces:
//
//    intent → biometric step-up → POST /executions/{id}/capability-grants
//    → POST /executions/{id}/{action} → GET resync (snapshot + replay)
//
//  Wire shapes per anvil-i17-i3's published endpoint-contract-i4.md (v1
//  DRAFT).
//
//  Proved here:
//  - a rejected step-up performs ZERO network I/O (fail closed);
//  - idempotency keys are minted per intent and stable across its retries;
//  - `capability_denied` (expired grant) and `insufficient_scope` surface
//    as different outcome kinds;
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
/// ordering assertions (grant before action, reads only on wake).
private final class CombinedHub {
    struct RecordedRequest {
        let method: String
        let path: String
        let body: [String: AnyCodable]?
    }

    var requests: [RecordedRequest] = []
    /// Route overrides: path → (status, body). Unmatched POSTs 500.
    var postHandler: (String) -> (Int, Data)? = { _ in nil }
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
    static let grantID = "40000000-0000-4000-8000-0000000000aa"

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

    @MainActor private func makeCenter() -> RoomCenter {
        RoomCenter(
            credentialStore: credentialStore,
            transport: hub.transport,
            replayStore: RoomReplayStore(defaults: defaults, storageKey: "test.roomReplay"),
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
            }
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

    func testBiometricRejectionPerformsZeroNetworkIO() async {
        biometricResults = [false]
        hub.postHandler = { _ in (200, Self.grantBody) }
        let center = await makeCenter()
        let intent = await center.makeIntent(
            dashboardID: dashboardID, roomID: Self.roomID,
            executionID: Self.executionID, action: .resume
        )

        let outcome = await center.perform(intent)

        XCTAssertEqual(outcome.kind, .biometricRejected)
        // The ENTIRE mutable flow is gated: not even the grant request ran.
        XCTAssertTrue(hub.requests.isEmpty)
        XCTAssertEqual(biometricReasons.count, 1)
    }

    func testSuccessfulActionOrderGrantThenActionThenResync() async {
        hub.postHandler = { path in
            if path.hasSuffix("/capability-grants") { return (201, Self.grantBody) }
            if path.hasSuffix("/resume") {
                return (200, Self.ackBody(state: "running"))
            }
            return nil
        }
        let center = await makeCenter()
        let intent = await center.makeIntent(
            dashboardID: dashboardID, roomID: Self.roomID,
            executionID: Self.executionID, action: .resume
        )

        let outcome = await center.perform(intent)

        XCTAssertEqual(outcome.kind, .applied)
        XCTAssertEqual(outcome.principal, "device:hub-credential:cred-7")
        XCTAssertEqual(outcome.detail, "running")

        let methods = hub.requests.map { "\($0.method) \($0.path)" }
        // Grant → action → snapshot+events resync. The resync re-reads
        // authority; the client never writes timeline state itself.
        XCTAssertEqual(
            methods[0],
            "POST /api/v1/executions/\(Self.executionID)/capability-grants"
        )
        XCTAssertEqual(
            methods[1],
            "POST /api/v1/executions/\(Self.executionID)/resume"
        )
        XCTAssertTrue(methods.dropFirst(2).allSatisfy { $0.hasPrefix("GET ") })
        XCTAssertEqual(hub.requests[1].body?["request_id"]?.stringValue, intent.idempotencyKey)
    }

    func testRetriedIntentReusesIdempotencyKey() async {
        var actionCalls = 0
        hub.postHandler = { path in
            if path.hasSuffix("/capability-grants") { return (201, Self.grantBody) }
            if path.hasSuffix("/resume") {
                actionCalls += 1
                // First attempt: a 500 — the Hub may not have applied it, so
                // a manual retry of the SAME intent must present the SAME
                // request_id. Second: the Hub reports the dedupe.
                return actionCalls == 1
                    ? (500, Self.problemBody(status: 500, code: "internal_error"))
                    : (200, Self.ackBody(state: "running", duplicate: true))
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
            .filter { $0.method == "POST" && !$0.path.hasSuffix("/capability-grants") }
            .compactMap { $0.body?["request_id"]?.stringValue }
        XCTAssertEqual(actionCalls, 2)
        XCTAssertEqual(actionKeys, [intent.idempotencyKey, intent.idempotencyKey])
        let finalOutcome = await center.controlOutcomes[intent.id]
        XCTAssertEqual(finalOutcome?.kind, .duplicateRejected)
    }

    func testExpiredGrantSurfacesCapabilityDenied() async {
        hub.postHandler = { path in
            if path.hasSuffix("/capability-grants") { return (201, Self.grantBody) }
            return (403, Self.problemBody(status: 403, code: "capability_denied"))
        }
        let center = await makeCenter()
        let intent = await center.makeIntent(
            dashboardID: dashboardID, roomID: Self.roomID,
            executionID: Self.executionID, action: .resume
        )

        let outcome = await center.perform(intent)
        XCTAssertEqual(outcome.kind, .capabilityDenied)
    }

    func testInsufficientScopeSurfacesSeparately() async {
        hub.postHandler = { _ in
            (403, Self.problemBody(status: 403, code: "insufficient_scope"))
        }
        let center = await makeCenter()
        let intent = await center.makeIntent(
            dashboardID: dashboardID, roomID: Self.roomID,
            executionID: Self.executionID, action: .cancel
        )

        let outcome = await center.perform(intent)
        XCTAssertEqual(outcome.kind, .insufficientScope)
        // Denied at the grant request — the action call never ran.
        XCTAssertEqual(hub.postCount, 1)
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

    func testStateConflictTriggersResync() async {
        hub.postHandler = { path in
            if path.hasSuffix("/capability-grants") { return (201, Self.grantBody) }
            return (409, Self.problemBody(status: 409, code: "invalid_state"))
        }
        let center = await makeCenter()
        let intent = await center.makeIntent(
            dashboardID: dashboardID, roomID: Self.roomID,
            executionID: Self.executionID, action: .resume
        )

        let outcome = await center.perform(intent)
        XCTAssertEqual(outcome.kind, .stateConflict)
        // The timeline moved underneath — the client re-reads authority.
        XCTAssertTrue(hub.requests.contains { $0.method == "GET" })
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
    }

    func testWakeWithoutCredentialDoesNotMintAuthority() async {
        let other = UUID()
        let center = await makeCenter()
        await center.handleWake(
            RoomWakeTarget(roomID: Self.roomID, dashboardID: other),
            activeDashboardID: other
        )
        // Unconfigured dashboards fail closed — a wake is not a credential.
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
           "payload":{"execution_id":"\#(executionID)","from_state":"running","to_state":"paused",
                      "substate":null,"reason":"user requested pause",
                      "actor":"device:hub-credential:cred-7","grant_id":"\#(grantID)"},
           "link":{},"correlation_id":"10000000-0000-4000-8000-0000000000d1",
           "causation_id":"paseo:evt-77","task_ref":null,"campaign_id":null,
           "idempotency_key":"hub:91","occurred_at":"2026-09-19T09:20:00.000Z",
           "created_at":"2026-09-19T09:20:01.000Z"}
         ],
         "latest_seq":8,"next_cursor":8,"has_more":false}
        """#.utf8)
    }

    private static var grantBody: Data {
        Data(#"""
        {"grant_id":"\#(grantID)","execution_id":"\#(executionID)","action":"resume",
         "principal":"device:hub-credential:cred-7","issued_at":"2026-09-19T10:00:00.000Z",
         "expires_at":"2026-09-19T10:05:00.000Z","scope_hash":"9f2c"}
        """#.utf8)
    }

    private static func ackBody(state: String, duplicate: Bool = false) -> Data {
        Data(#"""
        {"execution_id":"\#(executionID)","state":"\#(state)","substate":null,
         "room_seq":9,"event_id":"50000000-0000-4000-8000-0000000000e0",
         "duplicate":\#(duplicate)}
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
