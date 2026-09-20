//
//  RoomCenter.swift
//  Conduit
//
//  Session owner for the ANVIL Room surface (I4): it lazily builds the
//  dashboard-scoped Room clients and replay coordinators, publishes the
//  renderable state the Rooms views read, and runs the one allowed mutable
//  flow:
//
//      user intent → biometric step-up → POST /api/v1/controls/… (op)
//                  → recorded? poll GET /operations/{id} → applied
//                  → authority re-read (Room resync)
//
//  Invariants (unchangeable):
//  - NO mutable call happens before a fresh successful biometric step-up;
//    a failed/cancelled step-up ends the intent with zero network I/O;
//  - Conduit never holds or presents a capability grant — transport auth
//    (Bearer + scope) is the only client credential; the Hub instance's
//    bound ANVIL subject carries the durable grant server-side;
//  - `idempotencyKey` is minted once per INTENT (at confirmation), so a
//    retried intent can never double-apply; a replayed key surfaces as
//    `.duplicateRejected`, never as a fresh effect;
//  - 202 `recorded` is "authorized and queued with the execution authority",
//    never "the agent is running again" — the center polls the op record
//    until it turns `applied` (bounded) or surfaces `.recorded` with the
//    operation id for the UI to keep watching;
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
/// duplicate the semantic effect server-side. Execution-targeted ops need
/// `executionID`; `acknowledge` additionally needs `attentionKind`; `start`
/// needs `trigger` + `projectSlug` instead of an execution.
struct RoomControlIntent: Codable, Equatable, Identifiable {
    let id: UUID
    let dashboardID: UUID
    let roomID: String
    let executionID: String?
    let action: RoomControlAction
    let attentionKind: AttentionKind?
    let trigger: String?
    let projectSlug: String?
    /// I1 correlation spine passthrough into the Hub control ledger.
    let correlationID: String?
    let idempotencyKey: String
}

/// The outcome of one control intent, for banner rendering. The kinds keep
/// the authority distinctions the contract draws: a denied capability is
/// NEVER the same failure as a Bearer scope problem, and a recorded op is
/// NEVER presented as an applied one.
struct RoomControlOutcome: Equatable, Identifiable {
    enum Kind: Equatable {
        /// The Hub applied the op synchronously; Room resync follows.
        case applied
        /// The op was durably recorded but its effect is owned downstream
        /// (retry/resume → 202). The operation id rides `detail` so the UI
        /// can keep polling.
        case recorded
        /// The intent's idempotency key matched an already-recorded op —
        /// a retry that correctly did nothing new.
        case duplicateRejected
        /// The Hub instance's bound subject lacks the durable capability
        /// (`control_capability_denied`).
        case capabilityDenied
        /// The Bearer lacks the API scope (`insufficient_scope`).
        case insufficientScope
        /// The target exists but is not actionable (409
        /// `control_precondition_failed`).
        case preconditionFailed
        /// The idempotency key is bound to a different op/target (409
        /// `idempotency_key_conflict`) — fail closed, never assume.
        case idempotencyConflict
        /// Biometric step-up failed or was cancelled — nothing was sent.
        case biometricRejected
        /// No Hub credential is saved for this dashboard.
        case unconfigured
        /// The Hub credential was rejected (401).
        case unauthorized
        /// The execution or operation no longer exists (404).
        case notFound
        /// The Hub's control plane is unconfigured (503
        /// `control_plane_unavailable`) or its storage is down
        /// (`infrastructure_unavailable`).
        case controlPlaneUnavailable
        /// The intent was malformed client-side (e.g. `start` without a
        /// trigger) — nothing was sent.
        case invalidIntent
        /// Transport or contract failure — the Hub may not have run the
        /// action; the next sync reconciles.
        case failed
    }

    let intentID: UUID
    let action: RoomControlAction
    let kind: Kind
    /// The bound ANVIL subject that authorized the op (the op record's
    /// `subject`) — the identity the Room timeline will record.
    let subject: String?
    /// Server detail: op status, problem detail/code, or operation id,
    /// verbatim.
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
    private var controlJournal: RoomControlJournal
    private let authenticate: (String) async -> Bool
    private let clock: () -> Date
    private let idempotencyKeyMint: () -> String
    private let operationPollMaxAttempts: Int
    private let operationPollInterval: TimeInterval

