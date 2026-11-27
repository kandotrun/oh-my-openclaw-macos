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

/// Selectable text exposes its content as the element's value, plain text as its label.
@MainActor
private func text(containing fragment: String, in element: XCUIElement) -> XCUIElement {
    element.staticTexts.matching(NSPredicate(format: "value CONTAINS %@ OR label CONTAINS %@", fragment, fragment)).firstMatch
}

/// Connects through the first-run form with a synthetic token.
@MainActor
private func connect(_ app: XCUIApplication, to gateway: String) {
    let url = app.textFields["connectionURL"]
    XCTAssertTrue(url.waitForExistence(timeout: 10))
    url.click()
    url.typeText(gateway)
    let secret = app.secureTextFields["connectionSecret"]
    secret.click()
    secret.typeText("synthetic-token")
    app.buttons["connectButton"].click()
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

    /// In a shared thread, teammates sit on the left with their name, and my messages stay on the right.
    @MainActor
    func testTeamThreadShowsTeammatesOnTheLeft() throws {
        let app = launchIsolatedApp()
        let demo = app.buttons["tryDemo"]
        XCTAssertTrue(demo.waitForExistence(timeout: 10))
        demo.click()
        let team = app.staticTexts["チームの作業"].firstMatch
        XCTAssertTrue(team.waitForExistence(timeout: 10))
        team.click()
        let peer = app.descendants(matching: .any).matching(identifier: "peerMessage").firstMatch
        XCTAssertTrue(peer.waitForExistence(timeout: 10))
        XCTAssertTrue(peer.staticTexts["佐藤 花子"].exists)
        let own = app.descendants(matching: .any).matching(identifier: "ownMessage").firstMatch
        XCTAssertTrue(own.waitForExistence(timeout: 5))
        let peerText = text(containing: "UI テストが時々落ちます", in: peer)
        let ownText = text(containing: "PR を作っておいて", in: own)
        XCTAssertTrue(peerText.exists && ownText.exists)
        XCTAssertLessThan(peerText.frame.midX, ownText.frame.midX)
        let screenshot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        screenshot.name = "team-thread"
        screenshot.lifetime = .keepAlways
        add(screenshot)
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
        connect(app, to: fixture)
        let commands = app.staticTexts["pairingCommands"]
        XCTAssertTrue(commands.waitForExistence(timeout: 15))
        XCTAssertTrue((commands.value as? String ?? commands.label).contains("openclaw devices approve req-fixture-1"))
    }

    /// `just uitest` starts scripts/gateway-fixture.py --question, whose main thread waits on an answer.
    @MainActor
    func testUnsentQuestionAnswerSurvivesSwitchingThreads() throws {
        guard let fixture = ProcessInfo.processInfo.environment["OHMYOPENCLAW_QUESTION_FIXTURE"] else {
            throw XCTSkip("Run through `just uitest`, which starts the question fixture.")
        }
        let app = launchIsolatedApp()
        connect(app, to: fixture)
        let answer = app.textFields["promptAnswerField"]
        XCTAssertTrue(answer.waitForExistence(timeout: 15))
        answer.click()
        answer.typeText("Start from main")
        app.buttons["newThreadButton"].click()
        XCTAssertTrue(answer.waitForNonExistence(timeout: 5))
        app.descendants(matching: .any).matching(identifier: "mainThreadRow").firstMatch.click()
        XCTAssertTrue(answer.waitForExistence(timeout: 10))
        XCTAssertEqual(answer.value as? String, "Start from main")
    }

    /// `just uitest` starts scripts/gateway-fixture.py --access, which sends upgrades without a
    /// Cloudflare Access service token to a login page, as a Gateway behind Access does.
    @MainActor
    func testServiceTokenGetsThroughCloudflareAccess() throws {
        guard let fixture = ProcessInfo.processInfo.environment["OHMYOPENCLAW_ACCESS_FIXTURE"] else {
            throw XCTSkip("Run through `just uitest`, which starts the access fixture.")
        }
        let app = launchIsolatedApp()
        connect(app, to: fixture)
        XCTAssertTrue(text(containing: "Cloudflare Access のログイン", in: app).waitForExistence(timeout: 15))
        let clientID = app.textFields["accessClientID"]
        clientID.click()
        clientID.typeText("fixture-access.access")
        // One field alone is not a token: the form says so instead of connecting without it.
        XCTAssertTrue(app.staticTexts["accessIncomplete"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["connectButton"].isEnabled)
        let clientSecret = app.secureTextFields["accessClientSecret"]
        clientSecret.click()
        clientSecret.typeText("fixture-access-secret")
        let token = app.secureTextFields["connectionSecret"]
        token.click()
        token.typeText("synthetic-token")
        app.buttons["connectButton"].click()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "mainThreadRow").firstMatch.waitForExistence(timeout: 15))
    }

    /// `just uitest` starts scripts/gateway-fixture.py --shared, whose main thread holds a teammate's message.
    /// The fixture names this connection's profile in `hello-ok` and stamps it on every send.
    @MainActor
    func testSharedGatewayKeepsTheTeammateLeftAndMyMessageRight() throws {
        guard let fixture = ProcessInfo.processInfo.environment["OHMYOPENCLAW_SHARED_FIXTURE"] else {
            throw XCTSkip("Run through `just uitest`, which starts the shared fixture.")
        }
        let app = launchIsolatedApp()
        connect(app, to: fixture)
        let peers = app.descendants(matching: .any).matching(identifier: "peerMessage")
        XCTAssertTrue(peers.firstMatch.waitForExistence(timeout: 15))
        XCTAssertTrue(peers.firstMatch.staticTexts["Peer Person"].exists)
        let composer = app.textViews["composerText"]
        composer.click()
        composer.typeText("On it")
        composer.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(text(containing: "synthetic WebSocket response", in: app).waitForExistence(timeout: 20))
        // The teammate answers while my run settles. Only the history reload shows that answer, and the
        // same reload replaces my local copy with the stored row and its profile.
        XCTAssertTrue(text(containing: "Thanks, I'll review it.", in: app).waitForExistence(timeout: 10))
        XCTAssertEqual(peers.count, 2)
        // My message is the thread's only own row: one copy, not the local copy beside the stored one.
        let own = app.descendants(matching: .any).matching(identifier: "ownMessage")
        XCTAssertEqual(own.count, 1)
        XCTAssertTrue(text(containing: "On it", in: own.firstMatch).exists)
    }
}
