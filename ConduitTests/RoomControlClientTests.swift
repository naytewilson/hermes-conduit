//
//  RoomControlClientTests.swift
//  Conduit
//
//  Fake-transport contract tests for the ANVIL Room CONTROL seam (I4,
//  DESIGN-I1-I7 §5). The fixtures implement the design-doc contract shape
//  pending anvil-i17-i3's published endpoints:
//
//    POST /api/v1/execution-grants            → CapabilityGrant
//    POST /api/v1/executions/{id}/actions     → ExecutionActionAck
//
//  What is proved here: request shapes, server-owned grant fields passing
//  through verbatim, the idempotency key riding the action call, and the
//  error taxonomy keeping `insufficient_scope` (missing API scope) and
//  `capability_denied` (grant/principal/expiry check failed — including an
//  EXPIRED grant) as distinct, never-collapsed failures.
//

import Foundation
import XCTest
@testable import Conduit

/// Scripted Hub for the control seam: records every request (method, path,
/// decoded JSON body) and answers from a programmable handler. Transport-
/// level injection keeps `httpBody` intact — under a URLProtocol the body
/// would already be consumed into a stream.
private final class ScriptedControlHub {
    struct RecordedRequest {
        let method: String
        let path: String
        let body: [String: AnyCodable]?
    }

    var requests: [RecordedRequest] = []
    var handler: (URLRequest) -> (status: Int, body: Data) = { _ in (500, Data()) }

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
            let fixture = self.handler(request)
            let response = HTTPURLResponse(
                url: url, statusCode: fixture.status, httpVersion: "HTTP/1.1", headerFields: nil
            )!
            return (fixture.body, response)
        }
    }
}

final class RoomControlClientTests: XCTestCase {
    static let roomID = "10000000-0000-4000-8000-0000000000a1"
    static let executionID = "30000000-0000-4000-8000-0000000000f1"
    static let grantID = "40000000-0000-4000-8000-0000000000aa"

    private var hub: ScriptedControlHub!

    override func setUp() {
        super.setUp()
        hub = ScriptedControlHub()
    }

    private func makeClient(
        baseURL: String = "https://hub.test",
        token: String = "hub-api-key"
    ) throws -> RoomControlClient {
        try RoomControlClient(
            credential: RoomHubCredential(hubBaseURL: baseURL, token: token),
            transport: hub.transport
        )
    }

    // MARK: - Grant request shape

    func testGrantRequestPostsActionAndExecutionSubject() async throws {
        hub.handler = { _ in (200, Self.grantBody) }
        let grant = try await makeClient(token: "secret-control-token")
            .requestGrant(action: .resume, executionID: Self.executionID, roomID: nil)

        let request = try XCTUnwrap(hub.requests.first)
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.path, "/api/v1/execution-grants")
        XCTAssertEqual(request.body?["action"]?.stringValue, "resume")
        XCTAssertEqual(request.body?["execution_id"]?.stringValue, Self.executionID)
        XCTAssertNil(request.body?["room_id"])

