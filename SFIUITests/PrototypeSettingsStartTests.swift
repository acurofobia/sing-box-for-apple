import Foundation
import XCTest

@MainActor
final class PrototypeSettingsStartTests: XCTestCase {
    func testSettingsStartUsesRefreshedVLESSAndRejectsRevokedVLESS() async throws {
        #if targetEnvironment(simulator)
            throw XCTSkip("Requires a physical iPhone and the iOS Settings VPN switch.")
        #else
            let environment = ProcessInfo.processInfo.environment
            try XCTSkipUnless(environment["PROTOTYPE_DEVICE_SETTINGS_START"] == "1" ||
                environment["TEST_RUNNER_PROTOTYPE_DEVICE_SETTINGS_START"] == "1",
                "Opt in on an isolated physical iPhone with PROTOTYPE_DEVICE_SETTINGS_START=1.")
            continueAfterFailure = false
            let fixture = SettingsVLESSFixture()
            try await fixture.start()
            defer { fixture.stop() }
            fixture.stage = .a

            let app = XCUIApplication()
            app.launchArguments += ["-AppleLanguages", "(ru)", "-AppleLocale", "ru_RU"]
            let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")

            app.launch()
            try await prepareSubscription(in: app, source: fixture.source)
            try await openVPNSettings(settings)
            if let existingSwitch = vpnSwitch(in: settings) {
                guard switchState(existingSwitch) == false else {
                    mark("settings-preflight-vpn-active-or-unknown")
                    throw XCTSkip("A system VPN is active or its state cannot be verified.")
                }
            } else {
                XCTAssertTrue(visible(settings, labels: addVPNLabels).isHittable,
                              "Could not verify that Settings has no active VPN.")
            }
            app.terminate()
            app.launch()
            selectVLESS(in: app)

            let start = app.buttons["prototype.start"]
            let stop = app.buttons["prototype.stop"]
            let status = app.descendants(matching: .any)["prototype.status"].firstMatch
            try await require("The app did not enable the first VLESS start.") { start.isHittable && start.isEnabled }
            mark("app-a-attempt")
            start.tap()
            let disclosure = app.alerts["Перед подключением"]
            if disclosure.waitForExistence(timeout: 2) { disclosure.buttons["Подключить"].tap() }
            var approved = false
            let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
            let deadline = ContinuousClock.now.advanced(by: .seconds(80))
            while !fixture.sawProfile(.a), ContinuousClock.now < deadline {
                if !approved, let button = tunnelPermission(in: app) ?? tunnelPermission(in: springboard) {
                    mark("system-vpn-permission-allow")
                    button.tap()
                    approved = true
                }
                try await Task.sleep(for: .milliseconds(250))
            }
            guard fixture.sawProfile(.a) else {
                mark("app-a-no-vless-handshake-possible-system-authorization-blocker")
                XCTFail("Profile A did not reach the loopback fixture. Check for an iOS VPN authorization or passcode prompt.")
                return
            }
            mark("app-a-observed")
            try await require("The app did not expose a stop control for profile A.") { stop.isHittable && stop.isEnabled }
            stop.tap()
            try await require("Profile A did not stop.", timeout: 35) {
                start.isHittable && status.value as? String == "Отключено"
            }
            mark("app-a-stopped")

            fixture.stage = .b
            try await refresh(in: app, expecting: "Profile B")
            mark("app-b-refresh-committed")
            app.terminate()
            XCTAssertEqual(app.state, .notRunning, "The app must be closed before starting VPN in Settings.")

            let settingsSwitch = try await selectVipin(in: settings)
            XCTAssertFalse(fixture.sawProfile(.b), "Profile B reached the fixture before the Settings start.")
            mark("settings-b-attempt")
            settingsSwitch.tap()
            try await require("Starting in Settings did not use the refreshed profile B.", timeout: 80) {
                fixture.sawProfile(.b)
            }
            try await require("Settings did not stay connected with profile B.", timeout: 25) {
                self.switchState(settingsSwitch) == true
            }
            mark("settings-b-observed")
            settingsSwitch.tap()
            try await require("Settings did not disconnect profile B.", timeout: 35) {
                self.switchState(settingsSwitch) == false
            }
            mark("settings-b-stopped")

            fixture.stage = .revoked
            app.launch()
            try await refresh(in: app, expecting: "VLESS revoked")
            mark("app-revocation-refresh-committed")
            app.terminate()
            XCTAssertEqual(app.state, .notRunning, "The app must be closed for the revocation check.")

            let revokedSwitch = try await selectVipin(in: settings)
            fixture.resetObservations()
            let revokedAttempt = mark("settings-revoked-attempt")
            revokedSwitch.tap()
            try await requireStableOff(revokedSwitch)
            XCTAssertFalse(fixture.sawProfile(.a) || fixture.sawProfile(.b),
                           "A previously valid profile reached the fixture after revocation.")
            mark("settings-revoked-off-awaiting-extension-diagnostic")
            try await verifyRevocationDiagnostic(in: app, after: revokedAttempt)
            mark("settings-revoked-extension-diagnostic-confirmed")
            // Keep the test VPN configuration and app diagnostics for the host to inspect before cleanup.
        #endif
    }

