//
//  RoomHubAdmissionTests.swift
//  ConduitTests
//
//  D12 admission contract: a Room Hub session is admitted ONLY after the
//  Hub proves both typed contract surfaces — the Room projection
//  (GET /api/v1/rooms → RoomList) and the control plane
//  (GET /api/v1/controls/operations → ControlOperationList). A bare HTTP
//  200, an off-contract payload, a rejected credential, a missing scope,
//  or a dead seam each reject with their own typed error and leave the
//  credential store untouched.
//

import XCTest
@testable import Conduit

/// In-memory credential backend — the unsigned test host has no Keychain
/// entitlements; same seam the store's own tests use.
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

/// Scripted Hub for admission probes. Routes on path; records requests so
/// tests can prove probe order, headers, and that a rejected early probe
/// prevents later ones from firing at all.
private final class AdmissionHub {
    struct RecordedRequest {
        let method: String
        let path: String
        let query: String?
        let authorization: String?
    }

    var requests: [RecordedRequest] = []
    /// path → (status, body). Unmatched paths 500 — a test that hits an
    /// unexpected route fails loudly rather than falling through.
    var routes: [String: (Int, Data)] = [:]
    var transportError: Error?

    var transport: RoomTransport {
        RoomTransport { request in
            guard let url = request.url else { throw URLError(.badURL) }
            self.requests.append(RecordedRequest(
                method: request.httpMethod ?? "",
                path: url.path(percentEncoded: true),
                query: url.query,
                authorization: request.value(forHTTPHeaderField: "Authorization")
            ))
            if let transportError = self.transportError { throw transportError }
            let (status, payload) = self.routes[url.path] ?? (500, Data())
            return (
                payload,
                HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
            )
        }
    }
}

final class RoomHubAdmissionTests: XCTestCase {
    private var hub: AdmissionHub!
    private var backend: InMemoryRoomHubBackend!
    private var store: RoomHubCredentialStore!
    private let dashboardID = UUID()
    private let credential = RoomHubCredential(hubBaseURL: "https://hub.test", token: "room-token")
    private let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUp() {
        super.setUp()
        hub = AdmissionHub()
        backend = InMemoryRoomHubBackend()
        store = RoomHubCredentialStore(backend: backend)
    }

    override func tearDown() {
        hub = nil
        backend = nil
        store = nil
        super.tearDown()
    }

    private func makeValidator() -> RoomHubAdmissionValidator {
        RoomHubAdmissionValidator(transport: hub.transport, clock: { self.fixedNow })
    }

    // MARK: - Admission granted

    func testAdmissionRequiresBothTypedSurfaces() async throws {
        hub.routes["/api/v1/rooms"] = (200, Self.roomsListBody(roomCount: 2))
        hub.routes["/api/v1/controls/operations"] = (200, Self.emptyOperationsBody)

        let report = try await makeValidator().validate(credential: credential)

        XCTAssertEqual(report.roomCount, 2)
        XCTAssertTrue(report.controlSurfaceProven)
        XCTAssertEqual(report.validatedAt, fixedNow)
        XCTAssertEqual(
            hub.requests.map(\.path),
            ["/api/v1/rooms", "/api/v1/controls/operations"],
            "admission must probe projection before control, in that order"
        )
        XCTAssertTrue(
            hub.requests.allSatisfy { $0.authorization == "Bearer room-token" },
            "both probes must carry the narrow Bearer credential"
        )
        XCTAssertEqual(hub.requests[1].query, "limit=1")
    }

    // MARK: - The bare-200 rejections this gate exists for

