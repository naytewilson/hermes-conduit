import XCTest

/// Proves the ANVIL Fabric operator surface is reachable in a clean app
/// process without manufacturing or restoring a Hermes dashboard connection.
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
}
