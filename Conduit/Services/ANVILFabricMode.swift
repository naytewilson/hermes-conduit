//
//  ANVILFabricMode.swift
//  Conduit
//
//  Independent entry state for the ANVIL/SIEVE operator surface.
//
//  This is deliberately NOT a Hermes connection and never manufactures a
//  SavedDashboard. The Fabric workspace UUID is device-local routing identity
//  for Room credentials/replay only; authority remains in the Hub/ANVIL seam.
//

import Foundation

enum ANVILFabricModeStore {
    static let enabledKey = "conduit.anvilFabric.enabled"
    static let workspaceIDKey = "conduit.anvilFabric.workspaceID"

    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: enabledKey)
    }

    static func setEnabled(_ enabled: Bool, defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: enabledKey)
    }

    /// Stable local identity for the standalone Fabric workspace.
    ///
    /// This UUID is not a credential, capability, server identity, or Hermes
    /// dashboard id. It only scopes device-local Room Hub credentials, replay
    /// state, and control-journal identity so Fabric can operate without a
    /// Hermes dashboard existing at all.
    static func workspaceID(
        defaults: UserDefaults = .standard,
        makeUUID: () -> UUID = UUID.init
    ) -> UUID {
        if let raw = defaults.string(forKey: workspaceIDKey),
           let existing = UUID(uuidString: raw) {
            return existing
        }
        let created = makeUUID()
        defaults.set(created.uuidString, forKey: workspaceIDKey)
        return created
    }

#if DEBUG
    /// UI-test-only routing seam. It bypasses Hermes login without mutating
    /// persisted user state, proving the Fabric root is independently
    /// reachable on a clean process.
    static var uiTestForceEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains("-CONDUIT_UI_TEST_ANVIL_FABRIC")
    }
#else
    static let uiTestForceEnabled = false
#endif
}
