//
//  RoomCenter.swift
//  Conduit
//
//  Session owner for the ANVIL Room surface (I4): it lazily builds the
//  dashboard-scoped Room clients and replay coordinators, publishes the
//  renderable state the Rooms views read, and runs the one allowed mutable
//  flow:
//
//      user intent → biometric step-up → Hub-minted grant → action call
//                  → authority re-read (Room resync)
//
//  Invariants (unchangeable):
//  - NO mutable call happens before a fresh successful biometric step-up;
//    a failed/cancelled step-up ends the intent with zero network I/O;
//  - Conduit never mints grants — `grant_id` is always a server-minted
//    reference returned by POST /executions/{id}/capability-grants;
//  - `request_id` is minted once per INTENT (at confirmation), so a
//    retried intent can never double-apply;
//  - after any accepted action the Room is re-synced from authority — the
//    client never writes its own idea of the new state into the timeline;
//  - APNs is wake-only: a push can trigger a resync + navigation, never a
//    mutation, never an assumed effect;
//  - everything is keyed by dashboard: credentials, replay state, and
//    outcomes for dashboard A can never leak into dashboard B.
//

import Foundation

/// One user-confirmed control intent. `idempotencyKey` is minted once here —
/// retries of this intent reuse it, so reconnects and manual retries cannot
/// duplicate the semantic effect server-side.
struct RoomControlIntent: Equatable, Identifiable {
    let id: UUID
    let dashboardID: UUID
    let roomID: String
    /// The bound execution id — required for every action per the i3
    /// contract (`start` acts on a `queued` execution like the rest).
    let executionID: String
    let action: RoomControlAction
    let idempotencyKey: String
}

/// The outcome of one control intent, for banner rendering. The kinds keep
/// the authority distinctions the contract draws: a denied/expired grant is
/// NEVER the same failure as a bearer without scope.
struct RoomControlOutcome: Equatable, Identifiable {
    enum Kind: Equatable {
        /// The Hub accepted the action; Room resync follows.
        case applied
        /// The intent's idempotency key matched an already-applied action —
        /// a retry that correctly did nothing new.
        case duplicateRejected
        /// Grant/principal/expiry check failed server-side
        /// (`capability_denied`) — including expired grants.
        case capabilityDenied
        /// The bearer lacks the control scope (`insufficient_scope`).
        case insufficientScope
        /// The action is not valid for the execution's current state (409).
        case stateConflict
        /// Biometric step-up failed or was cancelled — nothing was sent.
        case biometricRejected
        /// No Hub credential is saved for this dashboard.
        case unconfigured
        /// The Hub credential was rejected (401).
        case unauthorized
        /// The execution/room no longer exists (404).
        case notFound
        /// This Hub has no mutable control seam (503).
        case controlUnavailable
        /// Transport or contract failure — the Hub may not have run the
        /// action; the next sync reconciles.
        case failed
    }

    let intentID: UUID
    let action: RoomControlAction
    let kind: Kind
    /// The Hub-minted grant's principal, when a grant was issued — the
    /// identity the Room timeline will record for the action.
    let principal: String?
    /// Server detail: ack status or problem detail/code, verbatim.
    let detail: String?
    let at: Date

    var id: UUID { intentID }
}

/// What a Room wake push may carry — routing identity only. A wake can name
/// a room (and optionally the execution it concerns) so the client can
/// resync and open it; the payload is never authority and never triggers a
/// mutation.
struct RoomWakeTarget: Equatable {
    let roomID: String
    let executionID: String?
    /// The dashboard the push was stamped for; nil on legacy unscoped pushes.
    let dashboardID: UUID?

    init(roomID: String, executionID: String? = nil, dashboardID: UUID? = nil) {
        self.roomID = roomID
        self.executionID = executionID
        self.dashboardID = dashboardID
    }
}

@MainActor
final class RoomCenter: ObservableObject {
    static let shared = RoomCenter()

    enum RoomsPhase: Equatable {
        case idle
        case loading
        case loaded
        /// No Hub credential is saved for this dashboard — unconfigured, not
        /// failed. The fix is a credential, not a retry.
        case unconfigured
        case failed(String)
    }

    struct DashboardRoomsState: Equatable {
        var phase: RoomsPhase = .idle
        var rooms: [ProjectedRoom] = []
        var lastError: String?
    }

    /// Rooms list state per dashboard UUID.
    @Published private(set) var dashboardStates: [UUID: DashboardRoomsState] = [:]
    /// Replay projections keyed "dashboardUUID/roomID" — the same scope key
    /// RoomReplayStore uses, so a room id on two hubs can never alias.
    @Published private(set) var projections: [String: RoomReplayCoordinator.Projection] = [:]
    /// Latest outcome per control intent id (bounded — see perform cap).
    @Published private(set) var controlOutcomes: [UUID: RoomControlOutcome] = [:]
    @Published private(set) var inFlightControls: Set<UUID> = []

    private let credentialStore: RoomHubCredentialStore
    private let transport: RoomTransport
    private var replayStore: RoomReplayStore
    private let authenticate: (String) async -> Bool
    private let clock: () -> Date
    private let idempotencyKeyMint: () -> String