    /// Session caches, keyed by dashboard — the same scoping as the
    /// credential store, so dashboard A's clients can never serve B.
    private var readClients: [UUID: RoomProjectionClient] = [:]
    private var controlClients: [UUID: RoomControlClient] = [:]
    private var coordinators: [UUID: RoomReplayCoordinator] = [:]

    init(
        credentialStore: RoomHubCredentialStore = .system,
        transport: RoomTransport = .urlSession(),
        replayStore: RoomReplayStore = RoomReplayStore(),
        controlJournal: RoomControlJournal = RoomControlJournal(),
        authenticate: @escaping (String) async -> Bool = BiometricAuth.authenticate,
        clock: @escaping () -> Date = Date.init,
        idempotencyKeyMint: (() -> String)? = nil,
        operationPollMaxAttempts: Int = 5,
        operationPollInterval: TimeInterval = 1.0
    ) {
        self.credentialStore = credentialStore
        self.transport = transport
        self.replayStore = replayStore
        self.controlJournal = controlJournal
        self.authenticate = authenticate
        self.clock = clock
        self.idempotencyKeyMint = idempotencyKeyMint ?? { UUID().uuidString }
        self.operationPollMaxAttempts = operationPollMaxAttempts
        self.operationPollInterval = operationPollInterval
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
        executionID: String? = nil,
        action: RoomControlAction,
        attentionKind: AttentionKind? = nil,
        trigger: String? = nil,
        projectSlug: String? = nil,
        correlationID: String? = nil
    ) -> RoomControlIntent {
        let candidate = RoomControlIntent(
            id: UUID(),
            dashboardID: dashboardID,
            roomID: roomID,
            executionID: executionID,
            action: action,
            attentionKind: attentionKind,
            trigger: trigger,
            projectSlug: projectSlug,
            correlationID: correlationID,
            // Hub V1 caps idempotencyKey at 64 characters. A UUID plus
            // this short producer prefix is globally collision-resistant.
            idempotencyKey: "conduit:\(idempotencyKeyMint())"
        )
        // Persist before the first possible POST. If the prior process died
        // with the same semantic intent unresolved, recover its exact key.
        return controlJournal.recoverOrInsert(candidate, at: clock())
    }

