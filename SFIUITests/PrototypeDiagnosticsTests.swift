import XCTest

@MainActor
final class PrototypeDiagnosticsTests: XCTestCase {
    func testDevicePersistsTunnelLogsAfterDisconnectAndAppRestart() throws {
        #if targetEnvironment(simulator)
            throw XCTSkip("Requires a physical iPhone with a saved VPN configuration.")
        #else
            try XCTSkipUnless(ProcessInfo.processInfo.environment["PROTOTYPE_DEVICE_DIAGNOSTICS_CHECK"] == "1",
                              "Enable explicitly; temporarily starts and stops the saved VPN.")
            continueAfterFailure = false
            let forceDisconnect = ProcessInfo.processInfo.environment["PROTOTYPE_DEVICE_FORCE_DISCONNECT_CHECK"] == "1"
            let app = XCUIApplication()
            app.launch()
            XCTAssertTrue(app.tabBars.buttons["Подключение"].waitForExistence(timeout: 15))
            app.tabBars.buttons["Подключение"].tap()
            let wasRunning = app.buttons["prototype.stop"].exists
            if wasRunning { app.buttons["prototype.stop"].tap() }
            XCTAssertTrue(app.buttons["prototype.start"].waitForExistence(timeout: 20))
            app.buttons["prototype.start"].tap()
            XCTAssertTrue(app.buttons["prototype.stop"].waitForExistence(timeout: 60))
            // Keep the app suspended while the extension writes independently.
            XCUIDevice.shared.press(.home)
            let background = XCTWaiter.wait(for: [XCTestExpectation(description: "background capture")], timeout: 35)
            XCTAssertEqual(background, .timedOut)
            app.activate()
            app.tabBars.buttons["Подключение"].tap()
            if forceDisconnect {
                XCTAssertTrue(app.buttons["prototype.start"].waitForExistence(timeout: 20), "Host must terminate the extension during the background capture")
                // Evict the old session from the normal three-session history.
                for _ in 0..<4 {
                    app.buttons["prototype.start"].tap()
                    XCTAssertTrue(app.buttons["prototype.stop"].waitForExistence(timeout: 20))
                    _ = XCTWaiter.wait(for: [XCTestExpectation(description: "new tunnel process")], timeout: 3)
                    app.buttons["prototype.stop"].tap()
                    XCTAssertTrue(app.buttons["prototype.start"].waitForExistence(timeout: 20))
                }
            } else {
                XCTAssertTrue(app.buttons["prototype.stop"].waitForExistence(timeout: 10))
                app.buttons["prototype.stop"].tap()
            }
            XCTAssertTrue(app.buttons["prototype.start"].waitForExistence(timeout: 20))
            app.terminate()
            app.launch()
            XCTAssertTrue(app.tabBars.buttons["Профиль"].waitForExistence(timeout: 15))
            app.tabBars.buttons["Профиль"].tap()
            let logs = app.buttons["prototype.logs"]
            for _ in 0..<5 where !logs.isHittable { app.swipeUp() }
            XCTAssertTrue(logs.waitForExistence(timeout: 10))
            logs.tap()
            app.buttons["prototype.logs.diagnostics"].tap()
            let report = app.textViews["prototype.logs.diagnostics.text"]
            XCTAssertTrue(report.waitForExistence(timeout: 20))
            var text = try XCTUnwrap(report.value as? String)
            // The full file includes older crash reports; read pages until the current incident is covered.
            for _ in 0..<20 {
                if text.contains("stop requested reason=1 (userInitiated)"), text.contains("[core]"), text.contains("sample elapsed=") { break }
                let next = app.buttons["prototype.logs.diagnostics.next"]
                guard next.exists, next.isEnabled else { break }
                next.tap()
                text += try XCTUnwrap(report.value as? String)
            }
            XCTAssertTrue(text.contains("[core]"), "Release core logs missing")
            XCTAssertTrue(text.contains("stop requested reason=1 (userInitiated)"), "Stop reason lost")
            XCTAssertTrue(text.contains("sample elapsed="), "Memory samples missing")
            XCTAssertTrue(text.contains("scene phase=background"), "App lifecycle missing")
            if forceDisconnect {
                XCTAssertTrue(text.contains("incidents/") && text.contains("Unexpected disconnect preserved"), "Unshared crash report was overwritten by reconnections")
                XCTAssertTrue(text.contains("last VPN disconnect error") || text.contains("iOS returned no last disconnect error"),
                              "iOS disconnect diagnostic result missing")
            }
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = "Persisted VPN diagnostics after disconnect and app restart"
            screenshot.lifetime = .keepAlways
            add(screenshot)
            app.buttons["prototype.logs.diagnostics.clear"].tap()
            let confirmation = app.alerts["Удалить сохранённые отчёты?"]
            XCTAssertTrue(confirmation.waitForExistence(timeout: 5))
            confirmation.buttons["Отмена"].tap()
            app.buttons["prototype.logs.diagnostics.share"].tap()
            XCTAssertTrue(app.otherElements["ActivityListView"].waitForExistence(timeout: 10))
            // Reset presentation without matching the share sheet's second Close button.
            app.terminate()
            app.launch()
            if wasRunning || ProcessInfo.processInfo.environment["PROTOTYPE_DEVICE_KEEP_CONNECTED"] == "1" {
                XCTAssertTrue(app.tabBars.buttons["Подключение"].waitForExistence(timeout: 15))
                app.tabBars.buttons["Подключение"].tap()
                XCTAssertTrue(app.buttons["prototype.start"].waitForExistence(timeout: 15))
                app.buttons["prototype.start"].tap()
            }
        #endif
    }
}
