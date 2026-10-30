import XCTest

@MainActor
final class PrototypeDeviceRoutingTests: XCTestCase {
    private let app = XCUIApplication()
    private var status: XCUIElement {
        app.descendants(matching: .any).matching(identifier: "prototype.status").firstMatch
    }

    func testFailoverServerDetailsWithSavedConfiguration() throws {
        #if targetEnvironment(simulator)
            throw XCTSkip("This check requires the iPhone's saved VLESS configuration.")
        #else
            try XCTSkipUnless(ProcessInfo.processInfo.environment["PROTOTYPE_DEVICE_FAILOVER_CHECK"] == "1",
                              "Enable this device check explicitly; it may start the saved VPN temporarily.")
            continueAfterFailure = false
            app.launch()
            XCTAssertTrue(app.tabBars.buttons["Подключение"].waitForExistence(timeout: 15))
            app.tabBars.buttons["Подключение"].tap()
            let wasRunning = app.buttons["prototype.stop"].exists
            defer {
                if !wasRunning, ProcessInfo.processInfo.environment["PROTOTYPE_DEVICE_KEEP_CONNECTED"] != "1" { stopVPN() }
            }
            if !wasRunning { startVPN() }
            waitForStatus("Подключено", timeout: 120)
            let details = app.buttons["prototype.vpn.details"]
            if details.value as? String != "Развёрнуто" { details.tap() }
            let connected = app.staticTexts.matching(NSPredicate(format: "label MATCHES %@", "Подключён: .+ \\([1-4] из 4\\)"))
                .firstMatch
            XCTAssertTrue(connected.waitForExistence(timeout: 20), "Server field did not report the active failover candidate")
            XCTAssertTrue(connected.isHittable, "Active server is clipped inside the drawer")
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = "Active VLESS failover server"
            screenshot.lifetime = .keepAlways
            add(screenshot)
            let report = XCTAttachment(string: connected.label)
            report.name = "Active failover status"
            report.lifetime = .keepAlways
            add(report)
        #endif
    }

    func testRoutingAndDownloadsWithSavedDeviceConfigurations() async throws {
        #if targetEnvironment(simulator)
            throw XCTSkip("This check requires a physical iPhone and saved VPN configurations.")
        #else
            try XCTSkipUnless(ProcessInfo.processInfo.environment["PROTOTYPE_DEVICE_ROUTING_CHECK"] == "1",
                              "Enable this device check explicitly; it changes the active VPN temporarily.")
            continueAfterFailure = false
            app.launch()
            XCTAssertTrue(app.tabBars.buttons["Роутинг"].waitForExistence(timeout: 15))
            app.tabBars.buttons["Подключение"].tap()
            app.buttons["prototype.mode"].tap()
            let originalMode = app.buttons["prototype.ui.option01"].value as? String == "Выбрано" ? "option01" : "option02"
            let modes = ["option01", "option02"].filter { app.buttons["prototype.ui." + $0].isEnabled }
            let modeTitles = Dictionary(uniqueKeysWithValues: modes.map { ($0, app.buttons["prototype.ui." + $0].label) })
            app.buttons["prototype.mode.close"].tap()
            try XCTSkipIf(modes.isEmpty, "Import a VPN configuration on the iPhone before running this check.")
            _ = reveal("prototype.stop")
            let wasConnected = status.value as? String == "Подключено"
            app.tabBars.buttons["Роутинг"].tap()
            let routingPicker = app.segmentedControls["prototype.routing.mode"]
            let originalRouting = routingPicker.buttons["Russia inside"].isSelected ? "Russia inside" : "С роутингом"
            app.tabBars.buttons["Подключение"].tap()
            defer {
                stopVPN()
                choose(mode: originalMode, routing: originalRouting)
                if wasConnected {
                    startVPN()
                }
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
                    var request = try URLRequest(url: XCTUnwrap(URL(string: "https://captive.apple.com/hotspot-detect.html")))
                    request.timeoutInterval = 30
                    let (data, response) = try await session.data(for: request)
                    XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
                    XCTAssertTrue(String(data: data, encoding: .utf8)?.contains("Success") == true)

                    app.tabBars.buttons["Профиль"].tap()
                    app.buttons["prototype.logs"].tap()
                    XCTAssertTrue(app.navigationBars["Логи · " + (modeTitles[mode] ?? mode)].waitForExistence(timeout: 10))
                    let search = app.searchFields.firstMatch
                    if !search.isHittable {
                        app.swipeDown()
                    }
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
                    app.tabBars.buttons["Роутинг"].tap()
                    let screenshot = XCTAttachment(screenshot: app.screenshot())
                    screenshot.name = "Routing choice on iPhone: \(mode), \(routing)"
                    screenshot.lifetime = .keepAlways
                    add(screenshot)
                    app.tabBars.buttons["Подключение"].tap()
                }
            }
        #endif
    }

    private func reveal(_ identifier: String) -> XCUIElement {
        let button = app.buttons[identifier]
        for _ in 0 ..< 5 {
            if button.isHittable {
                return button
            }
            app.swipeUp()
        }
        return button
    }

    private func choose(mode: String, routing: String) {
        let picker = app.buttons["prototype.mode"]
        for _ in 0 ..< 5 {
            if picker.isHittable {
                break
            }
            app.swipeDown()
        }
        picker.tap()
        let option = app.buttons["prototype.ui." + mode]
        XCTAssertTrue(option.waitForExistence(timeout: 5))
        option.tap()
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        app.tabBars.buttons["Роутинг"].tap()
        let selected = app.segmentedControls["prototype.routing.mode"].buttons[routing]
        selected.tap()
        let applied = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            selected.isSelected && selected.isEnabled
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [applied], timeout: 30), .completed,
                       "Routing change did not finish: " + routing)
        app.tabBars.buttons["Подключение"].tap()
    }

    private func stopVPN() {
        let stop = reveal("prototype.stop")
        if stop.exists, stop.isEnabled {
            stop.tap()
        }
        waitForStatus("Отключено", timeout: 30)
    }

    private func startVPN() {
        let start = reveal("prototype.start")
        XCTAssertTrue(start.isEnabled)
        start.tap()
        let disclosure = app.alerts["Перед подключением"]
        if disclosure.waitForExistence(timeout: 2) {
            disclosure.buttons["Подключить"].tap()
        }
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
