import XCTest

/// Drives the built-in demo; it never contacts a Gateway or AI provider.
final class DemoSmokeTests: XCTestCase {
    @MainActor
    func testDemoShowsTheMainThreadAndItsHistory() throws {
        let app = XCUIApplication()
        app.launch()
        let demo = app.buttons["tryDemo"]
        if demo.waitForExistence(timeout: 5) { demo.click() }
        XCTAssertTrue(app.outlines.cells.containing(.staticText, identifier: "メインチャット").firstMatch.waitForExistence(timeout: 10) || app.staticTexts["メインチャット"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["こんにちは。ここでは何ができる？"].waitForExistence(timeout: 10))
    }
}
