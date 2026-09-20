//
//  RoomControlClient.swift
//  Conduit
//
//  Mutable client for the Hub I4 control seam, implemented against the
//  FROZEN contract (docs/contracts/HUB_CONTROL_CONTRACT_V1.md @ a552616):
//
//    POST /api/v1/controls/executions/{executionId}/cancel      → 200 applied
//    POST /api/v1/controls/executions/{executionId}/acknowledge → 200 applied
//    POST /api/v1/controls/executions/{executionId}/retry       → 202 recorded
//    POST /api/v1/controls/executions/{executionId}/resume      → 202 recorded
//    POST /api/v1/controls/executions/start                    → 201 applied
//    GET  /api/v1/controls/operations/{operationId}             → 200 op record
//    GET  /api/v1/controls/operations?executionId?&op?&status?&limit?
//
//  Authority boundary (unchangeable):
//  - Conduit NEVER mints authority — the Hub instance's bound ANVIL subject
//    holds the durable grant; the client sends only transport auth
//    (Bearer + scope: `controls:operate` for POSTs, `controls:read` for
//    GETs). There is no grant-mint endpoint and no grant_id on the wire.
//  - every failure fails closed: a denied capability, a dead transport, or
//    an unreadable response all end as typed errors — never as a retried or
//    assumed effect;
//  - `insufficient_scope` (the Bearer lacks the API scope) stays distinct
//    from `control_capability_denied` (the bound subject's grant check
//    failed) — collapsing them is the exact bug this seam exists to prevent;
//  - 202 `recorded` is a SUCCESS with deferred effect, not an error: the
//    op is durably recorded and projected for the execution authority.
//    The caller polls GET /operations/{operationId} for recorded→applied.
//

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

enum RoomControlError: LocalizedError, Equatable {
    /// The dashboard has no saved Hub credential — the seam is unconfigured,
    /// a different failure than a rejected one.
    case missingCredential
    /// The stored/normalized Hub base URL could not produce a request URL.
    case invalidBaseURL
    /// No HTTP response arrived (DNS, TLS, timeout, offline).
    case transport(String)
    /// The response exceeded the safe bound before parsing.
    case oversizedResponse(limit: Int)
    /// A 2xx answer carried no decodable payload — a contract breach, never
    /// silently nil data.
    case undecodable(status: Int, detail: String)
    /// 401 — Bearer missing, malformed, or revoked.
    case unauthorized(RoomProblem)
    /// 403 `insufficient_scope` — the Bearer lacks the API scope.
    case insufficientScope(RoomProblem)
    /// 403 `control_capability_denied` — the Hub instance's bound ANVIL
    /// subject lacks the durable `control.<op>` grant. Never collapsed into
    /// a scope failure.
    case capabilityDenied(RoomProblem)
    /// 404 `execution_not_found` / `control_operation_not_found`.
    case notFound(RoomProblem)
    /// 409 `control_precondition_failed` — the target exists but is not
    /// actionable (wrong state, or `finish_execution_call` acknowledged
    /// over the public surface).
    case preconditionFailed(RoomProblem)
    /// 409 `idempotency_key_conflict` — the key was reused with a different
    /// op or target. The stored op is NOT the caller's intent; fail closed
    /// and surface the conflict rather than assuming the replay.
    case idempotencyConflict(RoomProblem)
    /// 503 `control_plane_unavailable` — the ANVIL Room seam is
    /// unconfigured on this Hub.
    case controlPlaneUnavailable(RoomProblem)
    /// 503 `infrastructure_unavailable` — Hub auth/storage unavailable.
    case infrastructureUnavailable(RoomProblem)
    /// Any other non-2xx, problem document preserved when decodable.
    case problem(status: Int, problem: RoomProblem?)

