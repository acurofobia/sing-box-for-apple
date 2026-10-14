import XCTest

@MainActor
final class PrototypeSmokeTests: XCTestCase {
    private let node = """
    {"route":{"final":"discard"},"outbounds":[{"type":"vless","tag":"test","server":"example.org","server_port":443,"uuid":"bf000d23-0752-40b4-affe-68f7707a9661"}]}
    """

    override func setUp() {
        continueAfterFailure = false
    }

    private func launchEmpty() -> XCUIApplication {
        let app = XCUIApplication()
        app.terminate()
        app.launch()
        let clear = app.buttons["prototype.configs.clear"]
        XCTAssertTrue(clear.waitForExistence(timeout: 10))
        clear.tap()
        app.buttons["prototype.links.reveal"].tap()
        return app
    }

    private func importVLESS(_ app: XCUIApplication) {
        app.buttons["prototype.vless.paste"].tap()
        let input = app.textViews["prototype.vless.json"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.tap()
        input.typeText(node)
        app.buttons["Импортировать"].tap()
    }

    private func importVK(_ app: XCUIApplication) {
        app.swipeUp()
        let input = app.textFields["wdtt://… или vkturnproxy://…"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.tap()
        app.typeText("wdtt://example.org:443:a:b:password:call")
        XCTAssertEqual(input.value as? String, "wdtt://example.org:443:a:b:password:call")
        let save = app.buttons["prototype.vk.save"]
        if !save.isHittable { app.swipeUp() }
        XCTAssertTrue(save.isHittable)
        save.tap()
        let saved = NSPredicate(format: "label == %@", "Заменить ссылку")
        let savedExpectation = XCTNSPredicateExpectation(predicate: saved, object: save)
        if XCTWaiter.wait(for: [savedExpectation], timeout: 3) != .completed {
            app.swipeUp()
            let failure = XCTAttachment(screenshot: app.screenshot())
            failure.lifetime = .keepAlways
            add(failure)
            XCTFail("VK link was not saved; inspect the visible import error")
        }
        app.swipeDown()
        let evidence = XCTAttachment(screenshot: app.screenshot())
        evidence.lifetime = .keepAlways
        add(evidence)
    }

    func testSubscriptionURLRemainsVisibleWhenLinksAreHidden() {
        let app = launchEmpty()
        app.buttons["prototype.links.reveal"].tap()
        let input = app.textFields["prototype.subscription.url"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        XCTAssertFalse(app.secureTextFields["prototype.subscription.url"].exists)
        input.tap()
        input.typeText("http://localhost:18081/subscription/both")
        XCTAssertEqual(input.value as? String, "http://localhost:18081/subscription/both")
        app.buttons["prototype.links.reveal"].tap()
        XCTAssertEqual(input.value as? String, "http://localhost:18081/subscription/both")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    func testRoutingChoicePersistsAndDoesNotStartVPN() {
        let app = launchEmpty()
        app.tabBars.buttons["Роутинги"].tap()
        let picker = app.segmentedControls["prototype.routing.mode"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        picker.buttons["Russia inside"].tap()
        XCTAssertTrue(picker.buttons["Russia inside"].isSelected)
        app.tabBars.buttons["VPN"].tap()
        app.buttons["prototype.logs"].tap()
        XCTAssertTrue(app.staticTexts["VPN отключён"].waitForExistence(timeout: 5))
        app.terminate()
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Роутинги"].waitForExistence(timeout: 10))
        app.tabBars.buttons["Роутинги"].tap()
        XCTAssertTrue(picker.buttons["Russia inside"].isSelected)
        picker.buttons["С роутингом"].tap()
        XCTAssertTrue(picker.buttons["С роутингом"].isSelected)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    func testModePickerShowsSelectedModeAndPreservesChoice() {
        let app = launchEmpty()
        importVLESS(app)
        importVK(app)
        let picker = app.segmentedControls["prototype.mode"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        let vless = picker.buttons["VLESS"]
        let vk = picker.buttons["VK TURN"]
        XCTAssertTrue(vless.isSelected)
        XCTAssertFalse(vk.isSelected)
        vk.tap()
        XCTAssertTrue(vk.isSelected)
        XCTAssertFalse(vless.isSelected)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.terminate()
        app.launch()
        XCTAssertTrue(picker.waitForExistence(timeout: 10))
        XCTAssertTrue(vk.isSelected)
        XCTAssertFalse(vless.isSelected)
        vless.tap()
        XCTAssertTrue(vless.isSelected)
        XCTAssertFalse(vk.isSelected)
        app.buttons["prototype.configs.clear"].tap()
    }

    func testSubscriptionUpdateRemovesUnavailableModesAndRetainsCacheOnHTTPError() {
        let app = launchEmpty()
        func fetch(_ mode: String) {
            let input = app.textFields["prototype.subscription.url"]
            input.tap()
            if (input.value as? String)?.hasPrefix("http://") == true {
                input.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.5)).tap()
                app.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 100))
            }
            app.typeText("http://localhost:18081/subscription/" + mode)
            XCTAssertEqual(input.value as? String, "http://localhost:18081/subscription/" + mode)
            app.buttons["prototype.subscription.fetch"].tap()
        }
        func waitEnabled(_ id: String, _ enabled: Bool) {
            let predicate = NSPredicate(format: "enabled == %@", NSNumber(value: enabled))
            let expectation = XCTNSPredicateExpectation(predicate: predicate, object: app.segmentedControls["prototype.mode"].buttons[id == "prototype.mode.vless" ? "VLESS" : "VK TURN"])
            let result = XCTWaiter.wait(for: [expectation], timeout: 10)
            if result != .completed {
                app.swipeUp()
                let screenshot = XCTAttachment(screenshot: app.screenshot())
                screenshot.lifetime = .keepAlways
                add(screenshot)
            }
            XCTAssertEqual(result, .completed)
        }
        fetch("both")
        waitEnabled("prototype.mode.vless", true)
        waitEnabled("prototype.mode.vk-turn", true)
        XCTAssertFalse(app.staticTexts["Test"].exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.lifetime = .keepAlways
        add(screenshot)
        fetch("config-error")
        app.swipeUp()
        XCTAssertTrue(app.staticTexts["Не удалось получить подписку (HTTP 404)."].waitForExistence(timeout: 10))
        app.swipeDown()
        waitEnabled("prototype.mode.vless", true)
        waitEnabled("prototype.mode.vk-turn", true)
        fetch("vless")
        waitEnabled("prototype.mode.vk-turn", false)
        waitEnabled("prototype.mode.vless", true)
        fetch("error")
        app.swipeUp()
        XCTAssertTrue(app.staticTexts["Не удалось получить подписку (HTTP 404)."].waitForExistence(timeout: 10))
        app.swipeDown()
        waitEnabled("prototype.mode.vless", true)
        fetch("vk")
        waitEnabled("prototype.mode.vless", false)
        waitEnabled("prototype.mode.vk-turn", true)
        fetch("empty")
        waitEnabled("prototype.mode.vk-turn", false)
        waitEnabled("prototype.mode.vless", false)
        app.buttons["prototype.configs.clear"].tap()
    }

    func testMissingConfigurationsDisableBothModes() {
        let app = launchEmpty()
        XCTAssertFalse(app.segmentedControls["prototype.mode"].buttons["VLESS"].isEnabled)
        XCTAssertFalse(app.segmentedControls["prototype.mode"].buttons["VK TURN"].isEnabled)
        app.swipeUp()
        XCTAssertFalse(app.buttons["prototype.start"].isEnabled)
    }

    func testVLESSImportEnablesOnlyVLESSAndPersistsAfterRelaunch() {
        let app = launchEmpty()
        importVLESS(app)
        XCTAssertTrue(app.segmentedControls["prototype.mode"].buttons["VLESS"].isEnabled)
        XCTAssertFalse(app.segmentedControls["prototype.mode"].buttons["VK TURN"].isEnabled)
        app.buttons["prototype.logs"].tap()
        XCTAssertTrue(app.navigationBars["Логи · VLESS"].waitForExistence(timeout: 5))
        app.terminate()
        app.launch()
        XCTAssertTrue(app.segmentedControls["prototype.mode"].buttons["VLESS"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.segmentedControls["prototype.mode"].buttons["VLESS"].isEnabled)
        XCTAssertFalse(app.segmentedControls["prototype.mode"].buttons["VK TURN"].isEnabled)
        app.buttons["prototype.logs"].tap()
        XCTAssertTrue(app.navigationBars["Логи · VLESS"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["prototype.configs.clear"].tap()
    }

    func testLogsOpenForBothImportedConnectionModes() {
        let app = launchEmpty()
        importVLESS(app)
        importVK(app)
        for mode in ["VK TURN", "VLESS"] {
            XCTAssertTrue(app.segmentedControls["prototype.mode"].buttons[mode].isEnabled)
            app.segmentedControls["prototype.mode"].buttons[mode].tap()
            app.buttons["prototype.logs"].tap()
            XCTAssertTrue(app.navigationBars["Логи · " + mode].waitForExistence(timeout: 5))
            XCTAssertTrue(app.buttons["prototype.logs.pause"].exists)
            app.navigationBars.buttons.element(boundBy: 0).tap()
        }
        app.buttons["prototype.configs.clear"].tap()
    }

    func testInvalidLinkDoesNotEnableVKMode() {
        let app = launchEmpty()
        app.swipeUp()
        let input = app.textFields["wdtt://… или vkturnproxy://…"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.tap()
        input.typeText("invalid-link")
        app.buttons["prototype.vk.save"].tap()
        app.swipeUp()
        XCTAssertTrue(app.staticTexts["Ожидается ссылка vkturnproxy://import?data=… или wdtt://… ."].waitForExistence(timeout: 5))
        app.swipeDown()
        XCTAssertFalse(app.segmentedControls["prototype.mode"].buttons["VK TURN"].isEnabled)
    }
}
