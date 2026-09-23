//
//  ANVILFabricModeTests.swift
//  ConduitTests
//
//  Proves the standalone Fabric identity and startup jurisdiction:
//  Fabric state is stable and independent, and persisted Fabric mode prevents
//  AppState from reviving a saved Hermes connection behind the operator.
//

import XCTest
@testable import Conduit

@MainActor
final class ANVILFabricModeTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var backend: InMemoryKeychainBackend!

    override func setUp() {
        super.setUp()
        suiteName = "ANVILFabricModeTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        backend = InMemoryKeychainBackend()
        KeychainHelper.useBackendForTesting(backend)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        KeychainHelper.clearDashboardRegistry()
        KeychainHelper.clearConnection()
        KeychainHelper.clearCredentials()
        KeychainHelper.clearCloudflareAccess()
        KeychainHelper.useBackendForTesting(KeychainHelper.SystemKeychainBackend())
        backend = nil
        defaults = nil
        super.tearDown()
    }

    func testWorkspaceIDIsStableAndIndependentOfHermesDashboardRegistry() {
        let expected = UUID(uuidString: "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE")!

        let first = ANVILFabricModeStore.workspaceID(
            defaults: defaults,
            makeUUID: { expected }
        )
        let second = ANVILFabricModeStore.workspaceID(
            defaults: defaults,
            makeUUID: { XCTFail("stable workspace must not mint twice"); return UUID() }
        )

        XCTAssertEqual(first, expected)
        XCTAssertEqual(second, expected)
        XCTAssertEqual(
            defaults.string(forKey: ANVILFabricModeStore.workspaceIDKey),
            expected.uuidString
        )
        XCTAssertNil(SavedDashboardRegistryStore.load())
    }

    func testMalformedWorkspaceIDIsReplacedDeterministically() {
        defaults.set("not-a-uuid", forKey: ANVILFabricModeStore.workspaceIDKey)
        let replacement = UUID(uuidString: "11111111-2222-4333-8444-555555555555")!

        let resolved = ANVILFabricModeStore.workspaceID(
            defaults: defaults,
            makeUUID: { replacement }
        )

        XCTAssertEqual(resolved, replacement)
        XCTAssertEqual(
            defaults.string(forKey: ANVILFabricModeStore.workspaceIDKey),
            replacement.uuidString
        )
    }

    func testFabricModeFlagRoundTripsWithoutCreatingHermesState() {
        XCTAssertFalse(ANVILFabricModeStore.isEnabled(defaults: defaults))

        ANVILFabricModeStore.setEnabled(true, defaults: defaults)

        XCTAssertTrue(ANVILFabricModeStore.isEnabled(defaults: defaults))
        XCTAssertNil(SavedDashboardRegistryStore.load())
        XCTAssertNil(KeychainHelper.loadConnection())
    }

    func testEnteringFabricRetiresLiveHermesButPreservesSavedAuth() throws {
        let dashboardID = UUID()
        let saved = HermesConnection(
            baseUrl: "https://hermes.example.test",
            ticket: "saved-ticket"
        )
        KeychainHelper.saveConnection(saved, dashboardID: dashboardID)
        let registry = SavedDashboardRegistry(
            activeDashboardID: dashboardID,
            dashboards: [
                SavedDashboard(
                    id: dashboardID,
                    label: "Hermes",
                    normalizedURL: saved.baseUrl
                )
            ]
        )
        let state = AppState(
            defaults: defaults,
            loadSavedConnection: false,
            dashboardRegistry: registry
        )
        state.connection = saved
        state.isConnected = true
        state.isConnecting = false
        state.showLogin = false

        state.enterANVILFabricMode()

        XCTAssertTrue(ANVILFabricModeStore.isEnabled(defaults: defaults))
        XCTAssertNil(state.connection)
        XCTAssertFalse(state.isConnected)
        XCTAssertFalse(state.isConnecting)

        let preserved = try XCTUnwrap(KeychainHelper.loadConnection(dashboardID: dashboardID))
        XCTAssertEqual(preserved.baseUrl, saved.baseUrl)
        XCTAssertEqual(preserved.ticket, saved.ticket)
        XCTAssertEqual(state.activeDashboardID, dashboardID)
    }

    func testPersistedFabricModeSuppressesSavedHermesAutoRestore() {
        let dashboardID = UUID()
        let saved = HermesConnection(
            baseUrl: "https://hermes.example.test",
            ticket: "saved-ticket"
        )
        KeychainHelper.saveConnection(saved, dashboardID: dashboardID)
        let registry = SavedDashboardRegistry(
            activeDashboardID: dashboardID,
            dashboards: [
                SavedDashboard(
                    id: dashboardID,
                    label: "Hermes",
                    normalizedURL: saved.baseUrl
                )
            ]
        )
        ANVILFabricModeStore.setEnabled(true, defaults: defaults)

        let state = AppState(
            defaults: defaults,
            loadSavedConnection: true,
            dashboardRegistry: registry
        )

        XCTAssertNil(
            state.connection,
            "Fabric startup must not restore a Hermes transport in the background"
        )
        XCTAssertFalse(state.isConnecting)
        XCTAssertTrue(state.showLogin)
        XCTAssertEqual(state.activeDashboardID, dashboardID)
    }
}
