import XCTest

@MainActor
final class PrototypeDeviceRoutingTests: XCTestCase {
    private let app = XCUIApplication()
    private var status: XCUIElement {
        app.descendants(matching: .any).matching(identifier: "prototype.status").firstMatch
    }

    func testRoutingAndDownloadsWithSavedDeviceConfigurations() async throws {
        #if targetEnvironment(simulator)
            throw XCTSkip("This check requires a physical iPhone and saved VPN configurations.")
        #else
            try XCTSkipUnless(ProcessInfo.processInfo.environment["PROTOTYPE_DEVICE_ROUTING_CHECK"] == "1",
                              "Enable this device check explicitly; it changes the active VPN temporarily.")
            continueAfterFailure = false
            app.launch()
            XCTAssertTrue(app.tabBars.buttons["Роутинги"].waitForExistence(timeout: 15))
            let connectionPicker = app.segmentedControls["prototype.mode"]
            let originalMode = connectionPicker.buttons["VLESS"].isSelected ? "VLESS" : "VK TURN"
            let modes = ["VLESS", "VK TURN"].filter { connectionPicker.buttons[$0].isEnabled }
            try XCTSkipIf(modes.isEmpty, "Import a VPN configuration on the iPhone before running this check.")
            _ = reveal("prototype.stop")
            let wasConnected = status.value as? String == "Подключено"
            app.tabBars.buttons["Роутинги"].tap()
            let routingPicker = app.segmentedControls["prototype.routing.mode"]
            let originalRouting = routingPicker.buttons["Russia inside"].isSelected ? "Russia inside" : "С роутингом"
            app.tabBars.buttons["VPN"].tap()
            defer {
                stopVPN()
                choose(mode: originalMode, routing: originalRouting)
                if wasConnected { startVPN() }
            }

            for mode in modes {
                stopVPN()
                for (index, routing) in ["Russia inside", "С роутингом"].enumerated() {
                    choose(mode: mode, routing: routing)
                    if index == 0 {
                        startVPN()
                    } else {
                        // Routing changes must reconnect the active VPN without a manual start.
                        waitForStatus("Подключено", timeout: 120)
                    }

                    let session = URLSession(configuration: .ephemeral)
                    defer { session.invalidateAndCancel() }
                    var request = URLRequest(url: URL(string: "https://captive.apple.com/hotspot-detect.html")!)
                    request.timeoutInterval = 30
                    let (data, response) = try await session.data(for: request)
                    XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
                    XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("Success"))

                    app.buttons["prototype.logs"].tap()
                    XCTAssertTrue(app.navigationBars["Логи · " + mode].waitForExistence(timeout: 10))
                    let search = app.searchFields.firstMatch
                    if !search.isHittable { app.swipeDown() }
                    XCTAssertTrue(search.waitForExistence(timeout: 10))
                    search.tap()
                    search.typeText("captive.apple.com")
                    let traffic = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "captive.apple.com")).allElementsBoundByIndex
                        .map(\.label).filter { $0.contains("connection to") || $0.contains("inbound connection to") }
                    let report = XCTAttachment(string: "Mode: \(mode)\nRouting: \(routing)\nHTTPS: 200, Success\n" + traffic.joined(separator: "\n"))
                    report.name = "VPN traffic: \(mode), \(routing)"
                    report.lifetime = .keepAlways
                    add(report)
                    if routing == "С роутингом", mode == modes.first {
                        search.tap()
                        search.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 100))
                        search.typeText("updated rule-set")
                        // Native updates are sequential; the last descriptor follows all geosite sets.
                        let lastUpdate = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "updated rule-set geoip-direct")).firstMatch
                        XCTAssertTrue(lastUpdate.waitForExistence(timeout: 90), "Native remote updates did not finish.")
                        let updates = app.staticTexts.allElementsBoundByIndex.map(\.label)
                            .filter { $0.contains("updated rule-set") }
                        let evidence = XCTAttachment(string: updates.joined(separator: "\n"))
                        evidence.name = "Native rule-set updates: \(mode)"
                        evidence.lifetime = .keepAlways
                        add(evidence)
                    }
                    app.navigationBars.buttons.element(boundBy: 0).tap()
                    app.tabBars.buttons["Роутинги"].tap()
                    let screenshot = XCTAttachment(screenshot: app.screenshot())
                    screenshot.name = "Routing choice on iPhone: \(mode), \(routing)"
                    screenshot.lifetime = .keepAlways
                    add(screenshot)
                    app.tabBars.buttons["VPN"].tap()
                }
            }
        #endif
    }

    private func reveal(_ identifier: String) -> XCUIElement {
        let button = app.buttons[identifier]
        for _ in 0..<5 {
            if button.isHittable { return button }
            app.swipeUp()
        }
        return button
    }

    private func choose(mode: String, routing: String) {
        let picker = app.segmentedControls["prototype.mode"]
        for _ in 0..<5 {
            if picker.isHittable { break }
            app.swipeDown()
        }
        picker.buttons[mode].tap()
        app.tabBars.buttons["Роутинги"].tap()
        let selected = app.segmentedControls["prototype.routing.mode"].buttons[routing]
        selected.tap()
        let applied = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            selected.isSelected && selected.isEnabled
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [applied], timeout: 30), .completed,
                       "Routing change did not finish: " + routing)
        app.tabBars.buttons["VPN"].tap()
    }

    private func stopVPN() {
        let stop = reveal("prototype.stop")
        if stop.isEnabled { stop.tap() }
        waitForStatus("Отключено", timeout: 30)
    }

    private func startVPN() {
        let start = reveal("prototype.start")
        XCTAssertTrue(start.isEnabled)
        start.tap()
        waitForStatus("Подключено", timeout: 120)
    }

    private func waitForStatus(_ value: String, timeout: TimeInterval) {
        let expected = XCTNSPredicateExpectation(predicate: NSPredicate { [self] _, _ in
            status.value as? String == value
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [expected], timeout: timeout), .completed,
                       "VPN did not reach the expected state: \(value)")
    }
}