    var errorDescription: String? {
        switch self {
        case .missingCredential:
            return AppLocalization.string("No Room hub credential is saved for this dashboard.")
        case .invalidBaseURL:
            return AppLocalization.string("The Room hub address is invalid.")
        case .transport(let detail):
            return AppLocalization.string("Could not reach the Room hub: \(detail)")
        case .oversizedResponse(let limit):
            return AppLocalization.string("The Room response exceeded \(String(limit)) bytes.")
        case .undecodable(let status, let detail):
            return AppLocalization.string("The Room hub answered HTTP \(String(status)) with an unreadable payload: \(detail)")
        case .unauthorized:
            return AppLocalization.string("The Room hub credential was rejected. Sign in again or replace the saved credential.")
        case .insufficientScope(let problem):
            return problem.detail ?? AppLocalization.string("The Room credential lacks the control scope.")
        case .capabilityDenied(let problem):
            return problem.detail ?? AppLocalization.string("The Hub's control capability was denied.")
        case .notFound(let problem):
            return problem.detail ?? AppLocalization.string("The execution or operation does not exist.")
        case .preconditionFailed(let problem):
            return problem.detail ?? AppLocalization.string("The action is not valid for the execution's current state.")
        case .idempotencyConflict(let problem):
            return problem.detail ?? AppLocalization.string("The idempotency key is already bound to a different operation.")
        case .controlPlaneUnavailable(let problem):
            return problem.detail ?? AppLocalization.string("This hub's control plane is not configured.")
        case .infrastructureUnavailable(let problem):
            return problem.detail ?? AppLocalization.string("The Room hub is temporarily unavailable.")
        case .problem(let status, let problem):
            return problem?.detail ?? AppLocalization.string("The Room hub answered HTTP \(String(status)).")
        }
    }
}

/// Typed client for the I4 control operations. It owns request construction
/// and response classification only — biometric step-up, idempotency-key
/// minting, recorded→applied polling, and post-action resync belong to
/// RoomCenter.
struct RoomControlClient {
    static let apiPrefix = "/api/v1/controls"

    let credential: RoomHubCredential
    private let baseURL: String
    private let transport: RoomTransport
    private let cloudflareAccess: CloudflareAccessCredentials?
    private let maxResponseBytes: Int
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    init(
        credential: RoomHubCredential,
        transport: RoomTransport = .urlSession(),
        cloudflareAccess: CloudflareAccessCredentials? = nil,
        maxResponseBytes: Int = DataURLLimits.maxJSONResponseBytes
    ) throws {
        let normalized = try ConnectionURLPolicy.normalizedBaseURL(credential.hubBaseURL)
        self.credential = RoomHubCredential(hubBaseURL: normalized, token: credential.token)
        self.baseURL = normalized
        self.transport = transport
        self.cloudflareAccess = cloudflareAccess
        self.maxResponseBytes = maxResponseBytes
        self.decoder = JSONDecoder()
        self.encoder = JSONEncoder()
    }

    // MARK: - Mutations (scope controls:operate)

    /// POST /executions/{executionId}/cancel → 200 applied.
    func cancelExecution(
        executionID: String,
        idempotencyKey: String,
        correlationID: String? = nil
    ) async throws -> ControlOperationRecord {
        try await postOp(
            "/executions/\(try pathComponent(executionID))/cancel",
            body: TargetedOperationRequest(idempotencyKey: idempotencyKey, correlationId: correlationID)
        )
    }

    /// POST /executions/{executionId}/acknowledge → 200 applied.
    /// `finish_execution_call` is daemon-side only — the Hub answers 409
    /// `control_precondition_failed`; the client surfaces it, never works
    /// around it.
    func acknowledgeAttention(
        executionID: String,
        attentionKind: AttentionKind,
        idempotencyKey: String,
        correlationID: String? = nil
    ) async throws -> ControlOperationRecord {
        try await postOp(
            "/executions/\(try pathComponent(executionID))/acknowledge",
            body: AcknowledgeAttentionRequest(
                attentionKind: attentionKind,
                idempotencyKey: idempotencyKey,
                correlationId: correlationID
            )
        )
    }

    /// POST /executions/{executionId}/retry → 202 recorded. The intent is
    /// durably recorded; the execution authority applies it. Poll
    /// `getOperation` for the recorded→applied transition.
    func retryExecution(
        executionID: String,
        idempotencyKey: String,
        correlationID: String? = nil
    ) async throws -> ControlOperationRecord {
        try await postOp(
            "/executions/\(try pathComponent(executionID))/retry",
            body: TargetedOperationRequest(idempotencyKey: idempotencyKey, correlationId: correlationID)
        )
    }

    /// POST /executions/{executionId}/resume → 202 recorded. Same async
    /// semantics as retry.
    func resumeExecution(
        executionID: String,
        idempotencyKey: String,
        correlationID: String? = nil
    ) async throws -> ControlOperationRecord {
        try await postOp(
            "/executions/\(try pathComponent(executionID))/resume",
            body: TargetedOperationRequest(idempotencyKey: idempotencyKey, correlationId: correlationID)
        )
    }

