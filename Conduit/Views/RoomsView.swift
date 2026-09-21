//
//  RoomsView.swift
//  Conduit
//
//  The ANVIL Rooms surface (I4): rooms list → room detail → capability-
//  scoped execution controls. Reads go through RoomCenter → the H1
//  projection seam; mutations go through RoomCenter.perform, which runs
//  biometric step-up → Hub op POST (frozen HUB_CONTROL_CONTRACT_V1) →
//  authority resync.
//
//  This view owns no authority decisions: it renders the Room projection
//  verbatim (stale stays visibly stale), and every control is a request the
//  Hub can deny — `control_capability_denied` and `insufficient_scope`
//  surface as different outcomes, never collapsed. 202 `recorded` is shown
//  as queued-with-the-authority, never as applied.
//

import SwiftUI

// MARK: - Rooms tab content

struct RoomListView: View {
    @ObservedObject var appLanguage = AppLanguageStore.shared
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var center = RoomCenter.shared
    @ObservedObject private var notifications = PushNotificationService.shared

    @State private var selectedRoom: ProjectedRoom?
    @State private var showCredentialSheet = false

    private var dashboardID: UUID? { appState.activeDashboardID }

    private var state: RoomCenter.DashboardRoomsState {
        dashboardID.map { center.roomsState(for: $0) } ?? RoomCenter.DashboardRoomsState()
    }

    var body: some View {
        Group {
            if dashboardID == nil {
                ContentUnavailableView(
                    AppLocalization.string("No Dashboard"),
                    systemImage: "server.rack",
                    description: Text(AppLocalization.string("Connect a dashboard to view Rooms."))
                )
            } else {
                listContent
            }
        }
        .task(id: dashboardID) {
            guard let dashboardID else { return }
            await center.refreshRooms(dashboardID: dashboardID)
        }
        .sheet(item: $selectedRoom) { room in
            RoomDetailSheet(room: room)
        }
        .sheet(isPresented: $showCredentialSheet) {
            if let dashboardID {
                RoomHubCredentialSheet(dashboardID: dashboardID)
            }
        }
    }