    /// The one mutable flow. Order is the contract: biometric step-up FIRST
    /// (a rejected step-up performs zero network I/O), then the op POST
    /// with the intent's idempotency key, then — for 202 `recorded` ops — a
    /// bounded poll of the op record until it turns `applied`, then an
    /// authority re-read.
    @discardableResult
    func perform(_ intent: RoomControlIntent) async -> RoomControlOutcome {
        inFlightControls.insert(intent.id)
        defer { inFlightControls.remove(intent.id) }

        let outcome: RoomControlOutcome
        do {
            let client = try controlClient(for: intent.dashboardID)

            let reason = AppLocalization.string("Authorize \(intent.action.rawValue) on this Room")
            guard await authenticate(reason) else {
                // No network I/O occurred, so this user gesture is safely
                // abandoned rather than recovered after restart.
                controlJournal.remove(intentID: intent.id)
                outcome = Self.outcome(intent, kind: .biometricRejected, at: clock())
                return record(outcome)
            }
            guard !Task.isCancelled else { throw CancellationError() }

            // Cold-restart recovery: if a prior process already obtained a
            // durable operation id, resume from the read projection. Never
            // POST the mutation again just to rediscover its status.
            if let journalEntry = controlJournal.entry(intentID: intent.id),
               let operationID = journalEntry.operationID {
                let latest = try await client.getOperation(operationID: operationID)
                controlJournal.recordOperation(
                    intentID: intent.id,
                    operationID: latest.operationId,
                    status: latest.status,
                    at: clock()
                )
                if latest.status == .applied {
                    await resyncAndResolveJournal(intent)
                    outcome = Self.outcome(
                        intent,
                        kind: .applied,
                        subject: latest.subject,
                        detail: latest.operationId,
                        at: clock()
                    )
                } else if let applied = await pollToApplied(
                    intentID: intent.id,
                    operationID: latest.operationId,
                    client: client
                ) {
                    await resyncAndResolveJournal(intent)
                    outcome = Self.outcome(
                        intent,
                        kind: .applied,
                        subject: applied.subject ?? latest.subject,
                        detail: applied.operationId,
                        at: clock()
                    )
                } else {
                    outcome = Self.outcome(
                        intent,
                        kind: .recorded,
                        subject: latest.subject,
                        detail: latest.operationId,
                        at: clock()
                    )
                }
                return record(outcome)
            }

            let serverRecord = try await dispatch(intent, client: client)
            // Persist the durable Hub identity before polling/resync. A crash
            // after this point resumes with GET /operations/{id}.
            controlJournal.recordOperation(
                intentID: intent.id,
                operationID: serverRecord.operationId,
                status: serverRecord.status,
                at: clock()
            )

            if serverRecord.isRecorded {
                if let applied = await pollToApplied(
                    intentID: intent.id,
                    operationID: serverRecord.operationId,
                    client: client
                ) {
                    await resyncAndResolveJournal(intent)
                    outcome = Self.outcome(
                        intent,
                        kind: .applied,
                        subject: applied.subject ?? serverRecord.subject,
                        detail: applied.operationId,
                        at: clock()
                    )
                } else {
                    outcome = Self.outcome(
                        intent,
                        kind: .recorded,
                        subject: serverRecord.subject,
                        detail: serverRecord.operationId,
                        at: clock()
                    )
                }
            } else {
                // Applied replay is still the already-recorded effect, not a
                // fresh mutation. Keep the UI distinction while finishing
                // the same authority resync boundary.
                await resyncAndResolveJournal(intent)
                outcome = Self.outcome(
                    intent,
                    kind: serverRecord.isReplay ? .duplicateRejected : .applied,
                    subject: serverRecord.subject,
                    detail: serverRecord.operationId,
                    at: clock()
                )
            }
        } catch let error as RoomControlError {
            outcome = Self.outcome(
                intent,
                kind: Self.kind(for: error),
                detail: Self.detail(for: error),
                at: clock()
            )
            // Client-malformed intent cannot have reached the server.
            if case .undecodable(let status, _) = error, status == 0 {
                controlJournal.remove(intentID: intent.id)
            }
            // A server-proven idempotency conflict means this key is already
            // bound to a DIFFERENT op/target. Retaining it would poison every
            // future equivalent gesture with the same permanent 409. Retire
            // only this losing local intent; the server record remains source
            // truth and this request still fails closed.
            if case .idempotencyConflict = error {
                controlJournal.remove(intentID: intent.id)
            }
            // A precondition failure means the timeline moved under us.
            // Re-read it, but keep the same durable key until a later
            // equivalent gesture either succeeds or is explicitly replaced.
            if case .preconditionFailed = error {
                await syncRoom(dashboardID: intent.dashboardID, roomID: intent.roomID)
            }
        } catch {
            // Ambiguous transport/process failures deliberately leave the
            // journal entry intact so a later retry reuses the exact key.
            outcome = Self.outcome(
                intent,
                kind: .failed,
                detail: error.localizedDescription,
                at: clock()
            )
        }
        return record(outcome)
    }

    /// Re-reads one op record — the UI's way to keep watching a `.recorded`
    /// outcome after `perform` returned. Returns the latest record, or nil
    /// when the read itself fails (the projection, not this call, is the
    /// freshness surface).
    func refreshOperation(
        dashboardID: UUID,
        operationID: String
    ) async -> ControlOperationRecord? {
        guard let client = try? controlClient(for: dashboardID) else { return nil }
        return try? await client.getOperation(operationID: operationID)
    }