    private var readClients: [UUID: RoomProjectionClient] = [:]
    private var controlClients: [UUID: RoomControlClient] = [:]
    private var coordinators: [UUID: RoomReplayCoordinator] = [:]

    init(
        credentialStore: RoomHubCredentialStore = .system,
        transport: RoomTransport = .urlSession(),
        replayStore: RoomReplayStore = RoomReplayStore(),
        authenticate: @escaping (String) async -> Bool = BiometricAuth.authenticate,
        clock: @escaping () -> Date = Date.init,
        idempotencyKeyMint: (() -> String)? = nil
    ) {
        self.credentialStore = credentialStore
        self.transport = transport
        self.replayStore = replayStore
        self.authenticate = authenticate
        self.clock = clock
        self.idempotencyKeyMint = idempotencyKeyMint ?? { UUID().uuidString }
    }

    // MARK: - Read surface

    func roomsState(for dashboardID: UUID) -> DashboardRoomsState {
        dashboardStates[dashboardID] ?? DashboardRoomsState()
    }

    /// The projection a detail view renders. Cold access hydrates from the
    /// durable replay store — this is also the post-relaunch restore path.
    func projection(dashboardID: UUID, roomID: String) -> RoomReplayCoordinator.Projection {
        let key = scopeKey(dashboardID: dashboardID, roomID: roomID)
        if let projection = projections[key] { return projection }
        let restored = coordinator(for: dashboardID)?.projection(for: roomID)
            ?? RoomReplayCoordinator.Projection()
        projections[key] = restored
        return restored
    }

    func refreshRooms(dashboardID: UUID) async {
        var state = roomsState(for: dashboardID)
        state.phase = .loading
        state.lastError = nil
        dashboardStates[dashboardID] = state
        do {
            let list = try await readClient(for: dashboardID).listRooms()
            state.rooms = list.rooms
            state.phase = .loaded
        } catch RoomProjectionError.missingCredential {
            state.phase = .unconfigured
        } catch {
            state.phase = .failed(error.localizedDescription)
            state.lastError = error.localizedDescription
        }
        dashboardStates[dashboardID] = state
    }

    /// One catch-up sync; errors leave the projection `.stale` (the
    /// coordinator already records the failure durably) — the view reads
    /// freshness rather than catching.
    func syncRoom(dashboardID: UUID, roomID: String) async {
        guard let coordinator = coordinator(for: dashboardID) else {
            markProjectionUnconfigured(dashboardID: dashboardID, roomID: roomID)
            return
        }
        _ = coordinator.projection(for: roomID)
        do {
            _ = try await coordinator.sync(roomID: roomID)
        } catch {
            // Projection already carries .stale(reason); mirror it below.
        }
        let key = scopeKey(dashboardID: dashboardID, roomID: roomID)
        projections[key] = coordinator.projection(for: roomID)
    }

    // MARK: - Control surface

    /// Mints the intent for one user-confirmed action — the idempotency key
    /// is born here and reused by every retry of this intent.
    func makeIntent(
        dashboardID: UUID,
        roomID: String,
        executionID: String,
        action: RoomControlAction
    ) -> RoomControlIntent {
        RoomControlIntent(
            id: UUID(),
            dashboardID: dashboardID,
            roomID: roomID,
            executionID: executionID,
            action: action,
            idempotencyKey: "conduit:\(dashboardID.uuidString.lowercased()):\(idempotencyKeyMint())"
        )
    }

    /// The one mutable flow. Order is the contract: biometric step-up FIRST
    /// (a rejected step-up performs zero network I/O), then the Hub-minted
    /// grant, then the action by grant reference, then an authority re-read.
    @discardableResult
    func perform(_ intent: RoomControlIntent) async -> RoomControlOutcome {
        inFlightControls.insert(intent.id)
        defer { inFlightControls.remove(intent.id) }

        let outcome: RoomControlOutcome
        do {
            let client = try controlClient(for: intent.dashboardID)

            let reason = AppLocalization.string("Authorize \(intent.action.rawValue) on this Room")
            guard await authenticate(reason) else {
                outcome = Self.outcome(intent, kind: .biometricRejected, at: clock())
                return record(outcome)
            }
            guard !Task.isCancelled else { throw CancellationError() }

            let grant = try await client.requestGrant(
                action: intent.action,
                executionID: intent.executionID
            )
            let ack = try await client.performAction(
                executionID: grant.executionID,
                action: intent.action,
                grantID: grant.grantID,
                requestID: intent.idempotencyKey
            )
            outcome = Self.outcome(
                intent,
                kind: ack.isDuplicateReplay ? .duplicateRejected : .applied,
                principal: grant.principal,
                detail: ack.state,
                at: clock()
            )
            // Authority re-read: the Room timeline, not the ack, is the
            // record of what the action did.
            await syncRoom(dashboardID: intent.dashboardID, roomID: intent.roomID)
        } catch let error as RoomControlError {
            outcome = Self.outcome(
                intent,
                kind: Self.kind(for: error),
                detail: Self.detail(for: error),
                at: clock()
            )
            // A state conflict means the timeline moved under us — resync so
            // the controls re-render against real state.
            if case .stateConflict = error {
                await syncRoom(dashboardID: intent.dashboardID, roomID: intent.roomID)
            }
        } catch {
            outcome = Self.outcome(
                intent,
                kind: .failed,
                detail: error.localizedDescription,
                at: clock()
            )
        }
        return record(outcome)
    }