        // The grant is authority-minted: every field passes through verbatim.
        XCTAssertEqual(grant.grantID, Self.grantID)
        XCTAssertEqual(grant.executionID, Self.executionID)
        XCTAssertEqual(grant.action, .resume)
        XCTAssertEqual(grant.principal, "device:nayte-iphone")
        XCTAssertEqual(grant.issuedAt, "2026-09-19T10:00:00.000Z")
        XCTAssertEqual(grant.expiresAt, "2026-09-19T10:05:00.000Z")
        XCTAssertEqual(grant.scopeHash, "sha256:9f2c")
    }

    func testGrantRequestCarriesBearerCredential() async throws {
        var captured: URLRequest?
        hub.handler = { request in
            captured = request
            return (200, Self.grantBody)
        }
        _ = try await makeClient(token: "secret-control-token")
            .requestGrant(action: .resume, executionID: Self.executionID, roomID: nil)
        XCTAssertEqual(
            captured?.value(forHTTPHeaderField: "Authorization"),
            "Bearer secret-control-token"
        )
    }

    func testStartGrantRequestCarriesRoomSubject() async throws {
        hub.handler = { _ in (200, Self.startGrantBody) }
        let grant = try await makeClient()
            .requestGrant(action: .start, executionID: nil, roomID: Self.roomID)

        let request = try XCTUnwrap(hub.requests.first)
        XCTAssertEqual(request.body?["action"]?.stringValue, "start")
        XCTAssertEqual(request.body?["room_id"]?.stringValue, Self.roomID)
        XCTAssertNil(request.body?["execution_id"])
        // Start's execution id is Hub-minted inside the grant — the client
        // never invents one.
        XCTAssertEqual(grant.executionID, "30000000-0000-4000-8000-0000000000ff")
    }

    func testGrantRequestWithNoSubjectFailsClosed() async throws {
        hub.handler = { _ in (200, Self.grantBody) }
        do {
            _ = try await makeClient().requestGrant(action: .resume, executionID: nil, roomID: nil)
            XCTFail("Expected missingSubject")
        } catch let error as RoomControlError {
            guard case .missingSubject = error else {
                return XCTFail("Expected .missingSubject, got \(error)")
            }
        }
        // Fail-closed BEFORE any network I/O.
        XCTAssertTrue(hub.requests.isEmpty)
    }

    // MARK: - Action request shape

    func testActionRequestReferencesGrantByIDAndCarriesIdempotencyKey() async throws {
        hub.handler = { _ in (200, Self.ackBody) }
        let ack = try await makeClient().performAction(
            executionID: Self.executionID,
            action: .cancel,
            grantID: Self.grantID,
            idempotencyKey: "conduit:dashboard-1:intent-9"
        )

        let request = try XCTUnwrap(hub.requests.first)
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.path, "/api/v1/executions/\(Self.executionID)/actions")
        XCTAssertEqual(request.body?["action"]?.stringValue, "cancel")
        XCTAssertEqual(request.body?["grant_id"]?.stringValue, Self.grantID)
        XCTAssertEqual(request.body?["idempotency_key"]?.stringValue, "conduit:dashboard-1:intent-9")
        // Grant material is never constructed client-side — only the
        // server-minted id is referenced.

        XCTAssertEqual(ack.executionID, Self.executionID)
        XCTAssertEqual(ack.action, .cancel)
        XCTAssertEqual(ack.status, "applied")
        XCTAssertEqual(ack.state, "cancelled")
        XCTAssertEqual(ack.roomSeq, 12)
        XCTAssertEqual(ack.correlationID, "10000000-0000-4000-8000-0000000000d1")
        XCTAssertFalse(ack.isDuplicateReplay)
    }

    func testDuplicateRejectedAckIsRecognized() async throws {
        hub.handler = { _ in (200, Self.duplicateAckBody) }
        let ack = try await makeClient().performAction(
            executionID: Self.executionID,
            action: .resume,
            grantID: Self.grantID,
            idempotencyKey: "conduit:dashboard-1:intent-9"
        )
        XCTAssertTrue(ack.isDuplicateReplay)
        XCTAssertEqual(ack.status, "duplicate_rejected")
    }

    func testExecutionIDIsPathEncoded() async throws {
        hub.handler = { _ in (200, Self.ackBody) }
        _ = try await makeClient().performAction(
            executionID: "../admin",
            action: .cancel,
            grantID: Self.grantID,
            idempotencyKey: "k"
        )
        // The hostile id is encoded into ONE path segment — it can never
        // rewrite the route.
        XCTAssertEqual(hub.requests.first?.path, "/api/v1/executions/..%2Fadmin/actions")
    }

    // MARK: - Authority distinctions

    func testExpiredGrantIsCapabilityDeniedNotScope() async throws {
        // THE acceptance distinction: an expired grant returns 403
        // capability_denied, which must surface as .capabilityDenied —
        // never collapsed into .insufficientScope.
        hub.handler = { _ in
            (403, Self.problemBody(
                status: 403,
                code: "capability_denied",
                title: "Forbidden",
                detail: "grant expired at 2026-09-19T10:05:00.000Z"
            ))
        }
        do {
            _ = try await makeClient().performAction(
                executionID: Self.executionID,
                action: .resume,
                grantID: Self.grantID,
                idempotencyKey: "k"
            )
            XCTFail("Expected capability_denied")
        } catch let error as RoomControlError {
            guard case .capabilityDenied(let problem) = error else {
                return XCTFail("Expected .capabilityDenied, got \(error)")
            }
            XCTAssertEqual(problem.code, "capability_denied")
            XCTAssertEqual(problem.detail, "grant expired at 2026-09-19T10:05:00.000Z")
        }
    }

    func testInsufficientScopeStaysDistinctFromCapabilityDenied() async throws {
        for (code, expectDenied) in [("insufficient_scope", false), ("capability_denied", true)] {
            hub.handler = { _ in
                (403, Self.problemBody(status: 403, code: code, title: "Forbidden"))
            }
            do {
                _ = try await makeClient().requestGrant(
                    action: .cancel, executionID: Self.executionID, roomID: nil
                )
                XCTFail("Expected forbidden for \(code)")
            } catch let error as RoomControlError {
                if expectDenied {
                    guard case .capabilityDenied = error else {
                        return XCTFail("Expected .capabilityDenied, got \(error)")
                    }
                } else {
                    guard case .insufficientScope = error else {
                        return XCTFail("Expected .insufficientScope, got \(error)")
                    }
                }
            }
        }
    }

    func testUnauthorized401IsACredentialFailure() async throws {
        hub.handler = { _ in
            (401, Self.problemBody(status: 401, code: "unauthorized", title: "Authentication required"))
        }
        do {
            _ = try await makeClient().requestGrant(action: .resume, executionID: Self.executionID, roomID: nil)
            XCTFail("Expected unauthorized")
        } catch let error as RoomControlError {
            guard case .unauthorized(let problem) = error else {
                return XCTFail("Expected .unauthorized, got \(error)")
            }
            XCTAssertEqual(problem.code, "unauthorized")
        }
    }

    func testExecutionNotFound404() async throws {
        hub.handler = { _ in
            (404, Self.problemBody(status: 404, code: "execution_not_found", title: "Not found"))
        }
        do {
            _ = try await makeClient().performAction(
                executionID: Self.executionID, action: .resume,
                grantID: Self.grantID, idempotencyKey: "k"
            )
            XCTFail("Expected notFound")
        } catch let error as RoomControlError {
            guard case .notFound(let problem) = error else {
                return XCTFail("Expected .notFound, got \(error)")
            }
            XCTAssertEqual(problem.code, "execution_not_found")
        }
    }

    func testStateConflict409() async throws {
        hub.handler = { _ in
            (409, Self.problemBody(
                status: 409, code: "state_conflict", title: "Conflict",
                detail: "execution is cancelled; resume is invalid"
            ))
        }
        do {
            _ = try await makeClient().performAction(
                executionID: Self.executionID, action: .resume,
                grantID: Self.grantID, idempotencyKey: "k"
            )
            XCTFail("Expected stateConflict")
        } catch let error as RoomControlError {
            guard case .stateConflict(let problem) = error else {
                return XCTFail("Expected .stateConflict, got \(error)")
            }
            XCTAssertEqual(problem.code, "state_conflict")
        }
    }

    func testControlUnavailable503() async throws {
        hub.handler = { _ in
            (503, Self.problemBody(status: 503, code: "room_control_unavailable", title: "Unavailable"))
        }
        do {
            _ = try await makeClient().requestGrant(action: .resume, executionID: Self.executionID, roomID: nil)
            XCTFail("Expected controlUnavailable")
        } catch let error as RoomControlError {
            guard case .controlUnavailable = error else {
                return XCTFail("Expected .controlUnavailable, got \(error)")
            }
        }
    }

    func testUndecodableGrantIsATypedFailure() async throws {
        hub.handler = { _ in (200, Data("<html>not json</html>".utf8)) }
        do {
            _ = try await makeClient().requestGrant(action: .resume, executionID: Self.executionID, roomID: nil)
            XCTFail("Expected undecodable")
        } catch let error as RoomControlError {
            guard case .undecodable(let status, _) = error else {
                return XCTFail("Expected .undecodable, got \(error)")
            }
            XCTAssertEqual(status, 200)
        }
    }

    func testNonLocalCleartextHubURLRejected() {
        XCTAssertThrowsError(
            try makeClient(baseURL: "http://hub.example.com")
        ) { error in
            XCTAssertTrue(
                error is ConnectionURLPolicyError,
                "Remote cleartext hub must be rejected by connection policy, got \(error)"
            )
        }
    }

    // MARK: - Fixtures

    private static var grantBody: Data {
        Data(#"""
        {"grant_id":"\#(grantID)","execution_id":"\#(executionID)","action":"resume",
         "principal":"device:nayte-iphone","issued_at":"2026-09-19T10:00:00.000Z",
         "expires_at":"2026-09-19T10:05:00.000Z","scope_hash":"sha256:9f2c"}
        """#.utf8)
    }

    private static var startGrantBody: Data {
        Data(#"""
        {"grant_id":"\#(grantID)","execution_id":"30000000-0000-4000-8000-0000000000ff",
         "action":"start","principal":"device:nayte-iphone",
         "issued_at":"2026-09-19T10:00:00.000Z","expires_at":"2026-09-19T10:05:00.000Z",
         "scope_hash":"sha256:aa01"}
        """#.utf8)
    }

    private static var ackBody: Data {
        Data(#"""
        {"execution_id":"\#(executionID)","action":"cancel","status":"applied",
         "state":"cancelled","room_seq":12,
         "correlation_id":"10000000-0000-4000-8000-0000000000d1",
         "duplicate_rejected":false}
        """#.utf8)
    }

    private static var duplicateAckBody: Data {
        Data(#"""
        {"execution_id":"\#(executionID)","action":"resume","status":"duplicate_rejected",
         "state":"running","room_seq":9,
         "correlation_id":"10000000-0000-4000-8000-0000000000d1",
         "duplicate_rejected":true}
        """#.utf8)
    }

    private static func problemBody(status: Int, code: String, title: String, detail: String? = nil) -> Data {
        var payload: [String: Any] = [
            "type": "https://paseo.sh/problems/\(code.replacingOccurrences(of: "_", with: "-"))",
            "title": title,
            "status": status,
            "code": code,
            "requestId": "req-\(status)"
        ]
        payload["detail"] = detail ?? "detail for \(code)"
        return try! JSONSerialization.data(withJSONObject: payload)
    }
}