    /// APNs wake-only handler: a room push can cause a resync of fresh
    /// authority — and nothing else. It cannot mutate and cannot be trusted
    /// for content beyond "this room moved".
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
        controlJournal.clearDashboard(dashboardID)
        readClients[dashboardID] = nil
        controlClients[dashboardID] = nil
        coordinators[dashboardID] = nil
        dashboardStates[dashboardID] = nil
        let prefix = "\(dashboardID.uuidString)/"
        projections = projections.filter { !$0.key.hasPrefix(prefix) }
    }

    // MARK: - Private

    /// Dispatches the intent to the frozen op surface. Malformed intents
    /// fail here, before any network I/O.
    private func dispatch(
        _ intent: RoomControlIntent,
        client: RoomControlClient
    ) async throws -> ControlOperationRecord {
        let key = intent.idempotencyKey
        switch intent.action {
        case .cancel:
            guard let executionID = intent.executionID, !executionID.isEmpty else {
                throw RoomControlError.undecodable(status: 0, detail: "cancel requires an executionID")
            }
            return try await client.cancelExecution(
                executionID: executionID,
                idempotencyKey: key,
                correlationID: intent.correlationID
            )
        case .retry:
            guard let executionID = intent.executionID, !executionID.isEmpty else {
                throw RoomControlError.undecodable(status: 0, detail: "retry requires an executionID")
            }
            return try await client.retryExecution(
                executionID: executionID,
                idempotencyKey: key,
                correlationID: intent.correlationID
            )
        case .resume:
            guard let executionID = intent.executionID, !executionID.isEmpty else {
                throw RoomControlError.undecodable(status: 0, detail: "resume requires an executionID")
            }
            return try await client.resumeExecution(
                executionID: executionID,
                idempotencyKey: key,
                correlationID: intent.correlationID
            )
        case .acknowledge:
            guard let executionID = intent.executionID, !executionID.isEmpty,
                  let kind = intent.attentionKind else {
                throw RoomControlError.undecodable(status: 0, detail: "acknowledge requires an executionID and attentionKind")
            }
            return try await client.acknowledgeAttention(
                executionID: executionID,
                attentionKind: kind,
                idempotencyKey: key,
                correlationID: intent.correlationID
            )
        case .start:
            guard let trigger = intent.trigger, !trigger.isEmpty,
                  let projectSlug = intent.projectSlug, !projectSlug.isEmpty else {
                throw RoomControlError.undecodable(status: 0, detail: "start requires a trigger and projectSlug")
            }
            return try await client.startApprovedExecution(
                trigger: trigger,
                projectSlug: projectSlug,
                idempotencyKey: key,
                correlationID: intent.correlationID
            )
        default:
            throw RoomControlError.undecodable(status: 0, detail: "unknown action \(intent.action.rawValue)")
        }
    }

    /// Bounded poll of GET /operations/{id}. Every observed status is
    /// durably journaled before the next step so a crash never regresses from
    /// an operation id back to mutation replay.
    private func pollToApplied(
        intentID: UUID,
        operationID: String,
        client: RoomControlClient
    ) async -> ControlOperationRecord? {
        for _ in 0..<operationPollMaxAttempts {
            if operationPollInterval > 0 {
                try? await Task.sleep(nanoseconds: UInt64(operationPollInterval * 1_000_000_000))
            }
            guard let record = try? await client.getOperation(operationID: operationID) else {
                return nil
            }
            controlJournal.recordOperation(
                intentID: intentID,
                operationID: record.operationId,
                status: record.status,
                at: clock()
            )
            if record.status == .applied { return record }
        }
        return nil
    }

    /// Applied does not become locally complete until the authority Room
    /// projection is live again. If resync fails, the journal intentionally
    /// remains so the next launch resolves the same op instead of minting a
    /// new mutation key.
    private func resyncAndResolveJournal(_ intent: RoomControlIntent) async {
        await syncRoom(dashboardID: intent.dashboardID, roomID: intent.roomID)
        let key = scopeKey(dashboardID: intent.dashboardID, roomID: intent.roomID)
        if let freshness = projections[key]?.freshness, freshness == .live {
            controlJournal.remove(intentID: intent.id)
        }
    }

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
        subject: String? = nil,
        detail: String? = nil,
        at: Date
    ) -> RoomControlOutcome {
        RoomControlOutcome(
            intentID: intent.id,
            action: intent.action,
            kind: kind,
            subject: subject,
            detail: detail,
            at: at
        )
    }

    private static func kind(for error: RoomControlError) -> RoomControlOutcome.Kind {
        switch error {
        case .capabilityDenied: return .capabilityDenied
        case .insufficientScope: return .insufficientScope
        case .preconditionFailed: return .preconditionFailed
        case .idempotencyConflict: return .idempotencyConflict
        case .missingCredential: return .unconfigured
        case .unauthorized: return .unauthorized
        case .notFound: return .notFound
        case .controlPlaneUnavailable, .infrastructureUnavailable: return .controlPlaneUnavailable
        case .undecodable(let status, _): return status == 0 ? .invalidIntent : .failed
        default: return .failed
        }
    }

    private static func detail(for error: RoomControlError) -> String? {
        switch error {
        case .capabilityDenied(let problem),
             .insufficientScope(let problem),
             .preconditionFailed(let problem),
             .idempotencyConflict(let problem),
             .unauthorized(let problem),
             .notFound(let problem),
             .controlPlaneUnavailable(let problem),
             .infrastructureUnavailable(let problem):
            return problem.detail ?? problem.code
        case .problem(_, let problem):
            return problem?.detail ?? problem?.code
        default:
            return error.errorDescription
        }
    }
}
