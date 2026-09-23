//
//  RoomHubAdmission.swift
//  Conduit
//
//  Typed admission gate for the Room Hub session (D12).
//
//  A credential is admitted ONLY after the Hub proves both contract
//  surfaces end to end through the typed clients:
//
//    GET /api/v1/rooms                → decodes RoomList
//      (projection shape + Bearer accepted + rooms:read scope)
//    GET /api/v1/controls/operations  → decodes ControlOperationList
//      (control plane exists + controls:read scope)
//
//  A bare HTTP 200 admits nothing: the payload must decode into the
//  contract model, and every classified failure (401/403/503, transport,
//  undecodable) rejects the session with its own operator-visible reason.
//  The credential reaches the Keychain only after both probes succeed —
//  see RoomHubCredentialStore.admit, the single admission path.
//
//  Validated scope boundary (recorded honestly): rooms:read and
//  controls:read are proven by these probes. controls:operate can only be
//  proven by an actual op POST — minting a mutation at admission would be
//  a side effect on operator authority, so it stays lazy: the first
//  control perform still surfaces a typed insufficient_scope /
//  capability_denied rejection if the credential lacks it.
//

import Foundation

/// Which contract surface a probe was validating when it failed. Kept in
/// the typed errors so tests and operators can tell a dead projection
/// seam from a dead control seam without parsing message text.
enum RoomHubAdmissionSurface: String, Equatable {
    case projection
    case control
}

/// What a successful admission proves, in operator terms.
struct RoomHubAdmissionReport: Equatable {
    /// Rooms visible to the bound ANVIL subject at admission time.
    let roomCount: Int
    /// GET /controls/operations returned a decodable ControlOperationList —
    /// the control plane exists and the credential holds controls:read.
    let controlSurfaceProven: Bool
    let validatedAt: Date
}

/// Every admission rejection is typed and operator-visible. A session is
/// never admitted silently, on a bare 200, or on a partial probe.
enum RoomHubAdmissionError: LocalizedError, Equatable {
    /// The hub base URL failed the connection URL policy (malformed, or
    /// cleartext to a non-local host).
    case invalidBaseURL
    /// No HTTP response arrived (DNS, TLS, timeout, offline).
    case transport(String)
    /// A response exceeded the safe bound before parsing.
    case oversizedResponse(limit: Int)
    /// 401 — the bearer was rejected outright.
    case unauthorized
    /// 403 `insufficient_scope` — the credential lacks the named API scope.
    case missingScope(scope: String, detail: String?)
    /// 403 `*_capability_denied` — the Hub's bound ANVIL subject lacks the
    /// durable grant. Fixable only Hub-side, never by retrying here.
    case capabilityDenied(surface: RoomHubAdmissionSurface, detail: String?)
    /// 503 — the Hub exposes no Room projection seam (also covers Hub
    /// auth/storage being down for the read path).
    case projectionUnavailable(detail: String?)
    /// 503 — the Hub exposes no ANVIL control plane. The Fabric operator
    /// session requires controls; a read-only Hub is not admissible.
    case controlPlaneUnavailable(detail: String?)
    /// A 2xx answer that did not decode into the contract model — the
    /// bare-200 admission this gate exists to reject.
    case undecodableContract(surface: RoomHubAdmissionSurface, status: Int, detail: String)
    /// Any other non-2xx status/problem.
    case rejected(surface: RoomHubAdmissionSurface, status: Int, detail: String?)
    /// Both probes passed but the Keychain write failed — the session is
    /// still not admitted.
    case persistenceFailed

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL:
            return AppLocalization.string("The Room hub address is invalid.")
        case .transport(let detail):
            return AppLocalization.string("Could not reach the Room hub: \(detail)")
        case .oversizedResponse(let limit):
            return AppLocalization.string("The Room response exceeded \(String(limit)) bytes.")
        case .unauthorized:
            return AppLocalization.string("The Room hub credential was rejected. Sign in again or replace the saved credential.")
        case .missingScope(let scope, let detail):
            return detail ?? AppLocalization.string("The credential lacks the required \(scope) scope. The session was not admitted.")
        case .capabilityDenied(_, let detail):
            return detail ?? AppLocalization.string("The hub's bound ANVIL subject lacks the durable grant required for admission. The session was not admitted.")
        case .projectionUnavailable(let detail):
            return detail ?? AppLocalization.string("This hub does not expose the ANVIL Room projection.")
        case .controlPlaneUnavailable(let detail):
            return detail ?? AppLocalization.string("This hub's control plane is not configured.")
        case .undecodableContract(_, let status, let detail):
            return AppLocalization.string("The Room hub answered HTTP \(String(status)) with an unreadable payload during admission: \(detail)")
        case .rejected(_, let status, let detail):
            return detail ?? AppLocalization.string("The Room hub answered HTTP \(String(status)) during admission. The session was not admitted.")
        case .persistenceFailed:
            return AppLocalization.string("Could not save to the Keychain.")
        }
    }
}

/// Runs the admission probes. Stateless beyond its injected seams — the
/// same transport injection the Room clients use lets tests script the
/// Hub without network.
struct RoomHubAdmissionValidator {
    let transport: RoomTransport
    let cloudflareAccess: CloudflareAccessCredentials?
    let maxResponseBytes: Int
    let clock: () -> Date