    /// APNs wake-only handler: a room push can cause a resync of fresh
    /// authority — and nothing else. It cannot mutate, cannot mint a grant,
    /// and cannot be trusted for content beyond "this room moved".
    func handleWake(_ target: RoomWakeTarget, activeDashboardID: UUID?) async {
        let dashboardID = target.dashboardID ?? activeDashboardID
        guard let dashboardID else { return }
        await syncRoom(dashboardID: dashboardID, roomID: target.roomID)
    }

    /// Drops everything this center holds for a removed dashboard: replay
    /// records (durable) plus cached clients/coordinators and published
    /// state — scoped exactly like the credential record.
    func clearDashboard(_ dashboardID: UUID) {
        replayStore.clearDashboard(dashboardID)
        readClients[dashboardID] = nil
        controlClients[dashboardID] = nil
        coordinators[dashboardID] = nil
        dashboardStates[dashboardID] = nil
        let prefix = "\(dashboardID.uuidString)/"
        projections = projections.filter { !$0.key.hasPrefix(prefix) }
    }

    // MARK: - Private

    private func scopeKey(dashboardID: UUID, roomID: String) -> String {
        RoomReplayStore.recordKey(dashboardID: dashboardID, roomID: roomID)
    }

    private func readClient(for dashboardID: UUID) throws -> RoomProjectionClient {
        if let client = readClients[dashboardID] { return client }
        let client = try RoomProjectionClient.forDashboard(
            dashboardID,
            transport: transport,
            credentialStore: credentialStore
        )
        readClients[dashboardID] = client
        return client
    }

    private func controlClient(for dashboardID: UUID) throws -> RoomControlClient {
        if let client = controlClients[dashboardID] { return client }
        let client = try RoomControlClient.forDashboard(
            dashboardID,
            transport: transport,
            credentialStore: credentialStore
        )
        controlClients[dashboardID] = client
        return client
    }

    private func coordinator(for dashboardID: UUID) -> RoomReplayCoordinator? {
        if let coordinator = coordinators[dashboardID] { return coordinator }
        guard let client = try? readClient(for: dashboardID) else { return nil }
        let coordinator = RoomReplayCoordinator(
            client: client,
            store: replayStore,
            dashboardID: dashboardID
        )
        coordinators[dashboardID] = coordinator
        return coordinator
    }

    private func markProjectionUnconfigured(dashboardID: UUID, roomID: String) {
        let key = scopeKey(dashboardID: dashboardID, roomID: roomID)
        var projection = projections[key] ?? RoomReplayCoordinator.Projection()
        let reason = AppLocalization.string("No Room hub credential is saved for this dashboard.")
        projection.freshness = .stale(reason)
        projection.lastError = reason
        projections[key] = projection
    }

    private func record(_ outcome: RoomControlOutcome) -> RoomControlOutcome {
        controlOutcomes[outcome.intentID] = outcome
        // Bound the outcome log: controls are operator-scale, but the map is
        // still capped so a pathological session cannot grow it.
        if controlOutcomes.count > 64 {
            let sorted = controlOutcomes.values.sorted { $0.at < $1.at }
            for stale in sorted.prefix(controlOutcomes.count - 64) {
                controlOutcomes[stale.intentID] = nil
            }
        }
        return outcome
    }

    private static func outcome(
        _ intent: RoomControlIntent,
        kind: RoomControlOutcome.Kind,
        principal: String? = nil,
        detail: String? = nil,
        at: Date
    ) -> RoomControlOutcome {
        RoomControlOutcome(
            intentID: intent.id,
            action: intent.action,
            kind: kind,
            principal: principal,
            detail: detail,
            at: at
        )
    }

    private static func kind(for error: RoomControlError) -> RoomControlOutcome.Kind {
        switch error {
        case .capabilityDenied: return .capabilityDenied
        case .insufficientScope: return .insufficientScope
        case .stateConflict: return .stateConflict
        case .missingCredential: return .unconfigured
        case .unauthorized: return .unauthorized
        case .notFound: return .notFound
        case .controlUnavailable: return .controlUnavailable
        default: return .failed
        }
    }

    private static func detail(for error: RoomControlError) -> String? {
        switch error {
        case .capabilityDenied(let problem),
             .insufficientScope(let problem),
             .stateConflict(let problem),
             .unauthorized(let problem),
             .notFound(let problem),
             .controlUnavailable(let problem),
             .authenticationUnavailable(let problem),
             .infrastructureUnavailable(let problem):
            return problem.detail ?? problem.code
        case .problem(_, let problem):
            return problem?.detail ?? problem?.code
        default:
            return error.errorDescription
        }
    }
}
