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

    /// Threads can be added one after another from the sidebar.
    @MainActor
    func testSidebarButtonAddsThreads() throws {
        let app = launchIsolatedApp()
        let demo = app.buttons["tryDemo"]
        XCTAssertTrue(demo.waitForExistence(timeout: 10))
        demo.click()
        XCTAssertTrue(app.staticTexts["メインチャット"].waitForExistence(timeout: 10))
        let before = app.descendants(matching: .any).matching(identifier: "threadRow").count
        let newThread = app.buttons["newThreadButton"]
        XCTAssertTrue(newThread.waitForExistence(timeout: 5))
        newThread.click()
        newThread.click()
        let rows = app.descendants(matching: .any).matching(identifier: "threadRow")
        let deadline = Date().addingTimeInterval(10)
        while rows.count < before + 2 && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.2)) }
        XCTAssertEqual(rows.count, before + 2)
    }

    /// Return sends; Shift-Return adds a line without sending.
    @MainActor
    func testComposerSendsWithReturnAndShiftReturnAddsALine() throws {
        let app = launchIsolatedApp()
        let demo = app.buttons["tryDemo"]
        XCTAssertTrue(demo.waitForExistence(timeout: 10))
        demo.click()
        let composer = app.textViews["composerText"]
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        composer.click()
        composer.typeText("一行目")
        composer.typeKey(.return, modifierFlags: .shift)
        composer.typeText("二行目")
        XCTAssertEqual(composer.value as? String, "一行目\n二行目")
        XCTAssertFalse(app.staticTexts["一行目\n二行目"].exists)
        composer.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(app.staticTexts["一行目\n二行目"].waitForExistence(timeout: 10))
        XCTAssertEqual(composer.value as? String, "")
        // Selectable text exposes its content as the element's value.
        let reply = app.staticTexts.matching(NSPredicate(format: "value CONTAINS %@ OR label CONTAINS %@", "について、一緒に考えましょう", "について、一緒に考えましょう")).firstMatch
        XCTAssertTrue(reply.waitForExistence(timeout: 20))
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
        let error = app.staticTexts["settingsError"]
        XCTAssertTrue(error.waitForExistence(timeout: 15))
        app.buttons["dismissSettingsError"].click()
        XCTAssertTrue(error.waitForNonExistence(timeout: 5))
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
