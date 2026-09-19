//
//  RoomControlClient.swift
//  Conduit
//
//  Mutable client for the Hub I4 control seam, implemented against
//  anvil-i17-i3's published contract (endpoint-contract-i4.md, v1 DRAFT):
//
//    POST /api/v1/executions/{execution_id}/capability-grants
//      {action, ttl_seconds?}        — mint a grant bound to the execution
//      → 201 CapabilityGrant
//
//    POST /api/v1/executions/{execution_id}/{action}
//      {grant_id, request_id?}       — act on the grant
//      → 200 ExecutionActionAck
//
//  Authority boundary (unchangeable):
//  - Conduit NEVER mints grants — it requests a Hub-minted CapabilityGrant
//    and invokes the action by `grant_id` reference only;
//  - the same dashboard-scoped Hub bearer authenticates the call (no broad
//    bearer bucket, no second credential store);
//  - every failure fails closed: a denied grant, a dead transport, or an
//    unreadable response all end as typed errors — never as a retried or
//    assumed effect;
//  - `insufficient_scope` (the bearer lacks the control scope) stays
//    distinct from `capability_denied` (the grant/principal/expiry check
//    failed) — collapsing them is the exact bug this seam exists to prevent.
//

import Foundation

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
    /// 401 — bearer missing, malformed, or revoked (`unauthorized`).
    case unauthorized(RoomProblem)
    /// 403 `insufficient_scope` — the bearer lacks the control scope.
    case insufficientScope(RoomProblem)
    /// 403 `capability_denied` — grant invalid, expired, or bound to a
    /// different principal/execution. An EXPIRED grant lands here too; it is
    /// never re-mapped into a scope failure.
    case capabilityDenied(RoomProblem)
    /// 404 `execution_not_found` / `room_not_found`.
    case notFound(RoomProblem)
    /// 409 `state_conflict` / `invalid_transition` — the action is not valid
    /// for the execution's current authoritative state.
    case stateConflict(RoomProblem)
    /// 503 `authentication_unavailable` — Hub auth is down; retry later.
    case authenticationUnavailable(RoomProblem)
    /// 503 `infrastructure_unavailable` — Hub storage/auth unavailable.
    case infrastructureUnavailable(RoomProblem)
    /// 503 `room_control_unavailable` — this Hub has no mutable seam.
    case controlUnavailable(RoomProblem)
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
            return problem.detail ?? AppLocalization.string("The capability grant was denied or expired.")
        case .notFound(let problem):
            return problem.detail ?? AppLocalization.string("The execution does not exist.")
        case .stateConflict(let problem):
            return problem.detail ?? AppLocalization.string("The action is not valid for the execution's current state.")
        case .authenticationUnavailable(let problem):
            return problem.detail ?? AppLocalization.string("Room hub authentication is unavailable. Retry later.")
        case .infrastructureUnavailable(let problem):
            return problem.detail ?? AppLocalization.string("The Room hub is temporarily unavailable.")
        case .controlUnavailable(let problem):
            return problem.detail ?? AppLocalization.string("This hub does not expose execution controls.")
        case .problem(let status, let problem):
            return problem?.detail ?? AppLocalization.string("The Room hub answered HTTP \(String(status)).")
        }
    }
}

/// Typed client for the two I4 control operations. It owns request
/// construction and response classification only — biometric step-up,
/// idempotency, and post-action resync belong to RoomCenter.
struct RoomControlClient {
    static let apiPrefix = "/api/v1"

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

    /// Asks the Hub to mint a capability grant for (action, execution) —
    /// `POST /executions/{id}/capability-grants`. The Hub decides whether the
    /// credential-derived principal MAY hold that grant — a denial is
    /// `capability_denied`/`insufficient_scope`, not an empty grant. `start`
    /// acts on an existing `queued` execution like every other action; the
    /// contract has no room-scoped mint.
    func requestGrant(
        action: RoomControlAction,
        executionID: String,
        ttlSeconds: Int? = nil
    ) async throws -> CapabilityGrant {
        let body = ExecutionGrantRequest(action: action, ttlSeconds: ttlSeconds)
        return try await post(
            "\(Self.apiPrefix)/executions/\(try pathComponent(executionID))/capability-grants",
            body: body,
            as: CapabilityGrant.self
        )
    }

    /// Invokes a granted action — `POST /executions/{id}/{action}`. The grant
    /// is referenced by server-minted id only; `requestID` is the caller's
    /// opaque per-intent dedupe token, stable across retries of the same
    /// intent.
    func performAction(
        executionID: String,
        action: RoomControlAction,
        grantID: String,
        requestID: String
    ) async throws -> ExecutionActionAck {
        let body = ExecutionActionRequest(grantID: grantID, requestID: requestID)
        return try await post(
            "\(Self.apiPrefix)/executions/\(try pathComponent(executionID))/\(try pathComponent(action.rawValue))",
            body: body,
            as: ExecutionActionAck.self
        )
    }

    // MARK: - Request pipeline

    private func post<Body: Encodable, Response: Decodable>(
        _ path: String,
        body: Body,
        as type: Response.Type
    ) async throws -> Response {
        let request = try makeRequest(path: path, body: body)
        let (data, response) = try await perform(request)
        guard let http = response as? HTTPURLResponse else {
            throw RoomControlError.transport(AppLocalization.string("No HTTP response"))
        }
        guard (200...299).contains(http.statusCode) else {
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

    private func makeRequest<Body: Encodable>(path: String, body: Body) throws -> URLRequest {
        guard let components = URLComponents(string: baseURL + path),
              let url = components.url else {
            throw RoomControlError.invalidBaseURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(credential.token)", forHTTPHeaderField: "Authorization")
        do {
            request.httpBody = try encoder.encode(body)
        } catch {
            throw RoomControlError.undecodable(
                status: 0,
                detail: "request encode failed: \(String(describing: error))"
            )
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

    /// Status/problem classification is code-first, mirroring the H1 read
    /// seam: 401 `unauthorized` is a credential problem; 403 splits
    /// `insufficient_scope` (missing API scope) from `capability_denied`
    /// (grant check failed — including expired grants); 404 and 409 carry
    /// their own codes; 503 splits three ways. Distinctions the server
    /// draws are preserved end-to-end, never collapsed.
    private func classifyFailure(status: Int, data: Data) -> RoomControlError {
        let problem = try? decoder.decode(RoomProblem.self, from: data)
        switch status {
        case 401:
            return .unauthorized(problem ?? Self.fallbackProblem(status: status, code: "unauthorized"))
        case 403:
            switch problem?.code {
            // `grant_not_found` is subsumed under capability_denied on the
            // wire per the published contract — same denial family.
            case "capability_denied", "grant_not_found":
                return .capabilityDenied(problem!)
            case "insufficient_scope":
                return .insufficientScope(problem!)
            default:
                return .problem(status: status, problem: problem)
            }
        case 404:
            return .notFound(problem ?? Self.fallbackProblem(status: status, code: "not_found"))
        case 409:
            return .stateConflict(problem ?? Self.fallbackProblem(status: status, code: "state_conflict"))
        case 503:
            switch problem?.code {
            case "authentication_unavailable":
                return .authenticationUnavailable(problem!)
            case "infrastructure_unavailable":
                return .infrastructureUnavailable(problem!)
            case "room_control_unavailable", "room_projection_unavailable":
                return .controlUnavailable(problem!)
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