    /// POST /executions/start → 201 applied. Dispatches through the
    /// manual-run pipeline; the op record's `effect` carries
    /// `{triggerRunId, providerEventReceiptId}`. `actor` defaults server-side
    /// to the calling credential ID when omitted or empty.
    func startApprovedExecution(
        trigger: String,
        projectSlug: String,
        idempotencyKey: String,
        input: AnyCodable? = nil,
        actor: String? = nil,
        expectedVersionId: String? = nil,
        correlationID: String? = nil
    ) async throws -> ControlOperationRecord {
        try await postOp(
            "/executions/start",
            body: StartApprovedExecutionRequest(
                trigger: trigger,
                projectSlug: projectSlug,
                idempotencyKey: idempotencyKey,
                input: input,
                actor: actor,
                expectedVersionId: expectedVersionId,
                correlationId: correlationID
            )
        )
    }

    // MARK: - Reading ops (scope controls:read)

    /// GET /operations/{operationId} → 200 op record. The replayable
    /// projection surface: poll this for recorded→applied transitions.
    func getOperation(operationID: String) async throws -> ControlOperationRecord {
        let response = try await get(
            "/operations/\(try pathComponent(operationID))",
            as: ControlOperationResponse.self
        )
        return response.operation
    }

    /// GET /operations?executionId?&op?&status?&limit? → 200
    /// `{operations: [...]}` ordered by created_at desc. Rebuilds control
    /// history after a restart.
    func listOperations(
        executionID: String? = nil,
        op: String? = nil,
        status: ControlOperationStatus? = nil,
        limit: Int? = nil
    ) async throws -> ControlOperationList {
        var items: [URLQueryItem] = []
        if let executionID { items.append(URLQueryItem(name: "executionId", value: executionID)) }
        if let op { items.append(URLQueryItem(name: "op", value: op)) }
        if let status { items.append(URLQueryItem(name: "status", value: status.rawValue)) }
        if let limit { items.append(URLQueryItem(name: "limit", value: String(max(1, min(limit, 200))))) }
        let query = items.isEmpty ? "" : "?" + items.map { item in
            let value = item.value.map(percentEncodeQueryValue) ?? ""
            return "\(item.name)=\(value)"
        }.joined(separator: "&")
        return try await get("/operations\(query)", as: ControlOperationList.self)
    }

    // MARK: - Request pipeline

    /// POSTs an op body and decodes the op record. 200 (applied), 201
    /// (applied), and 202 (recorded) are all successes — the record's
    /// `status` carries the distinction, never the HTTP code alone.
    private func postOp<Body: Encodable>(
        _ path: String,
        body: Body
    ) async throws -> ControlOperationRecord {
        let request = try makeRequest(path: Self.apiPrefix + path, body: body, method: "POST")
        let (data, response) = try await perform(request)
        guard let http = response as? HTTPURLResponse else {
            throw RoomControlError.transport(AppLocalization.string("No HTTP response"))
        }
        switch http.statusCode {
        case 200, 201, 202:
            do {
                return try decoder.decode(ControlOperationResponse.self, from: data).operation
            } catch {
                throw RoomControlError.undecodable(
                    status: http.statusCode,
                    detail: String(describing: error)
                )
            }
        default:
            throw classifyFailure(status: http.statusCode, data: data)
        }
    }

    private func get<Response: Decodable>(
        _ path: String,
        as type: Response.Type
    ) async throws -> Response {
        let request = try makeRequest(path: Self.apiPrefix + path, body: Optional<String>.none, method: "GET")
        let (data, response) = try await perform(request)
        guard let http = response as? HTTPURLResponse else {
            throw RoomControlError.transport(AppLocalization.string("No HTTP response"))
        }
        guard http.statusCode == 200 else {
            throw classifyFailure(status: http.statusCode, data: data)
        }
        do {
            return try decoder.decode(type, from: data)
        } catch {
            throw RoomControlError.undecodable(
                status: http.statusCode,
                detail: String(describing: error)
            )
        }
    }