    private let generalLabels = ["General", "Основные"]
    private let managementLabels = ["VPN & Device Management", "VPN и управление устройством", "VPN и управление устройствами"]
    private let addVPNLabels = ["Add VPN Configuration…", "Add VPN Configuration...", "Добавить конфигурацию VPN…", "Добавить конфигурацию VPN..."]

    private func prepareSubscription(in app: XCUIApplication, source: URL) async throws {
        let input = app.textFields["prototype.subscription.url"]
        let submit = app.buttons["prototype.subscription.fetch"]
        try await require("The app did not show the import form or a saved subscription.") {
            input.exists || app.buttons["prototype.subscription.refresh"].exists
        }
        if input.exists {
            let current = input.value as? String
            try XCTSkipUnless(current == nil || current == "" || current == "Вставьте ссылку" || current == source.absoluteString,
                              "Existing import field contains a non-fixture subscription.")
            if current != source.absoluteString {
                input.tap()
                input.typeText(source.absoluteString)
            }
            try await require("The app did not enable subscription import.") { submit.isHittable && submit.isEnabled }
            submit.tap()
            let onboarding = app.buttons["prototype.mode.onboarding.done"]
            try await require("The app did not finish the fixture import.", timeout: 35) {
                onboarding.isHittable || app.staticTexts["Profile A"].exists
            }
            if onboarding.isHittable { onboarding.tap() }
            try await require("The app did not import profile A.", timeout: 35) { app.staticTexts["Profile A"].exists }
            mark("app-a-import-committed")
        } else {
            let fixtureTitle = ["Profile A", "Profile B", "VLESS revoked"].contains { app.staticTexts[$0].exists }
            try XCTSkipUnless(fixtureTitle, "An existing subscription is not identified as the test fixture.")
            app.tabBars.buttons["Профиль"].tap()
            let edit = app.buttons["prototype.ui.item01"]
            for _ in 0 ..< 5 where !edit.isHittable { app.swipeUp() }
            try await require("Could not safely inspect the saved fixture source.") { edit.isHittable }
            edit.tap()
            try await require("The saved subscription editor did not open.") { input.exists }
            try XCTSkipUnless(input.value as? String == source.absoluteString, "Saved subscription does not match the fixture URL.")
            app.buttons["Отмена"].tap()
            try await refresh(in: app, expecting: "Profile A")
            mark("app-a-retry-refresh-committed")
        }
    }

    private func selectVLESS(in app: XCUIApplication) {
        let connection = app.tabBars.buttons["Подключение"]
        if connection.isHittable, !connection.isSelected { connection.tap() }
        let option = app.buttons["prototype.ui.option01"]
        let picker = app.buttons["prototype.mode"]
        if !option.isHittable {
            XCTAssertTrue(picker.waitForExistence(timeout: 10))
            picker.tap()
        }
        XCTAssertTrue(option.waitForExistence(timeout: 10))
        XCTAssertTrue(option.isHittable && option.isEnabled, "The fixture VLESS mode is unavailable.")
        option.tap()
        XCTAssertTrue(picker.waitForExistence(timeout: 10))
        XCTAssertEqual(picker.value as? String, "VLESS")
    }