    @ViewBuilder
    private var listContent: some View {
        List {
            switch state.phase {
            case .unconfigured:
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        Label(
                            AppLocalization.string("Room hub is not configured for this dashboard."),
                            systemImage: "key"
                        )
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        Button {
                            Haptics.selection()
                            showCredentialSheet = true
                        } label: {
                            Text(AppLocalization.string("Configure Room Hub"))
                                .font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity)
                                .frame(height: 40)
                        }
                        .conduitGlassControl(cornerRadius: 14, tint: .conduitAccent.opacity(0.14))
                    }
                    .padding(.vertical, 4)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }
            case .failed(let message):
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        Label(
                            AppLocalization.string("Could not load Rooms."),
                            systemImage: "exclamationmark.triangle"
                        )
                        .font(.footnote)
                        Text(verbatim: message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button(AppLocalization.string("Retry")) {
                            guard let dashboardID else { return }
                            Task { await center.refreshRooms(dashboardID: dashboardID) }
                        }
                        .font(.subheadline.weight(.semibold))
                    }
                    .padding(.vertical, 4)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }
            default:
                EmptyView()
            }

            Section(AppLocalization.string("Rooms")) {
                if state.rooms.isEmpty && state.phase == .loaded {
                    Text(AppLocalization.string("Rooms you can observe appear here."))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
                ForEach(state.rooms) { room in
                    Button {
                        Haptics.light()
                        selectedRoom = room
                    } label: {
                        RoomRow(room: room)
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 3, leading: 0, bottom: 3, trailing: 0))
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .overlay {
            if state.rooms.isEmpty && (state.phase == .idle || state.phase == .loading) {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .refreshable {
            guard let dashboardID else { return }
            await center.refreshRooms(dashboardID: dashboardID)
        }
    }
}

private struct RoomRow: View {
    @ObservedObject var appLanguage = AppLanguageStore.shared
    let room: ProjectedRoom

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: "rectangle.stack")
                .foregroundStyle(statusTint)
                .frame(width: 30, height: 30)
                .background(statusTint.opacity(0.13), in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: room.projectRef ?? shortID(room.roomID))
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Text(verbatim: shortID(room.roomID))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 3) {
                Text(statusLabel)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(statusTint)
                Text(verbatim: "#\(room.latestSeq)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
            }
            Image(systemName: "chevron.right")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var statusTint: Color {
        switch room.status {
        case .active: return .green
        case .archived: return .secondary
        case .closed: return .orange
        }
    }

    private var statusLabel: String {
        switch room.status {
        case .active: return AppLocalization.string("Active")
        case .archived: return AppLocalization.string("Archived")
        case .closed: return AppLocalization.string("Closed")
        }
    }

    private func shortID(_ id: String) -> String {
        id.count > 13 ? String(id.prefix(8)) + "…" + String(id.suffix(4)) : id
    }
}

// MARK: - Room detail sheet

struct RoomDetailSheet: View {
    @ObservedObject var appLanguage = AppLanguageStore.shared
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var center = RoomCenter.shared
    @Environment(\.dismiss) private var dismiss

    let room: ProjectedRoom

    @State private var pendingAction: PendingControl?
    @State private var acknowledgeExecutionID: String?
    @State private var lastOutcome: RoomControlOutcome?
    @State private var showCredentialSheet = false

    private struct PendingControl: Equatable {
        let action: RoomControlAction
        let executionID: String
        /// Required by the frozen contract for `.acknowledge`.
        let attentionKind: AttentionKind?
        /// I1 correlation spine copied from the Room projection, never minted.
        let correlationID: String?
    }

    private var dashboardID: UUID? { appState.activeDashboardID }

    private var projection: RoomReplayCoordinator.Projection {
        dashboardID.map { center.projection(dashboardID: $0, roomID: room.roomID) }
            ?? RoomReplayCoordinator.Projection()
    }

    private var executions: [RoomExecutionProjection] {
        RoomExecutionIndex.projections(from: projection.events)
    }

    private var controlsEnabled: Bool {
        projection.freshness == .live
    }

    var body: some View {
        NavigationStack {
            ZStack {
                ConduitBackdrop()
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        overviewSection
                        controlsSection
                        participantsSection
                        timelineSection
                    }
                    .padding(16)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .safeAreaInset(edge: .top, spacing: 0) {
                ConduitSheetHeader(title: AppLocalization.string("Room"), close: { dismiss() })
            }
        }
        .task(id: dashboardID) {
            guard let dashboardID else { return }
            await center.syncRoom(dashboardID: dashboardID, roomID: room.roomID)
        }
        .sheet(isPresented: $showCredentialSheet) {
            if let dashboardID {
                RoomHubCredentialSheet(dashboardID: dashboardID)
            }
        }
        .confirmationDialog(
            confirmTitle,
            isPresented: Binding(
                get: { pendingAction != nil },
                set: { if !$0 { pendingAction = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let pending = pendingAction {
                Button(actionLabel(pending.action), role: pending.action.isDestructive ? .destructive : nil) {
                    run(pending)
                }
            }
            Button(AppLocalization.string("Cancel"), role: .cancel) { pendingAction = nil }
        } message: {
            Text(AppLocalization.string("Biometric step-up authorizes this op with the Hub. The Hub instance's bound subject applies its own durable capability grant — Conduit never holds one."))
        }
        // Acknowledge requires an attention kind (frozen contract §2.2), so
        // the kind is chosen first, then the main confirmation dialog runs.
        .confirmationDialog(
            AppLocalization.string("Acknowledge which state?"),
            isPresented: Binding(
                get: { acknowledgeExecutionID != nil },
                set: { if !$0 { acknowledgeExecutionID = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let executionID = acknowledgeExecutionID {
                ForEach(AttentionKind.userSelectable, id: \.rawValue) { kind in
                    Button(attentionKindLabel(kind)) {
                        acknowledgeExecutionID = nil
                        let correlationID = executions.first { $0.executionID == executionID }?.correlationID
                        pendingAction = PendingControl(
                            action: .acknowledge,
                            executionID: executionID,
                            attentionKind: kind,
                            correlationID: correlationID
                        )
                    }
                }
            }
            Button(AppLocalization.string("Cancel"), role: .cancel) { acknowledgeExecutionID = nil }
        } message: {
            Text(AppLocalization.string("The Hub records which attention state you are acknowledging."))
        }
    }

    // MARK: Overview

    private var overviewSection: some View {
        ConduitSettingsSection(
            title: room.projectRef ?? AppLocalization.string("Room"),
            symbol: "rectangle.stack",
            tint: .conduitAccent
        ) {
            SettingsMetricRow(
                label: AppLocalization.string("Status"),
                value: statusLabel(room.status)
            )
            SettingsMetricRow(
                label: AppLocalization.string("Room"),
                value: shortID(room.roomID),
                lineLimit: 1
            )
            SettingsMetricRow(
                label: AppLocalization.string("Correlation"),
                value: shortID(room.correlationID),
                lineLimit: 1
            )
            SettingsMetricRow(
                label: AppLocalization.string("Latest sequence"),
                value: String(room.latestSeq)
            )
            SettingsMetricRow(
                label: AppLocalization.string("Freshness"),
                value: freshnessLabel,
                valueColor: freshnessColor,
                statusDot: freshnessColor
            )
            if let lastSync = projection.lastSyncAt {
                SettingsMetricRow(
                    label: AppLocalization.string("Last synced"),
                    value: Self.timestampFormatter.string(from: lastSync)
                )
            }
            if case .stale(let reason) = projection.freshness {
                Text(verbatim: reason)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    // MARK: Controls

    private var controlsSection: some View {
        ConduitSettingsSection(
            title: AppLocalization.string("Execution controls"),
            symbol: "switch.2",
            tint: .conduitAura
        ) {
            if let outcome = lastOutcome {
                outcomeBanner(outcome)
                    .task(id: outcome.id) {
                        await watchRecordedOperation(outcome)
                    }
            }

            if !controlsEnabled {
                Label(
                    AppLocalization.string("Controls need a fresh sync — replay first."),
                    systemImage: "arrow.clockwise"
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }

            if executions.isEmpty && room.status != .active {
                Text(AppLocalization.string("No controllable execution is bound to this Room."))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            ForEach(executions) { execution in
                executionBlock(execution)
            }
        }
    }

    private func executionBlock(_ execution: RoomExecutionProjection) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(verbatim: shortID(execution.executionID))
                    .font(.caption.monospaced().weight(.semibold))
                if let state = execution.state {
                    Text(verbatim: state)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Color.primary.opacity(0.06), in: Capsule())
                }
                Spacer(minLength: 4)
                if let principal = execution.subject {
                    Text(verbatim: principal)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            let candidates = RoomControlPolicy.candidates(for: execution)
            if candidates.isEmpty {
                Text(AppLocalization.string("No actions for this state."))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                FlowActionsRow(
                    actions: candidates,
                    isBusy: !center.inFlightControls.isEmpty,
                    onTap: { action in
                        guard controlsEnabled else { return }
                        Haptics.selection()
                        if action == .acknowledge {
                            // The frozen contract requires an attention kind
                            // on acknowledge — pick it before confirming.
                            acknowledgeExecutionID = execution.executionID
                        } else {
                            pendingAction = PendingControl(
                                action: action,
                                executionID: execution.executionID,
                                attentionKind: nil,
                                correlationID: execution.correlationID
                            )
                        }
                    }
                )
                .disabled(!controlsEnabled)
                .opacity(controlsEnabled ? 1 : 0.55)
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    /// Compact wrap of action buttons — each is a request the Hub can deny.
    /// The row locks while any intent is in flight so two confirmations can
    /// never overlap.
    private struct FlowActionsRow: View {
        let actions: [RoomControlAction]
        let isBusy: Bool
        let onTap: (RoomControlAction) -> Void

        var body: some View {
            HStack(spacing: 8) {
                ForEach(actions, id: \.rawValue) { action in
                    Button {
                        onTap(action)
                    } label: {
                        Label(actionTitle(action), systemImage: actionIcon(action))
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 10)
                            .frame(height: 34)
                    }
                    .conduitGlassControl(
                        cornerRadius: 12,
                        tint: action.isDestructive ? Color.red.opacity(0.16) : Color.conduitAccent.opacity(0.12)
                    )
                    .disabled(isBusy)
                }
            }
        }

        private func actionTitle(_ action: RoomControlAction) -> String {
            switch action {
            case .acknowledge: return AppLocalization.string("Acknowledge")
            case .resume: return AppLocalization.string("Resume")
            case .retry: return AppLocalization.string("Retry")
            case .cancel: return AppLocalization.string("Cancel")
            default: return action.rawValue
            }
        }

        private func actionIcon(_ action: RoomControlAction) -> String {
            switch action {
            case .acknowledge: return "checkmark.seal"
            case .resume: return "play.fill"
            case .retry: return "arrow.clockwise"
            case .cancel: return "xmark.octagon"
            default: return "bolt"
            }
        }
    }

    // MARK: Participants + timeline

    private var participantsSection: some View {
        ConduitSettingsSection(
            title: AppLocalization.string("Participants"),
            symbol: "person.2",
            tint: .conduitAura
        ) {
            if projection.participants.isEmpty {
                Text(AppLocalization.string("No active participants."))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            ForEach(projection.participants) { member in
                HStack(spacing: 10) {
                    Image(systemName: "person.crop.circle")
                        .foregroundStyle(.secondary)
                    Text(verbatim: shortID(member.agentID))
                        .font(.caption.monospaced())
                    Spacer()
                    Text(verbatim: member.role)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var timelineSection: some View {
        ConduitSettingsSection(
            title: AppLocalization.string("Timeline"),
            symbol: "clock.arrow.circlepath",
            tint: .conduitAccent
        ) {
            if projection.events.isEmpty {
                Text(AppLocalization.string("Replayed events appear here after a sync."))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            // Newest first — the operator reads the tail.
            ForEach(projection.events.reversed()) { event in
                RoomEventRow(event: event)
            }
        }
    }

    // MARK: Outcome + helpers

    private func outcomeBanner(_ outcome: RoomControlOutcome) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: outcomeIcon(outcome.kind))
                .foregroundStyle(outcomeColor(outcome.kind))
            VStack(alignment: .leading, spacing: 2) {
                Text(outcomeTitle(outcome))
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(outcomeColor(outcome.kind))
                if let subject = outcome.subject {
                    Text(verbatim: subject)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }
                if let detail = outcome.detail {
                    Text(verbatim: detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(outcomeColor(outcome.kind).opacity(0.09), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func outcomeTitle(_ outcome: RoomControlOutcome) -> String {
        switch outcome.kind {
        case .applied:
            return AppLocalization.string("Action applied")
        case .recorded:
            return AppLocalization.string("Recorded — queued with the execution authority")
        case .duplicateRejected:
            return AppLocalization.string("Already recorded — duplicate suppressed")
        case .capabilityDenied:
            return AppLocalization.string("The Hub denied the control capability")
        case .insufficientScope:
            return AppLocalization.string("The Room credential lacks the control scope")
        case .preconditionFailed:
            return AppLocalization.string("No longer actionable — timeline refreshed")
        case .idempotencyConflict:
            return AppLocalization.string("Idempotency conflict — key bound to a different op")
        case .biometricRejected:
            return AppLocalization.string("Authorization cancelled")
        case .unconfigured:
            return AppLocalization.string("Room hub is not configured")
        case .unauthorized:
            return AppLocalization.string("Credential rejected")
        case .notFound:
            return AppLocalization.string("Execution or operation not found")
        case .controlPlaneUnavailable:
            return AppLocalization.string("This hub has no execution controls")
        case .invalidIntent:
            return AppLocalization.string("Invalid control request")
        case .failed:
            return AppLocalization.string("Action failed")
        }
    }

    private func outcomeColor(_ kind: RoomControlOutcome.Kind) -> Color {
        switch kind {
        case .applied: return .green
        case .duplicateRejected: return .green
        case .recorded: return .orange
        case .capabilityDenied: return .red
        case .insufficientScope: return .orange
        case .preconditionFailed: return .orange
        case .idempotencyConflict: return .red
        case .biometricRejected: return .secondary
        case .unconfigured, .unauthorized, .notFound, .controlPlaneUnavailable, .invalidIntent, .failed: return .red
        }
    }

    private func outcomeIcon(_ kind: RoomControlOutcome.Kind) -> String {
        switch kind {
        case .applied, .duplicateRejected: return "checkmark.circle.fill"
        case .recorded: return "clock.badge.checkmark"
        case .capabilityDenied: return "lock.shield.fill"
        case .insufficientScope: return "key.fill"
        case .preconditionFailed: return "arrow.triangle.2.circlepath"
        case .idempotencyConflict: return "exclamationmark.2"
        case .biometricRejected: return "faceid"
        default: return "exclamationmark.triangle.fill"
        }
    }

    private var confirmTitle: String {
        guard let pending = pendingAction else { return "" }
        if pending.action == .acknowledge, let kind = pending.attentionKind {
            return AppLocalization.string("Acknowledge \(kind.rawValue) on this execution?")
        }
        return AppLocalization.string("Run \(pending.action.rawValue) on this execution?")
    }

    private func actionLabel(_ action: RoomControlAction) -> String {
        switch action {
        case .acknowledge: return AppLocalization.string("Acknowledge")
        case .resume: return AppLocalization.string("Resume")
        case .retry: return AppLocalization.string("Retry")
        case .cancel: return AppLocalization.string("Cancel")
        default: return action.rawValue
        }
    }

    private func attentionKindLabel(_ kind: AttentionKind) -> String {
        switch kind {
        case .terminal: return AppLocalization.string("Terminal")
        case .idle: return AppLocalization.string("Idle")
        case .finishExecutionCall: return kind.rawValue
        }
    }

    private func run(_ pending: PendingControl) {
        pendingAction = nil
        guard let dashboardID else { return }
        let intent: RoomControlIntent
        do {
            intent = try center.makeIntent(
                dashboardID: dashboardID,
                roomID: room.roomID,
                executionID: pending.executionID,
                action: pending.action,
                attentionKind: pending.attentionKind,
                correlationID: pending.correlationID
            )
        } catch {
            // Fail closed before any network I/O: a poisoned journal or a
            // failed durable commit means this gesture cannot safely mutate.
            lastOutcome = RoomControlOutcome(
                intentID: UUID(),
                action: pending.action,
                kind: .failed,
                subject: nil,
                detail: error.localizedDescription,
                at: Date()
            )
            return
        }
        Task {
            lastOutcome = await center.perform(intent)
        }
    }

    // MARK: - D12: recorded-operation watch

    /// Poll interval / bound for watching a `.recorded` outcome to `.applied`.
    /// Bounded so a never-resolving op cannot spin the UI forever; expiry
    /// leaves the recorded banner untouched (still truthful) and the next
    /// sync/projection surfaces the applied state.
    private static let recordedWatchInterval: Duration = .seconds(2)
    private static let recordedWatchMaxAttempts = 45

    /// Closes the operator loop for `.recorded` outcomes: after `perform`
    /// returns `.recorded`, the Hub owns the effect downstream, so the UI
    /// re-reads the op record via `refreshOperation` until its status flips
    /// to `.applied`, then resyncs and promotes the banner. Bounded and
    /// cancellable: a new outcome or a disappearing view ends the watch via
    /// the `.task(id:)` owner, and `Task.isCancelled` is honored each step.
    /// A failed read is transient -- it consumes one attempt, never the watch.
    private func watchRecordedOperation(_ outcome: RoomControlOutcome) async {
        guard outcome.kind == .recorded,
              let dashboardID,
              let operationID = outcome.detail, !operationID.isEmpty
        else { return }
        let roomID = room.roomID
        for _ in 0..<Self.recordedWatchMaxAttempts {
            try? await Task.sleep(for: Self.recordedWatchInterval)
            if Task.isCancelled { return }
            guard let record = await center.refreshOperation(
                dashboardID: dashboardID,
                operationID: operationID
            ) else { continue }
            if Task.isCancelled { return }
            guard record.status == .applied else { continue }
            await center.syncRoom(dashboardID: dashboardID, roomID: roomID)
            if Task.isCancelled { return }
            lastOutcome = RoomControlOutcome(
                intentID: outcome.intentID,
                action: outcome.action,
                kind: .applied,
                subject: record.subject,
                detail: record.operationId,
                at: Date()
            )
            return
        }
    }

    private func statusLabel(_ status: RoomStatus) -> String {
        switch status {
        case .active: return AppLocalization.string("Active")
        case .archived: return AppLocalization.string("Archived")
        case .closed: return AppLocalization.string("Closed")
        }
    }

    private var freshnessLabel: String {
        switch projection.freshness {
        case .live: return AppLocalization.string("Live")
        case .stale: return AppLocalization.string("Stale")
        case .neverSynced: return AppLocalization.string("Not synced yet")
        }
    }

    private var freshnessColor: Color {
        switch projection.freshness {
        case .live: return .green
        case .stale: return .orange
        case .neverSynced: return .secondary
        }
    }

    private func shortID(_ id: String) -> String {
        id.count > 13 ? String(id.prefix(8)) + "…" + String(id.suffix(4)) : id
    }

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .medium
        return formatter
    }()
}

// MARK: - Event row

private struct RoomEventRow: View {
    @ObservedObject var appLanguage = AppLanguageStore.shared
    let event: RoomEvent

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: kindIcon)
                .font(.caption)
                .foregroundStyle(kindTint)
                .frame(width: 24, height: 24)
                .background(kindTint.opacity(0.12), in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(verbatim: event.kind.rawValue)
                        .font(.caption2.monospaced().weight(.semibold))
                        .foregroundStyle(kindTint)
                    Spacer(minLength: 4)
                    Text(verbatim: "#\(event.roomSeq)")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                    if let stamp = shortTimestamp {
                        Text(verbatim: stamp)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.tertiary)
                    }
                }
                if let preview = previewText {
                    Text(verbatim: preview)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Text(verbatim: event.producer)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 3)
    }

    private var kindIcon: String {
        switch event.kind {
        case .message: return "bubble.left"
        case .handoff: return "arrow.triangle.branch"
        case .approval: return "checkmark.shield"
        case .evidenceRef: return "link"
        case .execution, .executionTransition, .executionBound, .executionRebound:
            return "gearshape.2"
        case .dispatchReceived: return "paperplane"
        case .sieveProjection: return "eye"
        case .system: return "info.circle"
        default: return "circle"
        }
    }

    private var kindTint: Color {
        switch event.kind {
        case .approval: return .green
        case .execution, .executionTransition, .executionBound, .executionRebound:
            return .conduitAccent
        case .dispatchReceived: return .conduitAura
        case .evidenceRef: return .indigo
        case .sieveProjection: return .teal
        default: return .secondary
        }
    }

    /// Payload preview: the recognizable text fields first, then state
    /// transitions rendered as `from → to`, never invented content.
    private var previewText: String? {
        for key in ["text", "title", "summary", "message", "reason"] {
            if let value = event.payload[key]?.descriptiveStringValue, !value.isEmpty {
                return value
            }
        }
        let from = event.payload["from_state"]?.stringValue ?? event.payload["from"]?.stringValue
        let to = event.payload["to_state"]?.stringValue ?? event.payload["state"]?.stringValue
            ?? event.payload["to"]?.stringValue
        if let to {
            return from.map { "\($0) → \(to)" } ?? to
        }
        return nil
    }

    private var shortTimestamp: String? {
        guard let stamp = event.occurredAt ?? Optional(event.createdAt), stamp.count >= 19 else {
            return nil
        }
        let start = stamp.index(stamp.startIndex, offsetBy: 11)
        let end = stamp.index(start, offsetBy: 8)
        return String(stamp[start..<end])
    }
}

// MARK: - Hub credential sheet

/// Per-dashboard Room Hub credential editor — the ONLY place the Hub URL +
/// bearer token are entered. Saved through RoomHubCredentialStore into the
/// dashboard-scoped Keychain record; deleting the dashboard clears it.
struct RoomHubCredentialSheet: View {
    @ObservedObject var appLanguage = AppLanguageStore.shared
    @Environment(\.dismiss) private var dismiss

    let dashboardID: UUID
    var credentialStore: RoomHubCredentialStore = .system
    var onSaved: (() -> Void)? = nil

    @State private var hubURL = ""
    @State private var token = ""
    @State private var hasSavedCredential = false
    @State private var validationError: String?

    var body: some View {
        NavigationStack {
            ZStack {
                ConduitBackdrop()
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        ConduitSettingsSection(
                            title: AppLocalization.string("Room Hub"),
                            symbol: "key.fill",
                            tint: .conduitAccent
                        ) {
                            Text(AppLocalization.string("Hub address and bearer token for this dashboard's ANVIL Room seam. Stored per dashboard in the Keychain."))
                                .font(.footnote)
                                .foregroundStyle(.secondary)

                            TextField(
                                AppLocalization.string("Hub base URL"),
                                text: $hubURL
                            )
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                            .padding(12)
                            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))

                            SecureField(
                                AppLocalization.string("Hub bearer token"),
                                text: $token
                            )
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .padding(12)
                            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))

                            if let validationError {
                                Text(verbatim: validationError)
                                    .font(.caption)
                                    .foregroundStyle(.red)
                            }

                            Button {
                                save()
                            } label: {
                                Text(AppLocalization.string("Save"))
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(Color.conduitBackgroundColor)
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 44)
                                    .background(Color.conduitAccent, in: RoundedRectangle(cornerRadius: 14))
                            }
                            .buttonStyle(.plain)

                            if hasSavedCredential {
                                Button(role: .destructive) {
                                    credentialStore.clear(dashboardID: dashboardID)
                                    hasSavedCredential = false
                                    hubURL = ""
                                    token = ""
                                } label: {
                                    Text(AppLocalization.string("Remove saved credential"))
                                        .font(.footnote.weight(.semibold))
                                        .frame(maxWidth: .infinity)
                                        .frame(height: 36)
                                }
                            }
                        }
                    }
                    .padding(16)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .safeAreaInset(edge: .top, spacing: 0) {
                ConduitSheetHeader(title: AppLocalization.string("Room Hub"), close: { dismiss() })
            }
        }
        .onAppear {
            if let existing = credentialStore.load(dashboardID: dashboardID) {
                hubURL = existing.hubBaseURL
                hasSavedCredential = true
            }
        }
    }

    private func save() {
        let trimmedURL = hubURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        // The URL is validated through the same policy the client applies —
        // remote hubs must be HTTPS; cleartext only on loopback/LAN/tailnet.
        do {
            _ = try ConnectionURLPolicy.normalizedBaseURL(trimmedURL)
        } catch {
            validationError = error.localizedDescription
            return
        }
        guard !trimmedToken.isEmpty else {
            validationError = AppLocalization.string("The hub token is empty.")
            return
        }
        let credential = RoomHubCredential(hubBaseURL: trimmedURL, token: trimmedToken)
        guard credentialStore.save(credential, dashboardID: dashboardID) else {
            validationError = AppLocalization.string("Could not save to the Keychain.")
            return
        }
        hasSavedCredential = true
        onSaved?()
        dismiss()
    }
}