    private func makeRequest<Body: Encodable>(path: String, body: Body, method: String) throws -> URLRequest {
        guard let components = URLComponents(string: baseURL + path),
              let url = components.url else {
            throw RoomControlError.invalidBaseURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(credential.token)", forHTTPHeaderField: "Authorization")
        if method == "POST" {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            do {
                request.httpBody = try encoder.encode(body)
            } catch {
                throw RoomControlError.undecodable(
                    status: 0,
                    detail: "request encode failed: \(String(describing: error))"
                )
            }
        }
        // Cloudflare Access service tokens attach only to https/wss requests
        // (applying(to:) enforces that boundary itself).
        if let cloudflareAccess {
            request = cloudflareAccess.applying(to: request)
        }
        return request
    }

    private func perform(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let result: (Data, URLResponse)
        do {
            result = try await transport.send(request)
        } catch let error as RoomControlError {
            throw error
        } catch let error as URLError {
            throw RoomControlError.transport(error.localizedDescription)
        } catch {
            if error is CancellationError { throw error }
            throw RoomControlError.transport(String(describing: error))
        }
        guard result.0.count <= maxResponseBytes else {
            throw RoomControlError.oversizedResponse(limit: maxResponseBytes)
        }
        return result
    }

    /// Status/problem classification is code-first, mirroring the frozen
    /// contract §4: 401 is a credential problem; 403 splits
    /// `insufficient_scope` (missing API scope) from
    /// `control_capability_denied` (the bound subject's grant check failed);
    /// 404 carries the not-found family; 409 splits `control_precondition_failed`
    /// from `idempotency_key_conflict`; 503 splits the control plane from
    /// infrastructure. Distinctions the server draws are preserved end to
    /// end, never collapsed.
    private func classifyFailure(status: Int, data: Data) -> RoomControlError {
        let problem = try? decoder.decode(RoomProblem.self, from: data)
        switch status {
        case 401:
            return .unauthorized(problem ?? Self.fallbackProblem(status: status, code: "unauthorized"))
        case 403:
            switch problem?.code {
            case "control_capability_denied":
                return .capabilityDenied(problem!)
            case "insufficient_scope":
                return .insufficientScope(problem!)
            default:
                return .problem(status: status, problem: problem)
            }
        case 404:
            return .notFound(problem ?? Self.fallbackProblem(status: status, code: "not_found"))
        case 409:
            switch problem?.code {
            case "control_precondition_failed":
                return .preconditionFailed(problem!)
            case "idempotency_key_conflict":
                return .idempotencyConflict(problem!)
            default:
                return .problem(status: status, problem: problem)
            }
        case 503:
            switch problem?.code {
            case "control_plane_unavailable":
                return .controlPlaneUnavailable(problem!)
            case "infrastructure_unavailable":
                return .infrastructureUnavailable(problem!)
            default:
                return .problem(status: status, problem: problem)
            }
        default:
            return .problem(status: status, problem: problem)
        }
    }

    private static func fallbackProblem(status: Int, code: String) -> RoomProblem {
        RoomProblem(
            type: nil,
            title: nil,
            status: status,
            detail: nil,
            code: code,
            requestID: nil
        )
    }

    /// Query values are encoded as RFC 3986 unreserved characters only.
    /// In particular, '&', '=', '+', '#', and '?' may never escape a value
    /// and become new control-plane parameters.
    private func percentEncodeQueryValue(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }

    /// Path parameters are URL-encoded per segment so a malformed execution
    /// id can never rewrite the route.
    private func pathComponent(_ value: String) throws -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#")
        guard let encoded = value.addingPercentEncoding(withAllowedCharacters: allowed),
              !encoded.isEmpty else {
            throw RoomControlError.invalidBaseURL
        }
        return encoded
    }
}

extension RoomControlClient {
    /// Builds the control client for one saved dashboard entirely from its
    /// scoped Keychain records — the SAME dashboard-scoped Room Hub
    /// credential the read seam uses plus the dashboard's own Cloudflare
    /// Access token. No second credential store, no broader token.
    static func forDashboard(
        _ dashboardID: UUID,
        transport: RoomTransport = .urlSession(),
        credentialStore: RoomHubCredentialStore = .system
    ) throws -> RoomControlClient {
        guard let credential = credentialStore.load(dashboardID: dashboardID) else {
            throw RoomControlError.missingCredential
        }
        return try RoomControlClient(
            credential: credential,
            transport: transport,
            cloudflareAccess: KeychainHelper.loadCloudflareAccess(
                dashboardID: dashboardID,
                for: credential.hubBaseURL
            )
        )
    }
}
