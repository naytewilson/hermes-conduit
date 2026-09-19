//
//  RoomControlClientTests.swift
//  Conduit
//
//  Fake-transport contract tests for the ANVIL Room CONTROL seam (I4),
//  implementing anvil-i17-i3's published contract
//  (cells/anvil-i17-i3/context/endpoint-contract-i4.md, v1 DRAFT):
//
//    POST /api/v1/executions/{execution_id}/capability-grants
//      {action, ttl_seconds?}                 → 201 CapabilityGrant
//    POST /api/v1/executions/{execution_id}/{action}
//      {grant_id, request_id?}                → 200 ExecutionActionAck
//
//  What is proved here: request shapes (execution and action bound in the
//  PATH, never the body), server-owned grant fields passing through
//  verbatim, the caller idempotency token riding the action call, and the
//  error taxonomy keeping `insufficient_scope` (missing `executions:control`
//  API scope) and `capability_denied` (grant/principal/expiry check failed —
//  including an EXPIRED grant and a subsumed `grant_not_found`) as distinct,
//  never-collapsed failures.
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

    func testGrantRequestPostsActionWithExecutionInPath() async throws {
        hub.handler = { _ in (201, Self.grantBody) }
        let grant = try await makeClient(token: "secret-control-token")
            .requestGrant(action: .resume, executionID: Self.executionID)

        let request = try XCTUnwrap(hub.requests.first)
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(
            request.path,
            "/api/v1/executions/\(Self.executionID)/capability-grants"
        )
        XCTAssertEqual(request.body?["action"]?.stringValue, "resume")
        // The execution is bound in the PATH per contract — the body carries
        // no subject fields.
        XCTAssertNil(request.body?["execution_id"])
        XCTAssertNil(request.body?["room_id"])
        XCTAssertNil(request.body?["ttl_seconds"])

        // The grant is authority-minted: every field passes through verbatim.
        XCTAssertEqual(grant.grantID, Self.grantID)
        XCTAssertEqual(grant.executionID, Self.executionID)
        XCTAssertEqual(grant.action, .resume)
        XCTAssertEqual(grant.principal, "device:hub-credential:cred-7")
        XCTAssertEqual(grant.issuedAt, "2026-09-19T10:00:00.000Z")
        XCTAssertEqual(grant.expiresAt, "2026-09-19T10:05:00.000Z")
        XCTAssertEqual(grant.scopeHash, "9f2c")
    }

    func testGrantRequestCarriesBearerCredential() async throws {
        var captured: URLRequest?
        hub.handler = { request in
            captured = request
            return (201, Self.grantBody)
        }
        _ = try await makeClient(token: "secret-control-token")
            .requestGrant(action: .resume, executionID: Self.executionID)
        XCTAssertEqual(
            captured?.value(forHTTPHeaderField: "Authorization"),
            "Bearer secret-control-token"
        )
    }

    func testStartGrantTargetsQueuedExecutionInPath() async throws {
        // The contract's `start` acts on an existing `queued` execution like
        // every other action — there is no room-scoped mint.
        hub.handler = { _ in (201, Self.startGrantBody) }
        let grant = try await makeClient()
            .requestGrant(action: .start, executionID: Self.executionID)

        let request = try XCTUnwrap(hub.requests.first)
        XCTAssertEqual(
            request.path,
            "/api/v1/executions/\(Self.executionID)/capability-grants"
        )
        XCTAssertEqual(request.body?["action"]?.stringValue, "start")
        XCTAssertEqual(grant.action, .start)
        XCTAssertEqual(grant.executionID, Self.executionID)
    }

    func testGrantRequestCarriesOptionalTTL() async throws {
        hub.handler = { _ in (201, Self.grantBody) }
        _ = try await makeClient()
            .requestGrant(action: .resume, executionID: Self.executionID, ttlSeconds: 120)
        XCTAssertEqual(hub.requests.first?.body?["ttl_seconds"]?.intValue, 120)
    }

    // MARK: - Action request shape

    func testActionRequestBindsGrantByIDAndCarriesRequestID() async throws {
        hub.handler = { _ in (200, Self.ackBody) }
        let ack = try await makeClient().performAction(
            executionID: Self.executionID,
            action: .cancel,
            grantID: Self.grantID,
            requestID: "conduit:dashboard-1:intent-9"
        )

        let request = try XCTUnwrap(hub.requests.first)
        XCTAssertEqual(request.method, "POST")
        // The action verb is the PATH leaf per contract.
        XCTAssertEqual(
            request.path,
            "/api/v1/executions/\(Self.executionID)/cancel"
        )
        XCTAssertEqual(request.body?["grant_id"]?.stringValue, Self.grantID)
        XCTAssertEqual(request.body?["request_id"]?.stringValue, "conduit:dashboard-1:intent-9")
        // Grant material is never constructed client-side — only the
        // server-minted id is referenced.
        XCTAssertNil(request.body?["action"])

        XCTAssertEqual(ack.executionID, Self.executionID)
        XCTAssertEqual(ack.state, "cancelled")
        XCTAssertEqual(ack.roomSeq, 12)
        XCTAssertEqual(ack.eventID, "50000000-0000-4000-8000-0000000000e1")
        XCTAssertFalse(ack.isDuplicateReplay)
    }

    func testDuplicateAckIsRecognized() async throws {
        // Contract: duplicate:true means the same (execution, action, grant)
        // was already committed — room_seq/event_id are the ORIGINAL commit.
        hub.handler = { _ in (200, Self.duplicateAckBody) }
        let ack = try await makeClient().performAction(
            executionID: Self.executionID,
            action: .resume,
            grantID: Self.grantID,
            requestID: "conduit:dashboard-1:intent-9"
        )
        XCTAssertTrue(ack.isDuplicateReplay)
        XCTAssertEqual(ack.roomSeq, 9)
    }

    func testRetryAckCarriesNewExecutionID() async throws {
        // `retry` mints a new attempt; the ack names it.
        hub.handler = { _ in (200, Self.retryAckBody) }
        let ack = try await makeClient().performAction(
            executionID: Self.executionID,
            action: .retry,
            grantID: Self.grantID,
            requestID: "k"
        )
        XCTAssertEqual(ack.retryExecutionID, "30000000-0000-4000-8000-0000000000f2")
        XCTAssertEqual(ack.state, "queued")
    }

    func testExecutionIDAndActionArePathEncoded() async throws {
        hub.handler = { _ in (200, Self.ackBody) }
        _ = try await makeClient().performAction(
            executionID: "../admin",
            action: RoomControlAction(rawValue: "../grant"),
            grantID: Self.grantID,
            requestID: "k"
        )
        // Hostile values encode into single path segments — they can never
        // rewrite the route.
        XCTAssertEqual(
            hub.requests.first?.path,
            "/api/v1/executions/..%2Fadmin/..%2Fgrant"
        )
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
                requestID: "k"
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

    func testGrantNotFoundSubsumesToCapabilityDenied() async throws {
        // Contract: `grant_not_found` is subsumed under capability_denied on
        // the wire — same denial family, never .insufficientScope.
        hub.handler = { _ in
            (403, Self.problemBody(status: 403, code: "grant_not_found", title: "Forbidden"))
        }
        do {
            _ = try await makeClient().performAction(
                executionID: Self.executionID,
                action: .resume,
                grantID: Self.grantID,
                requestID: "k"
            )
            XCTFail("Expected capability_denied")
        } catch let error as RoomControlError {
            guard case .capabilityDenied = error else {
                return XCTFail("Expected .capabilityDenied, got \(error)")
            }
        }
    }

    func testInsufficientScopeStaysDistinctFromCapabilityDenied() async throws {
        for (code, expectDenied) in [("insufficient_scope", false), ("capability_denied", true)] {
            hub.handler = { _ in
                (403, Self.problemBody(status: 403, code: code, title: "Forbidden"))
            }
            do {
                _ = try await makeClient().requestGrant(
                    action: .cancel, executionID: Self.executionID
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
            _ = try await makeClient().requestGrant(action: .resume, executionID: Self.executionID)
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
                grantID: Self.grantID, requestID: "k"
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
        // Contract 409s: `invalid_state` (action can't apply in the current
        // state) and `execution_not_bound` (no authority binding) — both are
        // state conflicts surfaced with the authority's verbatim detail.
        for code in ["invalid_state", "execution_not_bound"] {
            hub.handler = { _ in
                (409, Self.problemBody(
                    status: 409, code: code, title: "Conflict",
                    detail: "execution is cancelled; resume is invalid"
                ))
            }
            do {
                _ = try await makeClient().performAction(
                    executionID: Self.executionID, action: .resume,
                    grantID: Self.grantID, requestID: "k"
                )
                XCTFail("Expected stateConflict for \(code)")
            } catch let error as RoomControlError {
                guard case .stateConflict(let problem) = error else {
                    return XCTFail("Expected .stateConflict, got \(error)")
                }
                XCTAssertEqual(problem.code, code)
            }
        }
    }

    func testInfrastructureUnavailable503() async throws {
        // Contract 503 `infrastructure_unavailable` — the authority seam is
        // unconfigured/unreachable; fail closed.
        hub.handler = { _ in
            (503, Self.problemBody(status: 503, code: "infrastructure_unavailable", title: "Unavailable"))
        }
        do {
            _ = try await makeClient().requestGrant(action: .resume, executionID: Self.executionID)
            XCTFail("Expected infrastructureUnavailable")
        } catch let error as RoomControlError {
            guard case .infrastructureUnavailable = error else {
                return XCTFail("Expected .infrastructureUnavailable, got \(error)")
            }
        }
    }

    func testUndecodableGrantIsATypedFailure() async throws {
        hub.handler = { _ in (201, Data("<html>not json</html>".utf8)) }
        do {
            _ = try await makeClient().requestGrant(action: .resume, executionID: Self.executionID)
            XCTFail("Expected undecodable")
        } catch let error as RoomControlError {
            guard case .undecodable(let status, _) = error else {
                return XCTFail("Expected .undecodable, got \(error)")
            }
            XCTAssertEqual(status, 201)
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
         "principal":"device:hub-credential:cred-7","issued_at":"2026-09-19T10:00:00.000Z",
         "expires_at":"2026-09-19T10:05:00.000Z","scope_hash":"9f2c"}
        """#.utf8)
    }

    private static var startGrantBody: Data {
        Data(#"""
        {"grant_id":"\#(grantID)","execution_id":"\#(executionID)",
         "action":"start","principal":"device:hub-credential:cred-7",
         "issued_at":"2026-09-19T10:00:00.000Z","expires_at":"2026-09-19T10:05:00.000Z",
         "scope_hash":"aa01"}
        """#.utf8)
    }

    private static var ackBody: Data {
        Data(#"""
        {"execution_id":"\#(executionID)","state":"cancelled","substate":null,
         "room_seq":12,"event_id":"50000000-0000-4000-8000-0000000000e1",
         "duplicate":false}
        """#.utf8)
    }

    private static var duplicateAckBody: Data {
        Data(#"""
        {"execution_id":"\#(executionID)","state":"running","substate":null,
         "room_seq":9,"event_id":"50000000-0000-4000-8000-0000000000e0",
         "duplicate":true}
        """#.utf8)
    }

    private static var retryAckBody: Data {
        Data(#"""
        {"execution_id":"\#(executionID)","state":"queued","substate":null,
         "room_seq":13,"event_id":"50000000-0000-4000-8000-0000000000e2",
         "duplicate":false,
         "retry_execution_id":"30000000-0000-4000-8000-0000000000f2"}
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
