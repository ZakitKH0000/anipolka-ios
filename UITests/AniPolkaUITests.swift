import XCTest

final class AniPolkaUITests: XCTestCase {
    let app = XCUIApplication()
    override func setUpWithError() throws { continueAfterFailure = false }
    func start(reset: Bool = true, extra: [String] = []) {
        app.launchArguments = ["--demo"] + (reset ? ["--reset"] : []) + ["-AppleLanguages","(ru)","-AppleLocale","ru_RU"] + extra
        app.launch(); XCTAssertTrue(app.tabBars.buttons["Коллекция"].waitForExistence(timeout:15))
    }
    func capture(_ name: String) { let a = XCTAttachment(screenshot:app.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a) }
    func reveal(_ element: XCUIElement) {
        for _ in 0..<8 { if element.isHittable { return }; app.swipeUp() }
    }
    func testCollectionProgressUndoAndPersistence() {
        start(); capture("collection-dark")
        let increment = app.buttons.matching(NSPredicate(format:"identifier BEGINSWITH 'increment-'")).firstMatch
        XCTAssertTrue(increment.waitForExistence(timeout:5)); increment.tap()
        XCTAssertTrue(app.buttons["undo"].waitForExistence(timeout:3)); app.buttons["undo"].tap()
        increment.tap(); app.terminate(); start(reset:false)
        XCTAssertTrue(app.staticTexts["Серия 25"].firstMatch.waitForExistence(timeout:5))
        app.buttons["filter-favorites"].tap(); capture("favorites")
    }
    func testSettingsAndLightTheme() {
        start(); app.tabBars.buttons["Настройки"].tap(); capture("settings-dark")
        app.buttons["theme"].tap(); app.buttons["Светлое"].tap()
        app.tabBars.buttons["Коллекция"].tap(); capture("collection-light")
        app.swipeUp(); app.swipeUp(); capture("long-title")
    }
    func testManualAddEditAndImportPreview() {
        start(); app.buttons["add"].tap(); app.buttons["manual-add"].tap()
        XCTAssertTrue(app.staticTexts["wizard-step-title"].waitForExistence(timeout:5)); capture("wizard-progress-step")
        let title = app.textFields["entry-title"]
        // Multiline SwiftUI TextField may be exposed as a text view.
        let titleField = title.exists ? title : app.textViews["entry-title"]
        XCTAssertTrue(titleField.waitForExistence(timeout:5)); titleField.tap(); titleField.typeText("Тестовая история")
        let episode = app.textFields["entry-episode"]; episode.tap(); episode.typeText("7")
        app.buttons["wizard-next"].tap()
        XCTAssertTrue(app.buttons["find-anivibe"].waitForExistence(timeout:5)); capture("wizard-source-step")
        app.buttons["wizard-next"].tap()
        XCTAssertTrue(app.buttons["wizard-finish"].waitForExistence(timeout:5)); capture("wizard-finish-step")
        app.buttons["wizard-finish"].tap()
        // Cards are one accessibility element each: «название, серия N».
        let added = app.buttons.matching(NSPredicate(format:"label BEGINSWITH 'Тестовая история'")).firstMatch
        XCTAssertTrue(added.waitForExistence(timeout:5))
        app.tabBars.buttons["Настройки"].tap(); reveal(app.buttons["text-import"]); app.buttons["text-import"].tap()
        let input = app.textViews["import-text"]; XCTAssertTrue(input.waitForExistence(timeout:5)); input.tap(); input.typeText("Неисправленнае название 33\nБез номера")
        reveal(app.buttons["preview-import"]); app.buttons["preview-import"].tap(); capture("text-import-review")
        reveal(app.buttons["apply-import"]); app.buttons["apply-import"].tap()
        app.tabBars.buttons["Коллекция"].tap(); app.swipeUp(); capture("imported-collection")
    }
    func testAccessibilityLargeType() {
        start(extra:["-UIPreferredContentSizeCategoryName","UICTContentSizeCategoryAccessibilityXXXL"])
        capture("accessibility-large"); app.swipeUp(); capture("accessibility-long-title")
        app.tabBars.buttons["Настройки"].tap(); capture("accessibility-settings")
    }
    func testReleaseInboxAndPublicSourceInspection() {
        start(); app.tabBars.buttons["Серии"].tap(); capture("release-inbox")
        app.buttons["release-entry"].tap()
        XCTAssertTrue(app.buttons["edit-entry"].waitForExistence(timeout:5))
        reveal(app.buttons["entry-sources"]); app.buttons["entry-sources"].tap()
        XCTAssertTrue(app.buttons["inspect-source"].waitForExistence(timeout:5)); capture("episode-sources")
        app.buttons["inspect-source"].tap()
        XCTAssertTrue(app.buttons["source-option-kodik-910-1"].waitForExistence(timeout:30))
        capture("public-source-options")
    }
    func testTextReportPreviewStylesAndCopy() {
        start(); app.tabBars.buttons["Настройки"].tap()
        reveal(app.buttons["open-report"]); app.buttons["open-report"].tap()
        let preview = app.staticTexts["report-preview"]
        XCTAssertTrue(preview.waitForExistence(timeout:5)); capture("text-report")
        XCTAssertTrue(preview.label.contains("остановился на серии"))
        app.segmentedControls["report-style"].buttons["Для ИИ"].tap()
        XCTAssertTrue(app.staticTexts["report-preview"].label.contains("Это мой личный список аниме"))
        reveal(app.buttons["report-copy"]); app.buttons["report-copy"].tap()
        expectation(for:NSPredicate(format:"label CONTAINS 'Скопировано'"),evaluatedWith:app.buttons["report-copy"])
        waitForExpectations(timeout:5)
    }
    func testKitsuDonghuaSearchAndCoverSelection() {
        start(); app.buttons["add"].tap()
        let scope = app.segmentedControls["catalog-provider"]
        XCTAssertTrue(scope.waitForExistence(timeout:5)); scope.buttons["Kitsu"].tap()
        let query = app.textFields["catalog-query"]; query.tap(); query.typeText("Tunshi Xingkong")
        app.buttons["catalog-search"].tap()
        let result = app.buttons.matching(NSPredicate(format:"identifier BEGINSWITH 'wizard-result-' AND label == 'Tunshi Xingkong'")).firstMatch
        XCTAssertTrue(result.waitForExistence(timeout:30)); capture("kitsu-donghua-results"); result.tap()
        let field = app.textFields["entry-title"].exists ? app.textFields["entry-title"] : app.textViews["entry-title"]
        XCTAssertTrue(field.waitForExistence(timeout:5)); XCTAssertEqual(field.value as? String,"Tunshi Xingkong")
        capture("kitsu-selected-cover")
    }
    func testAutomaticDonghuaCoverIsCachedAndKeepsProgressAfterRelaunch() {
        start(extra:["--live-covers"])
        app.buttons["Открыть Tunshi Xingkong"].tap()
        let cached = app.descendants(matching:.any).matching(identifier:"cached-auto-cover").firstMatch
        XCTAssertTrue(cached.waitForExistence(timeout:60)); reveal(cached); capture("automatic-donghua-cover")
        XCTAssertTrue(app.staticTexts["Серия 24"].exists)
        app.terminate(); start(reset:false,extra:["--live-covers"])
        app.buttons["Открыть Tunshi Xingkong"].tap()
        XCTAssertTrue(cached.waitForExistence(timeout:5)); XCTAssertTrue(app.staticTexts["Серия 24"].exists)
    }
}
