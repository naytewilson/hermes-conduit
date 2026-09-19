//
//  ConduitApp.swift
//  Conduit — native SwiftUI iOS client for Hermes Agent
//
//  Created by Hermes Agent (Furina) — July 2026
//  This is a NATIVE SwiftUI app, not a React Native port.
//

import SwiftUI
import UIKit
import UserNotifications

final class ConduitAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        if let payload = launchOptions?[.remoteNotification] as? [AnyHashable: Any] {
            Task { @MainActor in
                PushNotificationService.shared.receiveNotificationPayload(payload)
            }
        }
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Task { @MainActor in
            PushNotificationService.shared.didReceiveDeviceToken(deviceToken)
        }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        Task { @MainActor in
            PushNotificationService.shared.didFailToRegister(error)
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        Task { @MainActor in
            PushNotificationService.shared.receiveNotificationPayload(response.notification.request.content.userInfo)
        }
        completionHandler()
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // The active conversation is already visible while Conduit is in the
        // foreground. Keep remote pushes quiet here and reserve banners/sound
        // for when the app is not being actively used.
        completionHandler([])
    }
}

@main
struct ConduitApp: App {
    @UIApplicationDelegateAdaptor(ConduitAppDelegate.self) private var appDelegate
    /// Resolved through the process-wide registry (NOT created directly) so a
    /// CarPlay-first launch — where the CarPlay scene connects before any
    /// phone scene renders — binds the exact same AppState instance this
    /// SwiftUI surface adopts, whichever surface needs it first.
    @StateObject private var appState = AppStateRuntimeRegistry.shared.appState
    @ObservedObject private var notifications = PushNotificationService.shared
    @ObservedObject private var pendingVoiceIntents = PendingVoiceIntentStore.shared
    @ObservedObject private var appLanguage = AppLanguageStore.shared
    /// Sidebar selection is AppStorage-backed; a Room wake preselects the
    /// Rooms tab so the next sidebar open (or the persistent column) lands
    /// on the resynced room list. The write is navigation only.
    @AppStorage("conduit.sidebarTab") private var sidebarTabRaw = SidebarTab.sessions.rawValue

    var body: some Scene {
        // Multi-scene support is enabled in the manifest so the CarPlay
        // CPTemplateApplicationScene can coexist with the phone scene
        // (Apple: the flag governs ALL scene creation). SwiftUI's singleton
        // `Window` scene — the ideal foreground counterpart — is
        // iOS-unavailable (macOS 13+/visionOS only), so the phone surface
        // stays a `WindowGroup` and duplicate iPad windows are closed by the
        // RootView first-window guard instead: never an iPad multi-window
        // product.
        WindowGroup(id: "conduit-primary") {
#if DEBUG
            // The fixture is compiled out of release builds, so the launch
            // argument branch must be too.
            if ProcessInfo.processInfo.arguments.contains(SelectionFixtureView.launchArgument) {
                SelectionFixtureView()
            } else {
                rootContent
            }
#else
            rootContent
#endif
        }
    }

    private var rootContent: some View {
        RootView()
            .environmentObject(appState)
            // In-app App Language: literal SwiftUI keys resolve through the
            // same selection as AppLocalization.string(…). The environment
            // locale propagates reactively (Text re-renders without identity
            // changes), and every view holding String-context copy observes
            // AppLanguageStore itself, so switching language re-renders
            // exactly those views — the root is never rebuilt, and
            // navigation/composer/sheet/window-claim state is untouched.
            .environment(\.locale, appLanguage.resolvedLocale)
            .onChange(of: appLanguage.selection) { _, _ in
                // AppState-owned display caches (slash command descriptions)
                // re-resolve outside SwiftUI state, so view re-renders alone
                // cannot refresh them.
                appState.appLanguageDidChange()
            }
            .preferredColorScheme(appState.themePreference.colorScheme)
            .tint(.conduitAccent)
            .task { await PushNotificationService.shared.refresh() }
            .task(id: notificationRouteKey) {
                guard appState.isConnected, let target = notifications.pendingTarget else { return }
                if await appState.openNotificationTarget(target) {
                    notifications.clearPendingTarget(target)
                } else {
                    notifications.handleFailedNotificationRoute(target)
                }
            }
            .task(id: notifications.pendingRoomWake) {
                await routePendingRoomWake()
            }
            .task(id: voiceIntentRouteKey) {
                await resolvePendingVoiceIntent()
            }
            .task(id: voiceIntentDeadlineKey) {
                await waitOutPendingVoiceDeadline()
            }
    }

