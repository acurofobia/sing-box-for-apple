import XCTest

@MainActor
final class PrototypeDeviceRoutingTests: XCTestCase {
    private let app = XCUIApplication()
    private var status: XCUIElement {
        app.descendants(matching: .any).matching(identifier: "prototype.status").firstMatch
    }

    func testColdLaunchShowsAlreadyRunningVPN() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["PROTOTYPE_DEVICE_CONNECTED_RELAUNCH"] == "1",
                          "Requires a physical iPhone with the prototype VPN already connected.")
        continueAfterFailure = false
        app.launch()
        let stop = app.buttons["prototype.stop"]
        XCTAssertTrue(stop.waitForExistence(timeout: 10))
        app.terminate()
        app.launch()
        XCTAssertTrue(stop.waitForExistence(timeout: 10), "The running VPN was not discovered automatically")
        XCTAssertTrue(stop.isEnabled)
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

    func testSubscriptionRoutingWithSavedDeviceConfigurations() async throws {
        #if targetEnvironment(simulator)
            throw XCTSkip("This check requires a physical iPhone and saved VPN configurations.")
        #else
            try XCTSkipUnless(ProcessInfo.processInfo.environment["PROTOTYPE_DEVICE_ROUTING_CHECK"] == "1",
                              "Enable this device check explicitly; it changes the active VPN temporarily.")
            continueAfterFailure = false
            app.launch()
            XCTAssertTrue(app.tabBars.buttons["Роутинг"].waitForExistence(timeout: 15))
            app.tabBars.buttons["Профиль"].tap()
            let refresh = app.buttons["prototype.subscription.refresh"]
            XCTAssertTrue(refresh.waitForExistence(timeout: 10))
            if refresh.isEnabled { refresh.tap() }
            app.tabBars.buttons["Роутинг"].tap()
            XCTAssertTrue(app.staticTexts["Подписка"].waitForExistence(timeout: 95),
                          "The saved subscription did not supply a routing profile.")
            app.tabBars.buttons["Подключение"].tap()
            app.buttons["prototype.mode"].tap()
            let originalMode = app.buttons["prototype.ui.option01"].value as? String == "Выбрано" ? "option01" : "option02"
            let modes = ["option01", "option02"].filter {
                let button = app.buttons["prototype.ui." + $0]
                return button.exists && button.isEnabled
            }
            app.buttons["prototype.mode.close"].tap()
            XCTAssertTrue(app.buttons["prototype.mode"].waitForExistence(timeout: 8))
            try XCTSkipIf(modes.isEmpty, "Import a VPN configuration on the iPhone before running this check.")
            let wasConnected = status.value as? String == "Подключено"
                || ProcessInfo.processInfo.environment["PROTOTYPE_DEVICE_PREINSTALL_CONNECTED"] == "1"
            app.tabBars.buttons["Роутинг"].tap()
            let insideID = "prototype.routing.russiaInside"
            let roskomID = "prototype.routing.enabled"
            XCTAssertTrue(app.buttons[insideID].waitForExistence(timeout: 8))
            let originalRouting = app.buttons[insideID].isSelected ? insideID : roskomID
            app.tabBars.buttons["Подключение"].tap()
            addTeardownBlock { @MainActor [self] in
                app.tabBars.buttons["Подключение"].tap()
                stopVPN()
                choose(mode: originalMode, routing: originalRouting)
                if wasConnected {
                    startVPN()
                }
            }

            for mode in modes {
                stopVPN()
                for (index, routing) in [insideID, roskomID].enumerated() {
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

                    let report = XCTAttachment(string: "Mode: \(mode)\nRouting: \(routing)\nHTTPS: 200, Success")
                    report.name = "VPN traffic: \(mode), \(routing)"
                    report.lifetime = .keepAlways
                    add(report)
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

    func testServiceRecoveryWithSavedDeviceConfigurations() throws {
        #if targetEnvironment(simulator)
            throw XCTSkip("Requires a physical iPhone and a working WDTT resource.")
        #else
            try XCTSkipUnless(ProcessInfo.processInfo.environment["PROTOTYPE_DEVICE_SERVICE_CHECK"] == "1",
                              "Enable the check explicitly to temporarily change VPN connections.")
            continueAfterFailure = false
            app.launchEnvironment["PROTOTYPE_RECOVERY_SIMULATE_TIMEOUT"] = "1"
            app.launch()
            let connection = app.tabBars.buttons["Подключение"]
            try XCTSkipUnless(connection.waitForExistence(timeout: 15), "The device has no saved subscription.")
            connection.tap()
            XCTAssertTrue(status.waitForExistence(timeout: 10))
            let wasRunning = app.buttons["prototype.stop"].exists ||
                ProcessInfo.processInfo.environment["PROTOTYPE_DEVICE_PREINSTALL_CONNECTED"] == "1"
            app.buttons["prototype.mode"].tap()
            let modes = ["option01", "option02"].filter { app.buttons["prototype.ui." + $0].exists && app.buttons["prototype.ui." + $0].isEnabled }
            let originalMode = modes.first { app.buttons["prototype.ui." + $0].value as? String == "Выбрано" }
            closeDeviceModeDrawer()
            try XCTSkipIf(modes.isEmpty || originalMode == nil, "No selected, available VPN configuration on the device.")
            app.tabBars.buttons["Роутинг"].tap()
            let inside = app.buttons["prototype.routing.russiaInside"]
            XCTAssertTrue(inside.waitForExistence(timeout: 8))
            let routing = inside.isSelected ? "prototype.routing.russiaInside" : "prototype.routing.enabled"
            connection.tap()
            addTeardownBlock { @MainActor [self] in
                if app.buttons["prototype.recovery.cancel"].exists { app.buttons["prototype.recovery.cancel"].tap() }
                if app.staticTexts["prototype.recovery.result"].exists || !connection.isHittable {
                    if app.buttons["prototype.recovery.close"].waitForExistence(timeout: 170) { app.buttons["prototype.recovery.close"].tap() }
                }
                if connection.isHittable { connection.tap() }
                stopVPN()
                if let originalMode { choose(mode: originalMode, routing: routing) }
                if wasRunning { startVPN() }
            }
            stopVPN()
            verifyServiceRefresh(wasRunning: false)
            waitForStatus("Отключено", timeout: 15)
            for mode in modes {
                stopVPN()
                choose(mode: mode, routing: routing)
                startVPN()
                verifyServiceRefresh(wasRunning: true)
                waitForStatus("Подключено", timeout: 120)
                app.buttons["prototype.mode"].tap()
                XCTAssertEqual(app.buttons["prototype.ui." + mode].value as? String, "Выбрано")
                closeDeviceModeDrawer()
                app.tabBars.buttons["Роутинг"].tap()
                XCTAssertTrue(app.buttons[routing].isSelected)
                connection.tap()
            }
        #endif
    }

    private func closeDeviceModeDrawer() {
        // The expanded header may be below the viewport on a compact iPhone.
        // Dismiss the scrim and wait until SwiftUI has completed its closing animation.
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.86)).tap()
        let picker = app.buttons["prototype.mode"]
        if !picker.waitForExistence(timeout: 2) {
            let selected = ["option01", "option02"].map { app.buttons["prototype.ui." + $0] }.first {
                $0.exists && $0.isHittable && $0.isEnabled && $0.value as? String == "Выбрано"
            }
            selected?.tap()
        }
        XCTAssertTrue(picker.waitForExistence(timeout: 8), "The mode drawer did not finish closing.")
    }

    private func verifyServiceRefresh(wasRunning: Bool) {
        app.tabBars.buttons["Профиль"].tap()
        let refresh = app.buttons["prototype.subscription.refresh"]
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in refresh.exists && refresh.isEnabled }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 115), .completed)
        refresh.tap()
        let start = app.buttons["prototype.recovery.start"]
        XCTAssertTrue(start.waitForExistence(timeout: 15))
        XCTAssertEqual(app.staticTexts["На время обновления мы отключим основной VPN и затем подключим его снова."].exists, wasRunning)
        start.tap()
        let result = app.staticTexts["prototype.recovery.result"]
        XCTAssertTrue(result.waitForExistence(timeout: 450))
        XCTAssertEqual(result.label, "Подписка обновлена.")
        app.buttons["prototype.recovery.close"].tap()
        app.tabBars.buttons["Подключение"].tap()
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
        let selected = app.buttons[routing]
        XCTAssertTrue(selected.waitForExistence(timeout: 8))
        XCTAssertTrue(selected.isEnabled && selected.isHittable, "Routing option unavailable: " + routing)
        selected.tap()
        let applied = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            selected.isSelected && selected.isEnabled
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [applied], timeout: 30), .completed,
                       "Routing change did not finish: " + routing)
        app.tabBars.buttons["Подключение"].tap()
    }

    private func stopVPN() {
        if app.buttons["prototype.stop"].exists {
            let stop = reveal("prototype.stop")
            XCTAssertTrue(stop.isEnabled)
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
