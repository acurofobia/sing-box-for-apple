import XCTest

@MainActor
final class PrototypeLegalTests: XCTestCase {
    private func launch(largeText: Bool = false) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["PROTOTYPE_UI_TESTING"] = "1"
        app.launchEnvironment["PROTOTYPE_UI_RESET"] = "1"
        app.launchArguments += ["-AppleLanguages", "(ru)", "-AppleLocale", "ru_RU", "-prototype.privacy.reviewed.2026-10-22", "NO"]
        if largeText {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        }
        app.launch()
        return app
    }

    func testLegalDocumentsAreAvailableBeforeImport() {
        let app = launch()
        XCTAssertTrue(app.textFields["prototype.subscription.url"].waitForExistence(timeout: 15))
        app.swipeUp()
        app.buttons["prototype.legal.privacy"].tap()
        let text = app.textViews["prototype.legal.text"]
        XCTAssertTrue(text.waitForExistence(timeout: 5))
        let policy = text.value as? String ?? ""
        XCTAssertTrue(policy.contains("Sergey Mikhailov"))
        XCTAssertTrue(policy.contains("fusedased@gmail.com"))
        XCTAssertTrue(policy.contains("VK TURN"))
        attach("privacy-before-import")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["prototype.legal.licenses"].tap()
        let list = app.descendants(matching: .any)["prototype.legal.licenseList"].firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: 5))
        let search = app.searchFields.firstMatch
        search.tap()
        search.typeText("BinaryCodable")
        app.buttons.matching(NSPredicate(format: "label == %@", "BinaryCodable")).firstMatch.tap()
        XCTAssertTrue(text.waitForExistence(timeout: 5))
        XCTAssertTrue((text.value as? String ?? "").contains("MIT"))
        attach("licenses-before-import")
    }

    func testSourceInformationIsAvailableBeforeImport() {
        let app = launch()
        XCTAssertTrue(app.textFields["prototype.subscription.url"].waitForExistence(timeout: 15))
        app.swipeUp()
        app.buttons["prototype.legal.sources"].tap()
        let text = app.textViews["prototype.legal.text"]
        XCTAssertTrue(text.waitForExistence(timeout: 5))
        XCTAssertTrue((text.value as? String ?? "").contains("sing-box-for-apple"))
        app.buttons["Закрыть"].tap()
        XCTAssertTrue(app.buttons["prototype.legal.sources"].exists)
    }

    func testPrivacyPolicySupportsLargeText() {
        let app = launch(largeText: true)
        XCTAssertTrue(app.textFields["prototype.subscription.url"].waitForExistence(timeout: 15))
        for _ in 0 ..< 5 where !app.buttons["prototype.legal.privacy"].isHittable {
            app.swipeUp()
        }
        app.buttons["prototype.legal.privacy"].tap()
        let text = app.textViews["prototype.legal.text"]
        XCTAssertTrue(text.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(text.frame.width, 200)
        XCTAssertGreaterThan(text.frame.height, 200)
        text.swipeUp()
        attach("privacy-large-text")
    }

    func testProfileAndFirstConnectionProvideLocalPrivacyAccess() async throws {
        let control = try XCTUnwrap(URL(string: "http://localhost:18081/control/normal"))
        let (_, response) = try await URLSession.shared.data(from: control)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let app = launch()
        let input = app.textFields["prototype.subscription.url"]
        XCTAssertTrue(input.waitForExistence(timeout: 15))
        input.tap()
        input.typeText("http://localhost:18081/subscription/both\n")
        app.buttons["prototype.subscription.fetch"].tap()
        let profile = app.buttons.matching(NSPredicate(format: "label == %@", "Профиль")).firstMatch
        XCTAssertTrue(profile.waitForExistence(timeout: 20))
        profile.tap()
        for _ in 0 ..< 5 where !app.buttons["prototype.legal.privacy"].isHittable {
            app.swipeUp()
        }
        app.buttons["prototype.legal.privacy"].tap()
        XCTAssertTrue(app.textViews["prototype.legal.text"].waitForExistence(timeout: 5))
        app.buttons["Закрыть"].tap()
        app.buttons.matching(NSPredicate(format: "label == %@", "Подключение")).firstMatch.tap()
        let mode = app.buttons["prototype.mode"]
        XCTAssertTrue(mode.waitForExistence(timeout: 5))
        XCTAssertLessThanOrEqual(mode.frame.maxY, app.buttons["prototype.subscription.refresh"].frame.minY)
        app.buttons["prototype.start"].tap()
        let disclosure = app.alerts["Перед подключением"]
        XCTAssertTrue(disclosure.waitForExistence(timeout: 5))
        disclosure.buttons["Отмена"].tap()
        XCTAssertTrue(app.buttons["prototype.start"].exists)
        XCTAssertFalse(app.buttons["prototype.stop"].exists)
        app.buttons["prototype.start"].tap()
        disclosure.buttons["Политика конфиденциальности"].tap()
        XCTAssertTrue(app.textViews["prototype.legal.text"].waitForExistence(timeout: 5))
        attach("privacy-before-first-connection")
        app.buttons["Закрыть"].tap()
        XCTAssertTrue(app.buttons["prototype.start"].exists)
    }

    private func attach(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