    private var notificationRouteKey: String {
        "\(notifications.pendingTarget?.id ?? "none"):\(appState.isConnected):\(notifications.navigationAttempt)"
    }

    /// Room wake handling (I4): a push that names a room causes a fresh
    /// authority re-read through RoomCenter and preselects the Rooms tab —
    /// the entire effect a push is allowed to have. Dashboard ownership is
    /// resolved with the same fail-closed rules as routing pushes: a wake
    /// for another saved dashboard is dropped (never a silent switch on push
    /// authority), and a wake for an unknown dashboard is dropped entirely.
    @MainActor
    private func routePendingRoomWake() async {
        guard let wake = notifications.pendingRoomWake else { return }
        let ownership = NotificationDashboardOwnership.resolve(
            targetDashboardID: wake.dashboardID,
            hasMalformedDashboardID: false,
            activeDashboardID: appState.activeDashboardID,
            savedDashboardIDs: appState.savedDashboardRegistry.dashboards.map(\.id)
        )
        guard case .route = ownership else {
            notifications.clearPendingRoomWake(wake)
            return
        }
        sidebarTabRaw = SidebarTab.rooms.rawValue
        await RoomCenter.shared.handleWake(wake, activeDashboardID: appState.activeDashboardID)
        notifications.clearPendingRoomWake(wake)
    }

    private var voiceIntentRouteKey: String {
        let connection = appState.voiceLaunchConnectionSnapshot()
        // Phase (not a bare isConnected flag) so connecting → stableFailure
        // re-evaluates the pending request while remaining disconnected.
        // Do not embed pendingSource: take() clears it without a revision
        // bump, and openVoiceConversation’s @Published mutations would flip
        // the key mid-handler and cancel the in-flight route task.
        return "\(pendingVoiceIntents.revision):\(connection.phase.rawValue)"
    }

    /// Deadline changes (new Siri enqueue / supersede) re-arm the wait; the
    /// revision already covers every other store mutation.
    private var voiceIntentDeadlineKey: String {
        guard let deadline = pendingVoiceIntents.pendingExternalLaunchDeadline else { return "none" }
        return "\(pendingVoiceIntents.revision):\(Int(deadline.timeIntervalSinceReferenceDate))"
    }

    /// Resolves the pending voice launch once. Ownership token: only the
    /// claimed request may be routed or failed; a superseded completion is
    /// discarded without publishing.
    private func resolvePendingVoiceIntent() async {
        let router = PendingVoiceIntentRouter(store: pendingVoiceIntents)
        let connection = appState.voiceLaunchConnectionSnapshot()
        let outcome = await router.routePending(connection: connection) { intent in
            await appState.openVoiceConversation(intent)
        }
        switch outcome {
        case .failed(let message):
            appState.errorMessage = message
        case .idle, .routed, .deferred, .superseded:
            break
        }
    }

    /// Authoritative 30s backstop. Sleeps on the monotonic clock, then
    /// expires the exact claim that armed the wait — never routes through
    /// generic readiness (which could return `.waiting` again).
    private func waitOutPendingVoiceDeadline() async {
        guard let claim = pendingVoiceIntents.peekClaim(),
              let elapsedDeadline = claim.intent.externalLaunchElapsedDeadline else {
            return
        }
        let now = ContinuousClock.now
        if now < elapsedDeadline {
            do {
                try await Task.sleep(for: now.duration(to: elapsedDeadline))
            } catch {
                // Superseded/cancelled waiter must not resolve a different intent.
                return
            }
        }
        guard let expired = pendingVoiceIntents.expireClaimIfCurrent(claim) else {
            return
        }
        if expired.source == .siri {
            appState.errorMessage = PendingVoiceLaunchPolicy.expiredFailureMessage
        }
    }
}
