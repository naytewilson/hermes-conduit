//
//  RoomControlClientTests.swift
//  Conduit
//
//  Fake-transport contract tests for the ANVIL Room CONTROL seam (I4),
//  against the FROZEN contract docs/contracts/HUB_CONTROL_CONTRACT_V1.md:
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
//  What is proved here: op paths and bodies (execution bound in the PATH;
//  `idempotencyKey` REQUIRED in every POST body), the camelCase op record
//  decoding, the 200/201/202 success family, same-key replay surfacing as
//  `replayed: true`, and the error taxonomy keeping `insufficient_scope`
//  (missing `controls:operate`/`controls:read` API scope) and
//  `control_capability_denied` (the bound subject's grant check failed) as
//  distinct, never-collapsed failures — plus the frozen conflict vocabulary
//  (`control_precondition_failed`, `idempotency_key_conflict`) and the 503
//  plane/infrastructure split.
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
        let query: String?
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
                query: URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQuery,
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
    static let executionID = "30000000-0000-4000-8000-0000000000f1"
    static let operationID = "60000000-0000-4000-8000-0000000000c1"

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

    // MARK: - Op request shapes

    func testCancelPostsToControlsPathWithIdempotencyKey() async throws {
        hub.handler = { _ in (200, Self.opRecordBody(op: "cancel", status: "applied")) }
        let record = try await makeClient(token: "secret-control-token")
            .cancelExecution(
                executionID: Self.executionID,
                idempotencyKey: "conduit:dash-1:intent-9",
                correlationID: "corr-1"
            )

        let request = try XCTUnwrap(hub.requests.first)
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(
            request.path,
            "/api/v1/controls/executions/\(Self.executionID)/cancel"
        )
        // The execution is bound in the PATH; the body carries the
        // REQUIRED idempotency key and nothing authority-shaped.
        XCTAssertEqual(request.body?["idempotencyKey"]?.stringValue, "conduit:dash-1:intent-9")
        XCTAssertEqual(request.body?["correlationId"]?.stringValue, "corr-1")
        XCTAssertNil(request.body?["grant_id"])
        XCTAssertNil(request.body?["grantId"])
        XCTAssertNil(request.body?["execution_id"])

        // The op record decodes camelCase verbatim.
        XCTAssertEqual(record.operationId, Self.operationID)
        XCTAssertEqual(record.op, "cancel")
        XCTAssertEqual(record.status, .applied)
        XCTAssertFalse(record.isReplay)
        XCTAssertFalse(record.isRecorded)
        XCTAssertEqual(record.idempotencyKey, "conduit:dash-1:intent-9")
        XCTAssertEqual(record.executionId, Self.executionID)
        XCTAssertEqual(record.capability, "control.cancel")
        XCTAssertEqual(record.subject, "device:hub-credential:cred-7")
        XCTAssertEqual(record.correlationId, "corr-1")
        XCTAssertEqual(record.createdAt, "2026-09-19T10:00:00.000Z")
        XCTAssertEqual(record.action, .cancel)
    }

    func testCancelRequestCarriesBearerCredential() async throws {
        var captured: URLRequest?
        hub.handler = { request in
            captured = request
            return (200, Self.opRecordBody(op: "cancel", status: "applied"))
        }
        _ = try await makeClient(token: "secret-control-token")
            .cancelExecution(executionID: Self.executionID, idempotencyKey: "k")
        XCTAssertEqual(
            captured?.value(forHTTPHeaderField: "Authorization"),
            "Bearer secret-control-token"
        )
    }

    func testAcknowledgeCarriesAttentionKind() async throws {
        hub.handler = { _ in (200, Self.opRecordBody(op: "acknowledge", status: "applied")) }
        let record = try await makeClient()
            .acknowledgeAttention(
                executionID: Self.executionID,
                attentionKind: .terminal,
                idempotencyKey: "k-ack"
            )

        let request = try XCTUnwrap(hub.requests.first)
        XCTAssertEqual(
            request.path,
            "/api/v1/controls/executions/\(Self.executionID)/acknowledge"
        )
        XCTAssertEqual(request.body?["attentionKind"]?.stringValue, "terminal")
        XCTAssertEqual(request.body?["idempotencyKey"]?.stringValue, "k-ack")
        XCTAssertEqual(record.op, "acknowledge")
        XCTAssertEqual(record.action, .acknowledge)
    }

    func testRetryReturns202Recorded() async throws {
        hub.handler = { _ in (202, Self.opRecordBody(op: "retry", status: "recorded")) }
        let record = try await makeClient()
            .retryExecution(executionID: Self.executionID, idempotencyKey: "k-retry")

        let request = try XCTUnwrap(hub.requests.first)
        XCTAssertEqual(
            request.path,
            "/api/v1/controls/executions/\(Self.executionID)/retry"
        )
        XCTAssertEqual(request.body?["idempotencyKey"]?.stringValue, "k-retry")
        // 202 is a SUCCESS with deferred effect — the record's status, not
        // the HTTP code, carries the distinction.
        XCTAssertTrue(record.isRecorded)
        XCTAssertEqual(record.status, .recorded)
        XCTAssertFalse(record.isReplay)
    }

    func testStartPostsToStartPathWithTriggerAndProject() async throws {
        hub.handler = { _ in (201, Self.startOpRecordBody) }
        let record = try await makeClient()
            .startApprovedExecution(
                trigger: "nightly-sweep",
                projectSlug: "anvil/core",
                idempotencyKey: "k-start",
                actor: "device:hub-credential:cred-7"
            )

        let request = try XCTUnwrap(hub.requests.first)
        // `start` is NOT an action on an existing execution — it dispatches
        // through the manual-run pipeline at its own path.
        XCTAssertEqual(request.path, "/api/v1/controls/executions/start")
        XCTAssertEqual(request.body?["trigger"]?.stringValue, "nightly-sweep")
        XCTAssertEqual(request.body?["projectSlug"]?.stringValue, "anvil/core")
        XCTAssertEqual(request.body?["idempotencyKey"]?.stringValue, "k-start")
        XCTAssertEqual(request.body?["actor"]?.stringValue, "device:hub-credential:cred-7")

        XCTAssertEqual(record.op, "execution_start")
        XCTAssertEqual(record.status, .applied)
        XCTAssertNil(record.executionId)
        XCTAssertEqual(record.action, .start)
        if case .object(let effectMap) = record.effect {
            XCTAssertEqual(
                effectMap["triggerRunId"]?.stringValue,
                "70000000-0000-4000-8000-0000000000d1"
            )
        } else {
            XCTFail("expected object effect, got \(String(describing: record.effect))")
        }
    }

    func testSameKeyReplayReturns200WithReplayedTrue() async throws {
        // Same key, same op/target: the stored result replays byte-identical.
        hub.handler = { _ in (200, Self.opRecordBody(op: "cancel", status: "applied", replayed: true)) }
        let record = try await makeClient()
            .cancelExecution(executionID: Self.executionID, idempotencyKey: "k-same")
        XCTAssertTrue(record.isReplay)
        XCTAssertEqual(record.status, .applied)
    }

    func testExecutionIDIsPathEncoded() async throws {
        hub.handler = { _ in (200, Self.opRecordBody(op: "cancel", status: "applied")) }
        _ = try await makeClient()
            .cancelExecution(executionID: "../admin", idempotencyKey: "k")
        // Hostile values encode into single path segments — they can never
        // rewrite the route.
        XCTAssertEqual(
            hub.requests.first?.path,
            "/api/v1/controls/executions/..%2Fadmin/cancel"
        )
    }

    // MARK: - Operation lookup / list

    func testGetOperationFetchesOpRecord() async throws {
        hub.handler = { _ in (200, Self.opRecordBody(op: "retry", status: "applied")) }
        let record = try await makeClient().getOperation(operationID: Self.operationID)

        let request = try XCTUnwrap(hub.requests.first)
        XCTAssertEqual(request.method, "GET")
        XCTAssertEqual(
            request.path,
            "/api/v1/controls/operations/\(Self.operationID)"
        )
        XCTAssertNil(request.body)
        XCTAssertEqual(record.operationId, Self.operationID)
    }

    func testListOperationsEncodesFilters() async throws {
        hub.handler = { _ in (200, Self.opListBody) }
        let list = try await makeClient().listOperations(
            executionID: Self.executionID,
            status: .applied,
            limit: 50
        )

        let request = try XCTUnwrap(hub.requests.first)
        XCTAssertEqual(request.method, "GET")
        XCTAssertEqual(request.path, "/api/v1/controls/operations")
        let query = try XCTUnwrap(request.query)
        XCTAssertTrue(query.contains("executionId=\(Self.executionID)"))
        XCTAssertTrue(query.contains("status=applied"))
        XCTAssertTrue(query.contains("limit=50"))
        XCTAssertEqual(list.operations.count, 2)
        XCTAssertEqual(list.operations[0].operationId, Self.operationID)
    }

    func testListOperationsCannotInjectAdditionalQueryParameters() async throws {
        hub.handler = { _ in (200, Self.opListBody) }
        _ = try await makeClient().listOperations(
            executionID: "exec&status=recorded",
            op: "retry&limit=200",
            status: .applied,
            limit: 5
        )

        let query = try XCTUnwrap(hub.requests.first?.query)
        XCTAssertTrue(query.contains("executionId=exec%26status%3Drecorded"))
        XCTAssertTrue(query.contains("op=retry%26limit%3D200"))
        XCTAssertTrue(query.contains("status=applied"))
        XCTAssertTrue(query.contains("limit=5"))
        XCTAssertEqual(query.components(separatedBy: "&").count, 4)
    }

    // MARK: - Authority distinctions

    func testCapabilityDeniedIsNotScope() async throws {
        // THE acceptance distinction: the Hub instance's bound subject
        // failing its grant check returns 403 `control_capability_denied`,
        // which must surface as .capabilityDenied — never collapsed into
        // .insufficientScope.
        hub.handler = { _ in
            (403, Self.problemBody(
                status: 403,
                code: "control_capability_denied",
                title: "Forbidden",
                detail: "subject lacks control.cancel grant"
            ))
        }
        do {
            _ = try await makeClient()
                .cancelExecution(executionID: Self.executionID, idempotencyKey: "k")
            XCTFail("Expected control_capability_denied")
        } catch let error as RoomControlError {
            guard case .capabilityDenied(let problem) = error else {
                return XCTFail("Expected .capabilityDenied, got \(error)")
            }
            XCTAssertEqual(problem.code, "control_capability_denied")
            XCTAssertEqual(problem.detail, "subject lacks control.cancel grant")
        }
    }

    func testInsufficientScopeStaysDistinctFromCapabilityDenied() async throws {
        for (code, expectDenied) in [("insufficient_scope", false), ("control_capability_denied", true)] {
            hub.handler = { _ in
                (403, Self.problemBody(status: 403, code: code, title: "Forbidden"))
            }
            do {
                _ = try await makeClient()
                    .cancelExecution(executionID: Self.executionID, idempotencyKey: "k")
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
            _ = try await makeClient()
                .cancelExecution(executionID: Self.executionID, idempotencyKey: "k")
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
            _ = try await makeClient()
                .retryExecution(executionID: Self.executionID, idempotencyKey: "k")
            XCTFail("Expected notFound")
        } catch let error as RoomControlError {
            guard case .notFound(let problem) = error else {
                return XCTFail("Expected .notFound, got \(error)")
            }
            XCTAssertEqual(problem.code, "execution_not_found")
        }
    }

    func testConflict409sStayDistinct() async throws {
        // The 409 family splits: `control_precondition_failed` (the target
        // exists but is not actionable — verbatim from the authority) vs
        // `idempotency_key_conflict` (the key is already bound to a
        // DIFFERENT op/target — fail closed, never assume the replay).
        for (code, detail, check) in [
            ("control_precondition_failed",
             "execution is cancelled; resume is invalid",
             { (e: RoomControlError) in
                 if case .preconditionFailed(let p) = e { return p.code == "control_precondition_failed" }
                 return false
             }),
            ("idempotency_key_conflict",
             "key bound to op cancel on 30000000-0000-4000-8000-0000000000f1",
             { (e: RoomControlError) in
                 if case .idempotencyConflict(let p) = e { return p.code == "idempotency_key_conflict" }
                 return false
             }),
        ] {
            hub.handler = { _ in
                (409, Self.problemBody(status: 409, code: code, title: "Conflict", detail: detail))
            }
            do {
                _ = try await makeClient()
                    .resumeExecution(executionID: Self.executionID, idempotencyKey: "k")
                XCTFail("Expected 409 for \(code)")
            } catch let error as RoomControlError {
                XCTAssertTrue(check(error), "Wrong 409 mapping for \(code): \(error)")
            }
        }
    }

    func testControlPlaneAndInfrastructure503StayDistinct() async throws {
        // The 503 family splits: `control_plane_unavailable` (this Hub's
        // Room seam is unconfigured) vs `infrastructure_unavailable`
        // (Hub auth/storage down).
        for (code, check) in [
            ("control_plane_unavailable", { (e: RoomControlError) in
                if case .controlPlaneUnavailable = e { return true }; return false
            }),
            ("infrastructure_unavailable", { (e: RoomControlError) in
                if case .infrastructureUnavailable = e { return true }; return false
            }),
        ] {
            hub.handler = { _ in
                (503, Self.problemBody(status: 503, code: code, title: "Unavailable"))
            }
            do {
                _ = try await makeClient()
                    .cancelExecution(executionID: Self.executionID, idempotencyKey: "k")
                XCTFail("Expected 503 for \(code)")
            } catch let error as RoomControlError {
                XCTAssertTrue(check(error), "Wrong 503 mapping for \(code): \(error)")
            }
        }
    }

    func testUndecodableOpRecordIsATypedFailure() async throws {
        hub.handler = { _ in (200, Data("<html>not json</html>".utf8)) }
        do {
            _ = try await makeClient()
                .cancelExecution(executionID: Self.executionID, idempotencyKey: "k")
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

    private static func opRecordBody(
        op: String,
        status: String,
        replayed: Bool = false
    ) -> Data {
        let replayedField = replayed ? "\"replayed\":true," : ""
        return Data(#"""
        {"operation":{
          "operationId":"\#(operationID)","op":"\#(op)","status":"\#(status)",
          \#(replayedField)"idempotencyKey":"conduit:dash-1:intent-9",
          "executionId":"\#(executionID)","capability":"control.\#(op)",
          "subject":"device:hub-credential:cred-7","correlationId":"corr-1",
          "effect":{"state":"cancelled"},
          "createdAt":"2026-09-19T10:00:00.000Z","updatedAt":"2026-09-19T10:00:01.000Z"
        }}
        """#.utf8)
    }

    private static var startOpRecordBody: Data {
        Data(#"""
        {"operation":{
          "operationId":"\#(operationID)","op":"execution_start","status":"applied",
          "idempotencyKey":"k-start","executionId":null,"capability":"control.execution_start",
          "subject":"device:hub-credential:cred-7","correlationId":null,
          "effect":{"triggerRunId":"70000000-0000-4000-8000-0000000000d1",
                    "providerEventReceiptId":"80000000-0000-4000-8000-0000000000e1"},
          "createdAt":"2026-09-19T10:00:00.000Z","updatedAt":"2026-09-19T10:00:01.000Z"
        }}
        """#.utf8)
    }

    private static var opListBody: Data {
        Data(#"""
        {"operations":[
          {"operationId":"\#(operationID)","op":"cancel","status":"applied",
           "idempotencyKey":"k-1","executionId":"\#(executionID)",
           "capability":"control.cancel","subject":"device:hub-credential:cred-7",
           "correlationId":null,"effect":null,
           "createdAt":"2026-09-19T10:00:00.000Z","updatedAt":"2026-09-19T10:00:01.000Z"},
          {"operationId":"60000000-0000-4000-8000-0000000000c2","op":"retry","status":"recorded",
           "idempotencyKey":"k-2","executionId":"\#(executionID)",
           "capability":"control.retry","subject":"device:hub-credential:cred-7",
           "correlationId":null,"effect":null,
           "createdAt":"2026-09-19T10:01:00.000Z","updatedAt":"2026-09-19T10:01:00.000Z"}
        ]}
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