    func testBare200OnRoomsIsNotAdmission() async throws {
        hub.routes["/api/v1/rooms"] = (200, Data(#"{"ok":true}"#.utf8))
        hub.routes["/api/v1/controls/operations"] = (200, Self.emptyOperationsBody)

        await assertRejection(
            matching: {
                guard case .undecodableContract(let surface, let status, _) = $0 else { return false }
                return surface == .projection && status == 200
            }
        )
        XCTAssertEqual(
            hub.requests.map(\.path),
            ["/api/v1/rooms"],
            "a projection failure must prevent the control probe entirely"
        )
    }

    func testBare200OnControlsIsNotAdmission() async throws {
        hub.routes["/api/v1/rooms"] = (200, Self.roomsListBody(roomCount: 1))
        hub.routes["/api/v1/controls/operations"] = (200, Data("<html>ok</html>".utf8))

        await assertRejection(
            matching: {
                guard case .undecodableContract(let surface, let status, _) = $0 else { return false }
                return surface == .control && status == 200
            }
        )
    }

    // MARK: - Auth-scope rejections stay typed and scoped

    func testUnauthorizedCredentialRejectsSession() async throws {
        hub.routes["/api/v1/rooms"] = (401, Self.problemBody(status: 401, code: "unauthorized"))

        await assertRejection(matching: { $0 == .unauthorized })
        XCTAssertEqual(hub.requests.map(\.path), ["/api/v1/rooms"])
    }

    func testMissingRoomsScopeRejectsNamingScope() async throws {
        hub.routes["/api/v1/rooms"] = (
            403, Self.problemBody(status: 403, code: "insufficient_scope", detail: "needs rooms:read")
        )

        await assertRejection(
            matching: {
                guard case .missingScope(let scope, _) = $0 else { return false }
                return scope == "rooms:read"
            }
        )
    }

    func testMissingControlsScopeRejectsNamingScope() async throws {
        hub.routes["/api/v1/rooms"] = (200, Self.roomsListBody(roomCount: 0))
        hub.routes["/api/v1/controls/operations"] = (
            403, Self.problemBody(status: 403, code: "insufficient_scope", detail: "needs controls:read")
        )

        await assertRejection(
            matching: {
                guard case .missingScope(let scope, _) = $0 else { return false }
                return scope == "controls:read"
            }
        )
    }

    func testCapabilityDeniedOnProjectionRejects() async throws {
        hub.routes["/api/v1/rooms"] = (
            403, Self.problemBody(status: 403, code: "capability_denied", detail: "no room.read grant")
        )

        await assertRejection(
            matching: {
                guard case .capabilityDenied(let surface, _) = $0 else { return false }
                return surface == .projection
            }
        )
    }

    func testCapabilityDeniedOnControlRejects() async throws {
        hub.routes["/api/v1/rooms"] = (200, Self.roomsListBody(roomCount: 0))
        hub.routes["/api/v1/controls/operations"] = (
            403, Self.problemBody(status: 403, code: "control_capability_denied", detail: "no control grant")
        )

        await assertRejection(
            matching: {
                guard case .capabilityDenied(let surface, _) = $0 else { return false }
                return surface == .control
            }
        )
    }

    // MARK: - Seam-availability rejections

    func testHubWithoutRoomProjectionRejects() async throws {
        hub.routes["/api/v1/rooms"] = (
            503, Self.problemBody(status: 503, code: "room_projection_unavailable")
        )

        await assertRejection(matching: {
            guard case .projectionUnavailable = $0 else { return false }
            return true
        })
    }

    func testHubWithoutControlPlaneRejects() async throws {
        hub.routes["/api/v1/rooms"] = (200, Self.roomsListBody(roomCount: 0))
        hub.routes["/api/v1/controls/operations"] = (
            503, Self.problemBody(status: 503, code: "control_plane_unavailable")
        )

        await assertRejection(matching: {
            guard case .controlPlaneUnavailable = $0 else { return false }
            return true
        })
    }

    func testUnreachableHubRejects() async throws {
        hub.transportError = URLError(.cannotConnectToHost)

        await assertRejection(matching: {
            guard case .transport = $0 else { return false }
            return true
        })
    }

    func testInsecureRemoteBaseURLRejectsBeforeAnyRequest() async throws {
        let insecure = RoomHubCredential(hubBaseURL: "http://203.0.113.9", token: "room-token")

        await assertRejection(
            credential: insecure,
            matching: { $0 == .invalidBaseURL }
        )
        XCTAssertTrue(hub.requests.isEmpty, "URL-policy failure must issue zero network I/O")
    }

    func testUnexpectedStatusRejects() async throws {
        hub.routes["/api/v1/rooms"] = (500, Self.problemBody(status: 500, code: "internal_error"))

        await assertRejection(matching: {
            guard case .rejected(let surface, let status, _) = $0 else { return false }
            return surface == .projection && status == 500
        })
    }

    // MARK: - The store boundary: persist only after admission

    func testAdmitPersistsCredentialOnlyAfterBothProbes() async throws {
        hub.routes["/api/v1/rooms"] = (200, Self.roomsListBody(roomCount: 1))
        hub.routes["/api/v1/controls/operations"] = (200, Self.emptyOperationsBody)

        let report = try await store.admit(
            credential,
            dashboardID: dashboardID,
            validator: makeValidator()
        )

        XCTAssertEqual(report.roomCount, 1)
        XCTAssertEqual(store.load(dashboardID: dashboardID), credential)
    }

    func testAdmitLeavesStoreUntouchedOnRejection() async throws {
        hub.routes["/api/v1/rooms"] = (401, Self.problemBody(status: 401, code: "unauthorized"))

        await assertRejection(using: {
            _ = try await self.store.admit(
                self.credential,
                dashboardID: self.dashboardID,
                validator: self.makeValidator()
            )
        }, matching: { $0 == .unauthorized })

        XCTAssertNil(
            store.load(dashboardID: dashboardID),
            "a rejected admission must never write the credential"
        )
    }

    func testAdmitLeavesPriorCredentialUntouchedOnRejection() async throws {
        let prior = RoomHubCredential(hubBaseURL: "https://hub-prior.test", token: "prior-token")
        XCTAssertTrue(store.save(prior, dashboardID: dashboardID))
        hub.routes["/api/v1/rooms"] = (
            503, Self.problemBody(status: 503, code: "room_projection_unavailable")
        )

        await assertRejection(using: {
            _ = try await self.store.admit(
                self.credential,
                dashboardID: self.dashboardID,
                validator: self.makeValidator()
            )
        }, matching: {
            guard case .projectionUnavailable = $0 else { return false }
            return true
        })

        XCTAssertEqual(
            store.load(dashboardID: dashboardID), prior,
            "a failed re-admission must not clobber the working credential"
        )
    }

    // MARK: - Helpers

    private func assertRejection(
        credential: RoomHubCredential? = nil,
        using probe: (() async throws -> Void)? = nil,
        matching predicate: (RoomHubAdmissionError) -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let run = probe ?? {
            _ = try await self.makeValidator().validate(
                credential: credential ?? self.credential
            )
        }
        do {
            try await run()
            XCTFail("admission must reject, but it succeeded", file: file, line: line)
        } catch let error as RoomHubAdmissionError {
            XCTAssertTrue(
                predicate(error),
                "unexpected admission rejection: \(error)",
                file: file, line: line
            )
        } catch {
            XCTFail("non-admission error escaped the gate: \(error)", file: file, line: line)
        }
    }

    // MARK: - Fixtures

    private static func roomsListBody(roomCount: Int) -> Data {
        let rooms = (0..<roomCount).map { index in
            """
            {"room_id":"10000000-0000-4000-8000-0000000000a\(index)",
             "project_ref":"anvil/core","status":"active",
             "correlation_id":"10000000-0000-4000-8000-0000000000d1","latest_seq":8,
             "created_at":"2026-09-19T09:00:00.000Z","updated_at":"2026-09-19T09:30:00.000Z"}
            """
        }.joined(separator: ",")
        return Data(#"{"rooms":[\#(rooms)]}"#.utf8)
    }

    private static var emptyOperationsBody: Data {
        Data(#"{"operations":[]}"#.utf8)
    }

    private static func problemBody(status: Int, code: String, detail: String? = nil) -> Data {
        let detailField = detail.map { #""detail":"\#($0)","# } ?? ""
        return Data(#"{"status":\#(status),"code":"\#(code)",\#(detailField)"requestId":"req-1"}"#.utf8)
    }
}