    private func refresh(in app: XCUIApplication, expecting title: String) async throws {
        let profile = app.tabBars.buttons["Профиль"]
        try await require("The app did not show the Profile tab for manual refresh.") { profile.isHittable }
        if !profile.isSelected { profile.tap() }
        let refresh = app.buttons["prototype.subscription.refresh"]
        try await require("The app did not enable manual subscription refresh.") { refresh.isHittable && refresh.isEnabled }
        refresh.tap()
        try await require("The app did not commit the expected fixture stage.", timeout: 40) {
            app.staticTexts[title].exists && refresh.isEnabled
        }
    }

    private func tunnelPermission(in application: XCUIApplication) -> XCUIElement? {
        let prompt = application.alerts.firstMatch
        guard prompt.exists else { return nil }
        let text = prompt.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: " ").lowercased()
        guard text.contains("vipin"),
              text.contains("add vpn configuration") || text.contains("добав") && text.contains("конфигурац") && text.contains("vpn")
        else {
            return nil
        }
        let allow = prompt.buttons.matching(NSPredicate(format: "label IN %@", ["Allow", "Разрешить"])).firstMatch
        return allow.isHittable ? allow : nil
    }

    private func openVPNSettings(_ settings: XCUIApplication) async throws {
        settings.activate()
        // Return to a known starting page if Settings was left in another pane.
        let rootTitles = ["Settings", "Настройки"]
        func at(_ titles: [String]) -> Bool {
            settings.navigationBars.matching(NSPredicate(format: "identifier IN %@ OR label IN %@", titles, titles)).firstMatch.exists
        }
        for _ in 0 ..< 8 {
            if at(["VPN"]) { return }
            if at(managementLabels) || at(generalLabels) || at(rootTitles) { break }
            let back = settings.navigationBars.buttons.matching(NSPredicate(format: "identifier == %@ OR label IN %@", "BackButton", ["Back", "Назад"] + rootTitles + generalLabels)).firstMatch
            guard back.exists, back.isHittable else { break }
            back.tap()
        }
        var lastPage = ""
        for _ in 0 ..< 18 {
            if at(["VPN"]) { return }
            let page = at(managementLabels) ? "management" : at(generalLabels) ? "general" : "root"
            let labels = page == "management" ? ["VPN"] : page == "general" ? managementLabels : generalLabels
            let identifiers = page == "general" ? ["ManagedConfigurationList", "DEVICE_MANAGEMENT"] : page == "root" ? ["General"] : []
            let target = settings.descendants(matching: .any)
                .matching(NSPredicate(format: "label IN %@ OR identifier IN %@", labels, identifiers)).firstMatch
            if target.exists, target.isHittable {
                target.tap()
            } else if page == "root", lastPage != page {
                settings.swipeDown(velocity: .fast)
            } else {
                settings.swipeUp()
            }
            if lastPage != page { mark("settings-navigation-" + page) }
            lastPage = page
        }
        mark("settings-vpn-navigation-blocked")
        XCTFail("Could not navigate Settings > General > VPN & Device Management > VPN.")
    }

    private func selectVipin(in settings: XCUIApplication) async throws -> XCUIElement {
        try await openVPNSettings(settings)
        let status = try XCTUnwrap(vpnSwitch(in: settings), "Could not identify the VPN status switch.")
        XCTAssertEqual(switchState(status), false, "Refusing to change VPN selection while a system VPN is active or its state is unknown.")
        let matches = settings.cells.matching(NSPredicate(format: "label == %@", "vipin"))
        let row = matches.firstMatch
        try await require("The test profile vipin must be uniquely identifiable in Settings.") {
            matches.count == 1 && row.isHittable
        }
        if !isSelectedProfile(row) { row.tap() }
        try await require("Settings did not confirm selection of the test VPN profile.") {
            settings.navigationBars["VPN"].exists && matches.count == 1 && status.isHittable && self.isSelectedProfile(row)
        }
        XCTAssertEqual(switchState(status), false, "Selecting the test VPN unexpectedly changed the switch state.")
        return status
    }

    private func isSelectedProfile(_ row: XCUIElement) -> Bool {
        let selected = ["Selected", "Выбрано", "Выбран"]
        let traits = (row.value as? String ?? "").components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        return row.isSelected || traits.contains(where: selected.contains) || row.images["checkmark"].exists
    }

    private func vpnSwitch(in settings: XCUIApplication) -> XCUIElement? {
        guard settings.navigationBars["VPN"].exists else { return nil }
        let switches = settings.switches.matching(NSPredicate(format: "label IN %@", ["VPN", "Status", "Статус", "VPN Status", "Статус VPN"]))
        if switches.count == 1 { return switches.firstMatch }
        return settings.switches.count == 1 ? settings.switches.firstMatch : nil
    }

    private func switchState(_ toggle: XCUIElement) -> Bool? {
        guard toggle.exists else { return nil }
        if let value = toggle.value as? NSNumber, [0, 1].contains(value.intValue) { return value.boolValue }
        guard let value = toggle.value as? String else { return nil }
        switch value {
        case "0", "Off", "Выкл.": return false
        case "1", "On", "Вкл.": return true
        default: return nil
        }
    }

    private func visible(_ application: XCUIApplication, labels: [String]) -> XCUIElement {
        application.descendants(matching: .any).matching(NSPredicate(format: "label IN %@", labels)).firstMatch
    }

    private func requireStableOff(_ toggle: XCUIElement) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(32))
        var offSince: ContinuousClock.Instant?
        while ContinuousClock.now < deadline {
            if switchState(toggle) == false {
                if offSince == nil { offSince = .now }
                if let offSince, offSince.duration(to: .now) >= .seconds(6) { return }
            } else {
                offSince = nil
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        XCTFail("After the revoked Settings start, the VPN switch did not return to Off.")
    }

    private func verifyRevocationDiagnostic(in app: XCUIApplication, after attempt: Date) async throws {
        app.launch()
        let profile = app.tabBars.buttons["Профиль"]
        try await require("The app did not reopen its saved fixture after the Settings attempt.") { profile.isHittable }
        profile.tap()
        let logs = app.buttons["prototype.logs"]
        for _ in 0 ..< 5 where !logs.isHittable { app.swipeUp() }
        try await require("Could not open the app diagnostic log.") { logs.isHittable }
        logs.tap()
        let saved = app.buttons["prototype.logs.diagnostics"]
        try await require("Could not open saved diagnostics.") { saved.isHittable }
        saved.tap()
        let report = app.textViews["prototype.logs.diagnostics.text"]
        try await require("Saved diagnostics were not loaded.", timeout: 25) { report.exists }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let reason = "[tunnel] startup failed: Выбранный режим недоступен. Для следующего подключения выберите другой режим."
        let next = app.buttons["prototype.logs.diagnostics.next"]
        for _ in 0 ..< 40 {
            if let page = report.value as? String, page.split(separator: "\n").contains(where: { line in
                guard line.hasSuffix(reason), let timestamp = line.split(separator: " ", maxSplits: 1).first,
                      let date = formatter.date(from: String(timestamp)) else { return false }
                return date >= attempt
            }) { return }
            guard next.exists, next.isEnabled else { break }
            next.tap()
        }
        XCTFail("The extension did not report an unavailable VLESS startup failure after the Settings attempt.")
    }

    private func require(_ message: String, timeout: TimeInterval = 15, until ready: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
        while !ready(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(200))
        }
        XCTAssertTrue(ready(), message)
    }

    @discardableResult
    private func mark(_ stage: String) -> Date {
        let now = Date()
        let timestamp = now.ISO8601Format(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
        let line = "SETTINGS-VLESS \(timestamp) \(stage)"
        FileHandle.standardOutput.write(Data((line + "\n").utf8))
        let attachment = XCTAttachment(string: line)
        attachment.name = stage
        attachment.lifetime = .keepAlways
        add(attachment)
        return now
    }
}
