import XCTest

/// Each launch uses an ephemeral store, so tests never read or change the
/// developer's saved Gateways, conversations, or Keychain items.
@MainActor
private func launchIsolatedApp() -> XCUIApplication {
    let app = XCUIApplication()
    app.launchEnvironment["OHMYOPENCLAW_EPHEMERAL_STORE"] = "1"
    app.launch()
    return app
}

final class DemoSmokeTests: XCTestCase {
    /// The demo never contacts a Gateway or AI provider.
    @MainActor
    func testDemoShowsTheMainThreadAndItsHistory() throws {
        let app = launchIsolatedApp()
        let demo = app.buttons["tryDemo"]
        XCTAssertTrue(demo.waitForExistence(timeout: 10))
        demo.click()
        XCTAssertTrue(app.staticTexts["メインチャット"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["こんにちは。ここでは何ができる？"].waitForExistence(timeout: 10))
    }

    /// Errors from Gateway actions stay visible when only the Settings window is open.
    @MainActor
    func testConnectionFailureIsShownInSettings() throws {
        let app = launchIsolatedApp()
        let url = app.textFields["connectionURL"]
        XCTAssertTrue(url.waitForExistence(timeout: 10))
        url.click()
        url.typeText("ws://127.0.0.1:9")
        let secret = app.secureTextFields["connectionSecret"]
        secret.click()
        secret.typeText("synthetic-token")
        app.buttons["connectButton"].click()
        XCTAssertTrue(app.buttons["connectButton"].waitForExistence(timeout: 15))
        app.typeKey(",", modifierFlags: .command)
        XCTAssertTrue(app.staticTexts["settingsError"].waitForExistence(timeout: 15))
    }

    /// `just uitest` starts scripts/gateway-fixture.py --pairing and passes its URL.
    @MainActor
    func testFirstConnectionShowsPairingGuidance() throws {
        guard let fixture = ProcessInfo.processInfo.environment["OHMYOPENCLAW_PAIRING_FIXTURE"] else {
            throw XCTSkip("Run through `just uitest`, which starts the pairing fixture.")
        }
        let app = launchIsolatedApp()
        let url = app.textFields["connectionURL"]
        XCTAssertTrue(url.waitForExistence(timeout: 10))
        url.click()
        url.typeText(fixture)
        let secret = app.secureTextFields["connectionSecret"]
        secret.click()
        secret.typeText("synthetic-token")
        app.buttons["connectButton"].click()
        let commands = app.staticTexts["pairingCommands"]
        XCTAssertTrue(commands.waitForExistence(timeout: 15))
        XCTAssertTrue((commands.value as? String ?? commands.label).contains("openclaw devices approve req-fixture-1"))
    }
}