    init(
        transport: RoomTransport = .urlSession(),
        cloudflareAccess: CloudflareAccessCredentials? = nil,
        maxResponseBytes: Int = DataURLLimits.maxJSONResponseBytes,
        clock: @escaping () -> Date = Date.init
    ) {
        self.transport = transport
        self.cloudflareAccess = cloudflareAccess
        self.maxResponseBytes = maxResponseBytes
        self.clock = clock
    }

    /// Probes projection first (the session's primary surface), then the
    /// control plane. A failure on EITHER probe rejects the session — the
    /// Fabric operator surface requires rooms AND controls working.
    ///
    /// Throws RoomHubAdmissionError on rejection; CancellationError passes
    /// through untouched (a cancelled probe is not an admission verdict).
    func validate(credential: RoomHubCredential) async throws -> RoomHubAdmissionReport {
        let normalized: String
        do {
            normalized = try ConnectionURLPolicy.normalizedBaseURL(credential.hubBaseURL)
        } catch {
            throw RoomHubAdmissionError.invalidBaseURL
        }
        let scoped = RoomHubCredential(hubBaseURL: normalized, token: credential.token)

        let readClient: RoomProjectionClient
        let controlClient: RoomControlClient
        do {
            readClient = try RoomProjectionClient(
                credential: scoped,
                transport: transport,
                cloudflareAccess: cloudflareAccess,
                maxResponseBytes: maxResponseBytes
            )
            controlClient = try RoomControlClient(
                credential: scoped,
                transport: transport,
                cloudflareAccess: cloudflareAccess,
                maxResponseBytes: maxResponseBytes
            )
        } catch {
            throw RoomHubAdmissionError.invalidBaseURL
        }

        let rooms: RoomList
        do {
            rooms = try await readClient.listRooms()
        } catch let error as RoomProjectionError {
            throw Self.map(error)
        }

        do {
            _ = try await controlClient.listOperations(limit: 1)
        } catch let error as RoomControlError {
            throw Self.map(error)
        }

        return RoomHubAdmissionReport(
            roomCount: rooms.rooms.count,
            controlSurfaceProven: true,
            validatedAt: clock()
        )
    }

    /// Read-probe failures → admission rejections. The client's status/code
    /// classification is preserved: 401 stays a credential problem, 403
    /// keeps scope-vs-grant distinct, 503 keeps seam-vs-infrastructure
    /// distinct.
    private static func map(_ error: RoomProjectionError) -> RoomHubAdmissionError {
        switch error {
        case .missingCredential, .invalidBaseURL:
            return .invalidBaseURL
        case .transport(let detail):
            return .transport(detail)
        case .oversizedResponse(let limit):
            return .oversizedResponse(limit: limit)
        case .undecodable(let status, let detail):
            return .undecodableContract(surface: .projection, status: status, detail: detail)
        case .unauthorized:
            return .unauthorized
        case .insufficientScope(let problem):
            return .missingScope(scope: "rooms:read", detail: problem.detail)
        case .capabilityDenied(let problem):
            return .capabilityDenied(surface: .projection, detail: problem.detail)
        case .projectionUnavailable(let problem),
             .authenticationUnavailable(let problem),
             .infrastructureUnavailable(let problem):
            return .projectionUnavailable(detail: problem.detail)
        case .roomNotFound(let problem):
            return .rejected(surface: .projection, status: problem.status, detail: problem.detail)
        case .problem(let status, let problem):
            return .rejected(surface: .projection, status: status, detail: problem?.detail)
        }
    }

    /// Control-probe failures → admission rejections, same preservation
    /// rule. A Hub without a control plane or a credential without
    /// controls:read cannot admit a Fabric operator session.
    private static func map(_ error: RoomControlError) -> RoomHubAdmissionError {
        switch error {
        case .missingCredential, .invalidBaseURL:
            return .invalidBaseURL
        case .transport(let detail):
            return .transport(detail)
        case .oversizedResponse(let limit):
            return .oversizedResponse(limit: limit)
        case .undecodable(let status, let detail):
            return .undecodableContract(surface: .control, status: status, detail: detail)
        case .unauthorized:
            return .unauthorized
        case .insufficientScope(let problem):
            return .missingScope(scope: "controls:read", detail: problem.detail)
        case .capabilityDenied(let problem):
            return .capabilityDenied(surface: .control, detail: problem.detail)
        case .controlPlaneUnavailable(let problem),
             .infrastructureUnavailable(let problem):
            return .controlPlaneUnavailable(detail: problem.detail)
        case .notFound(let problem):
            return .rejected(surface: .control, status: problem.status, detail: problem.detail)
        case .preconditionFailed(let problem), .idempotencyConflict(let problem):
            return .rejected(surface: .control, status: problem.status, detail: problem.detail)
        case .problem(let status, let problem):
            return .rejected(surface: .control, status: status, detail: problem?.detail)
        }
    }
}

extension RoomHubCredentialStore {
    /// The ONE credential admission path. The Hub must prove both contract
    /// surfaces BEFORE anything reaches the Keychain — a failed probe
    /// leaves the store untouched and the session unadmitted.
    @discardableResult
    func admit(
        _ credential: RoomHubCredential,
        dashboardID: UUID,
        validator: RoomHubAdmissionValidator = RoomHubAdmissionValidator()
    ) async throws -> RoomHubAdmissionReport {
        let report = try await validator.validate(credential: credential)
        guard save(credential, dashboardID: dashboardID) else {
            throw RoomHubAdmissionError.persistenceFailed
        }
        return report
    }
}
