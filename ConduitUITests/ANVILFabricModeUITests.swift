import XCTest

/// Proves the ANVIL Fabric operator surface is independently reachable and
/// that an already-connected Hermes shell can cross the mode boundary without
/// signing out or requiring a real server.
final class ANVILFabricModeUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testFabricRootBypassesHermesLoginGate() {
        let app = XCUIApplication()
        app.launchArguments += ["-CONDUIT_UI_TEST_ANVIL_FABRIC"]
        app.launch()

        XCTAssertTrue(
            app.navigationBars["ANVIL Fabric"].waitForExistence(timeout: 10),
            "Standalone Fabric root did not appear. Tree:\n\(app.debugDescription)"
        )
        XCTAssertTrue(app.buttons["fabric.return-hermes"].exists)
        XCTAssertFalse(
            app.textFields["login.server-url"].exists,
            "Fabric must not require the Hermes login surface"
        )
    }

    func testConnectedShellCanEnterFabricAndReturnWithoutSignOut() {
        let app = XCUIApplication()
        app.launchArguments += [
            "-CONDUIT_UI_TEST_CONNECTED_DASHBOARD",
            "https://fabric-transition.example"
        ]
        app.launch()

        let sessions = app.buttons["Open sessions"]
        XCTAssertTrue(
            sessions.waitForExistence(timeout: 10),
            "Connected stub shell did not appear. Tree:\n\(app.debugDescription)"
        )
        sessions.tap()

        let openFabric = app.buttons["sidebar.open-anvil-fabric"]
        XCTAssertTrue(
            openFabric.waitForExistence(timeout: 5),
            "Connected sidebar has no standalone Fabric entry. Tree:\n\(app.debugDescription)"
        )
        openFabric.tap()

        XCTAssertTrue(
            app.navigationBars["ANVIL Fabric"].waitForExistence(timeout: 10),
            "Connected-to-Fabric transition failed. Tree:\n\(app.debugDescription)"
        )
        XCTAssertFalse(app.textFields["login.server-url"].exists)

        let returnHermes = app.buttons["fabric.return-hermes"]
        XCTAssertTrue(returnHermes.waitForExistence(timeout: 5))
        returnHermes.tap()

        XCTAssertTrue(
            app.buttons["Open sessions"].waitForExistence(timeout: 10),
            "Returning from Fabric did not restore the inert Hermes shell. Tree:\n\(app.debugDescription)"
        )
    }
}
