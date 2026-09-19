//
//  RoomHubCredentialTests.swift
//  Conduit
//
//  ANVIL Room Hub credential isolation. The production store uses the iOS
//  Keychain; tests inject a per-test in-memory backend without touching
//  upstream Conduit's KeychainHelper implementation.
//

import Foundation
import XCTest
@testable import Conduit

private final class InMemoryRoomHubCredentialBackend: RoomHubCredentialBackend {
    private var storage: [String: Data] = [:]

    func data(account: String) -> Data? {
        storage[account]
    }

    func save(_ data: Data, account: String) -> Bool {
        storage[account] = data
        return true
    }

    func delete(account: String) {
        storage.removeValue(forKey: account)
    }
}

final class RoomHubCredentialTests: XCTestCase {
    private var store: RoomHubCredentialStore!

    override func setUp() {
        super.setUp()
        store = RoomHubCredentialStore(backend: InMemoryRoomHubCredentialBackend())
    }

    override func tearDown() {
        store = nil
        super.tearDown()
    }

    func testSaveLoadRoundTripWithinDashboard() {
        let dashboard = UUID()
        let credential = RoomHubCredential(hubBaseURL: "https://hub.test", token: "token-a")

        XCTAssertTrue(store.save(credential, dashboardID: dashboard))
        XCTAssertEqual(store.load(dashboardID: dashboard), credential)
    }

    func testCredentialCannotLeakAcrossDashboards() {
        let dashboardA = UUID()
        let dashboardB = UUID()

        XCTAssertTrue(store.save(
            RoomHubCredential(hubBaseURL: "https://hub-a.test", token: "token-a"),
            dashboardID: dashboardA
        ))
        XCTAssertTrue(store.save(
            RoomHubCredential(hubBaseURL: "https://hub-b.test", token: "token-b"),
            dashboardID: dashboardB
        ))

        XCTAssertEqual(store.load(dashboardID: dashboardA)?.token, "token-a")
        XCTAssertEqual(
            store.load(dashboardID: dashboardB)?.token,
            "token-b",
            "Dashboard B must never read dashboard A's token"
        )
    }

    func testClearingOneDashboardLeavesTheOtherUntouched() {
        let dashboardA = UUID()
        let dashboardB = UUID()

        XCTAssertTrue(store.save(
            RoomHubCredential(hubBaseURL: "https://hub-a.test", token: "token-a"),
            dashboardID: dashboardA
        ))
        XCTAssertTrue(store.save(
            RoomHubCredential(hubBaseURL: "https://hub-b.test", token: "token-b"),
            dashboardID: dashboardB
        ))

        store.clear(dashboardID: dashboardA)

        XCTAssertNil(store.load(dashboardID: dashboardA))
        XCTAssertEqual(store.load(dashboardID: dashboardB)?.token, "token-b")
    }

    func testOverwriteReplacesOnlySameDashboardRecord() {
        let dashboardA = UUID()
        let dashboardB = UUID()

        XCTAssertTrue(store.save(
            RoomHubCredential(hubBaseURL: "https://hub-a.test", token: "old"),
            dashboardID: dashboardA
        ))
        XCTAssertTrue(store.save(
            RoomHubCredential(hubBaseURL: "https://hub-b.test", token: "token-b"),
            dashboardID: dashboardB
        ))
        XCTAssertTrue(store.save(
            RoomHubCredential(hubBaseURL: "https://hub-a2.test", token: "new"),
            dashboardID: dashboardA
        ))

        XCTAssertEqual(
            store.load(dashboardID: dashboardA),
            RoomHubCredential(hubBaseURL: "https://hub-a2.test", token: "new")
        )
        XCTAssertEqual(store.load(dashboardID: dashboardB)?.token, "token-b")
    }

    @MainActor
    func testForDashboardUsesInjectedScopedCredentialStore() throws {
        let dashboardA = UUID()
        let dashboardB = UUID()

        XCTAssertTrue(store.save(
            RoomHubCredential(hubBaseURL: "https://hub-a.test", token: "token-a"),
            dashboardID: dashboardA
        ))

        let clientA = try RoomProjectionClient.forDashboard(
            dashboardA,
            credentialStore: store
        )
        XCTAssertEqual(clientA.credential.token, "token-a")
        XCTAssertEqual(clientA.credential.hubBaseURL, "https://hub-a.test")

        XCTAssertThrowsError(
            try RoomProjectionClient.forDashboard(
                dashboardB,
                credentialStore: store
            )
        ) { error in
            guard case RoomProjectionError.missingCredential = error else {
                return XCTFail("Dashboard B must see missingCredential, got \(error)")
            }
        }
    }
}
