import XCTest

final class AniPolkaUITests: XCTestCase {
    let app = XCUIApplication()
    override func setUpWithError() throws { continueAfterFailure = false }
    func start(reset: Bool = true, extra: [String] = []) {
        app.launchArguments = ["--demo"] + (reset ? ["--reset"] : []) + ["-AppleLanguages","(ru)","-AppleLocale","ru_RU"] + extra
        app.launch(); XCTAssertTrue(app.tabBars.buttons["Коллекция"].waitForExistence(timeout:15))
    }
    func capture(_ name: String) { let a = XCTAttachment(screenshot:app.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a) }
    func testCollectionProgressUndoAndPersistence() {
        start(); capture("collection-dark")
        let increment = app.buttons.matching(NSPredicate(format:"identifier BEGINSWITH 'increment-'")).firstMatch
        XCTAssertTrue(increment.waitForExistence(timeout:5)); increment.tap()
        XCTAssertTrue(app.buttons["undo"].waitForExistence(timeout:3)); app.buttons["undo"].tap()
        increment.tap(); app.terminate(); start(reset:false)
        XCTAssertTrue(app.staticTexts["Последняя серия: 25"].firstMatch.waitForExistence(timeout:5))
        app.tabBars.buttons["Избранное"].tap(); capture("favorites")
    }
    func testSettingsAndLightTheme() {
        start(); app.tabBars.buttons["Настройки"].tap(); capture("settings-dark")
        app.buttons["theme"].tap(); app.buttons["Светлое"].tap()
        app.tabBars.buttons["Коллекция"].tap(); capture("collection-light")
        app.swipeUp(); app.swipeUp(); capture("long-title")
    }
    func testManualAddEditAndImportPreview() {
        start(); app.buttons["add"].tap(); app.buttons["manual-add"].tap()
        let title = app.textFields["entry-title"]
        // Multiline SwiftUI TextField may be exposed as a text view.
        let titleField = title.exists ? title : app.textViews["entry-title"]
        XCTAssertTrue(titleField.waitForExistence(timeout:5)); titleField.tap(); titleField.typeText("Тестовая история")
        let episode = app.textFields["entry-episode"]; episode.tap(); episode.typeText("7")
        app.buttons["save-entry"].tap()
        XCTAssertTrue(app.staticTexts["Тестовая история"].firstMatch.waitForExistence(timeout:5))
        app.tabBars.buttons["Настройки"].tap(); app.buttons["text-import"].tap()
        let input = app.textViews["import-text"]; XCTAssertTrue(input.waitForExistence(timeout:5)); input.tap(); input.typeText("Неисправленнае название 33\nБез номера")
        app.buttons["preview-import"].tap(); capture("text-import-review")
        app.swipeUp(); app.buttons["apply-import"].tap()
        app.tabBars.buttons["Коллекция"].tap(); app.swipeUp(); capture("imported-collection")
    }
    func testAccessibilityLargeType() {
        start(extra:["-UIPreferredContentSizeCategoryName","UICTContentSizeCategoryAccessibilityXXXL"])
        capture("accessibility-large"); app.swipeUp(); capture("accessibility-long-title")
        app.tabBars.buttons["Настройки"].tap(); capture("accessibility-settings")
    }
}
