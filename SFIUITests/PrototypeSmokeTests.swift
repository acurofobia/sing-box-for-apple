import NetworkExtension
import UIKit
import XCTest

@MainActor
final class PrototypeSmokeTests: XCTestCase {
    func testFirstImportConnectionFailureOffersServiceRecoveryAndKeepsDraftOnCancel() {
        let app = launch()
        let input = app.textFields["prototype.subscription.url"]
        XCTAssertTrue(input.waitForExistence(timeout: 10))
        input.tap()
        let source = "https://127.0.0.1:1/subscription"
        input.typeText(source)
        app.buttons["prototype.subscription.fetch"].tap()
        let start = app.buttons["prototype.recovery.start"]
        XCTAssertTrue(start.waitForExistence(timeout: 15))
        let cancel = app.buttons["prototype.recovery.cancel"]
        let heading = app.staticTexts["Обновление через сервисный WDTT"]
        XCTAssertLessThan(heading.frame.midX, cancel.frame.midX)
        XCTAssertLessThan(cancel.frame.maxY, start.frame.minY)
        XCTAssertEqual(start.frame.minX, heading.frame.minX, accuracy: 2)
        XCTAssertEqual(start.frame.maxX, cancel.frame.maxX, accuracy: 2)
        cancel.tap()
        XCTAssertEqual(input.value as? String, source)
        XCTAssertTrue(app.buttons["prototype.subscription.fetch"].isEnabled)
    }

    func testUnstartedServiceRecoveryDoesNotOfferToDisconnectVPNAfterRelaunch() throws {
        let app = launch()
        try openSubscriptionLink("https://127.0.0.1:1/subscription", in: app)
        app.buttons["prototype.subscription.fetch"].tap()
        XCTAssertTrue(app.buttons["prototype.recovery.start"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["prototype.recovery.confirmStop"].exists)

        app.terminate()
        let reopened = launch(reset: false)
        XCTAssertTrue(reopened.textFields["prototype.subscription.url"].waitForExistence(timeout: 10))
        XCTAssertFalse(reopened.buttons["prototype.recovery.start"].exists)
        XCTAssertFalse(reopened.buttons["prototype.recovery.confirmStop"].exists)
    }

    func testImportWaitsInDownloadStepUntilPersonalKeyIsReady() async throws {
        let app = launch()
        try await control("preparing")
        try openSubscriptionLink("http://localhost:18081/subscription/bundle", in: app)
        app.buttons["prototype.subscription.fetch"].tap()
        let download = app.descendants(matching: .any)["prototype.import.download"]
        let save = app.descendants(matching: .any)["prototype.import.save"]
        XCTAssertTrue(download.waitForExistence(timeout: 5))
        try await Task.sleep(for: .seconds(6))
        XCTAssertEqual(download.value as? String, "Выполняется")
        XCTAssertEqual(save.value as? String, "Ожидает")
        try await control("normal")
        XCTAssertTrue(app.descendants(matching: .any)["prototype.mode.drawer"].waitForExistence(timeout: 20))
    }

    func testImportDialogShowsStepsAndReturnsToDraftAfterFailure() throws {
        let app = launch()
        try openSubscriptionLink("http://localhost:18081/subscription/slow-error", in: app)
        let download = app.descendants(matching: .any)["prototype.import.download"]
        let save = app.descendants(matching: .any)["prototype.import.save"]
        let submit = app.buttons["prototype.subscription.fetch"]
        let dialog = app.alerts["prototype.import.dialog"]
        XCTAssertFalse(download.exists)
        submit.tap()
        XCTAssertTrue(dialog.waitForExistence(timeout: 3))
        XCTAssertEqual(download.value as? String, "Выполняется")
        XCTAssertEqual(save.value as? String, "Ожидает")
        XCTAssertLessThan(download.frame.midY, save.frame.midY)
        XCTAssertFalse(submit.exists && submit.isEnabled)
        capture(app, "Subscription import in progress")
        let close = app.buttons["prototype.import.close"]
        XCTAssertTrue(close.waitForExistence(timeout: 15))
        XCTAssertEqual(download.value as? String, "Ошибка")
        XCTAssertEqual(save.value as? String, "Пропущено")
        XCTAssertTrue(app.staticTexts["Не удалось получить подписку (HTTP 404)."].exists)
        close.tap()
        XCTAssertFalse(dialog.exists)
        XCTAssertTrue(submit.isEnabled)
        let input = app.textFields["prototype.subscription.url"]
        XCTAssertEqual(input.value as? String, "http://localhost:18081/subscription/slow-error")
        input.tap()
        input.typeKey("a", modifierFlags: .command)
        let workingSource = "http://localhost:18081/subscription/both"
        input.typeText(workingSource + "\n")
        XCTAssertEqual(input.value as? String, workingSource)
        XCTAssertFalse(download.exists)
        submit.tap()
        XCTAssertTrue(app.buttons["prototype.mode.onboarding.done"].waitForExistence(timeout: 15))
    }

    func testCancellingImportDialogReturnsToReplacementForm() throws {
        let app = launch()
        addSubscription(app)
        let source = "http://localhost:18081/subscription/slow-error"
        try openSubscriptionLink(source, in: app)
        let submit = app.buttons["prototype.subscription.fetch"]
        XCTAssertTrue(submit.waitForExistence(timeout: 10))
        submit.tap()
        let cancel = app.buttons["prototype.import.cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 3))
        cancel.tap()
        XCTAssertTrue(submit.waitForExistence(timeout: 5))
        XCTAssertTrue(submit.isEnabled)
        XCTAssertEqual(app.textFields["prototype.subscription.url"].value as? String, source)
        app.buttons["Отмена"].tap()
        XCTAssertTrue(app.staticTexts["Обзор"].waitForExistence(timeout: 5))
        tabButton(app, "Профиль").tap()
        let edit = app.buttons["prototype.ui.item01"]
        for _ in 0 ..< 5 where !edit.isHittable { app.swipeUp() }
        edit.tap()
        let input = app.textFields["prototype.subscription.url"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        XCTAssertEqual(input.value as? String, "http://localhost:18081/subscription/both")
    }

    func testSubscriptionErrorCanBeDismissedAndRetriedWithoutFreezingInterface() async throws {
        let app = launch()
        addSubscription(app)
        try await control("offline")
        app.buttons["prototype.subscription.refresh"].tap()
        let notice = app.staticTexts["prototype.notice.message"]
        XCTAssertTrue(notice.waitForExistence(timeout: 10))
        XCTAssertEqual(notice.label, "Не удалось получить подписку (HTTP 503).")
        capture(app, "Subscription error before dismissal")
        app.buttons["prototype.notice.close"].tap()
        XCTAssertFalse(notice.exists)
        tabButton(app, "Профиль").tap()
        XCTAssertTrue(app.buttons["prototype.ui.item01"].waitForExistence(timeout: 5))
        tabButton(app, "Подключение").tap()
        app.buttons["prototype.subscription.refresh"].tap()
        XCTAssertTrue(notice.waitForExistence(timeout: 10))
        app.buttons["prototype.notice.close"].tap()
        XCTAssertFalse(notice.exists)
        app.buttons["prototype.mode"].tap()
        XCTAssertTrue(app.buttons["prototype.mode.close"].waitForExistence(timeout: 5))
        capture(app, "Interface responds after repeated subscription errors")
    }

    func testColdLaunchKeepsSavedSubscriptionAndModeWhenServerIsUnavailable() async throws {
        let app = launch()
        addSubscription(app)
        app.buttons["prototype.mode"].tap()
        app.buttons["prototype.ui.option01"].tap()
        app.buttons["prototype.mode"].tap()
        app.buttons["prototype.ui.option02"].tap()
        XCTAssertEqual(app.buttons["prototype.mode"].value as? String, "Обход БС")
        app.terminate()
        try await control("offline")
        let restored = launch(reset: false)
        XCTAssertTrue(restored.buttons["prototype.mode"].waitForExistence(timeout: 5))
        XCTAssertEqual(restored.buttons["prototype.mode"].value as? String, "Обход БС")
        restored.buttons["prototype.subscription.refresh"].tap()
        XCTAssertTrue(restored.staticTexts["Не удалось получить подписку (HTTP 503)."].waitForExistence(timeout: 10))
        XCTAssertTrue(restored.staticTexts["Обзор"].exists)
        XCTAssertTrue(tabButton(restored, "Профиль").isHittable)
        capture(restored, "Saved subscription after mode switch with server unavailable")
    }

    func testSystemDeepLinksUpdateAlreadyOpenSubscriptionForm() throws {
        let system = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
        let openTitle = NSPredicate(format: "label IN %@", ["Открыть", "Open"])
        let open = system.buttons.matching(openTitle).firstMatch
        let safariOpen = safari.buttons.matching(openTitle).firstMatch
        if safariOpen.exists { safariOpen.tap() }
        if open.exists { open.tap() }
        let app = launch()
        addSubscription(app)
        app.buttons["prototype.mode"].tap()
        XCTAssertTrue(app.buttons["prototype.mode.close"].waitForExistence(timeout: 5))
        for variant in ["changed", "restricted"] {
            safari.open(try XCTUnwrap(URL(string: "http://localhost:18081/deeplink/" + variant)))
            let link = safari.links["Open vipin"]
            XCTAssertTrue(link.waitForExistence(timeout: 10))
            link.tap()
            if safariOpen.waitForExistence(timeout: 3) { safariOpen.tap() }
            let input = app.textFields["prototype.subscription.url"]
            XCTAssertTrue(input.waitForExistence(timeout: 10))
            XCTAssertEqual(input.value as? String, "http://localhost:18081/subscription/" + variant)
        }
        capture(app, "System deep link updates existing draft")
        app.buttons["Отмена"].tap()
        XCTAssertTrue(app.buttons["prototype.mode"].waitForExistence(timeout: 5))
    }

    func testDeepLinkPrefillsSubscriptionAndKeepsFirstImportOnboarding() throws {
        let app = launch()
        let source = "http://localhost:18081/subscription/both"
        try openSubscriptionLink(source, in: app)
        let input = app.textFields["prototype.subscription.url"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        XCTAssertEqual(input.value as? String, source)
        XCTAssertFalse(tabButton(app, "Профиль").exists)
        capture(app, "Deep link subscription draft")
        app.buttons["prototype.subscription.fetch"].tap()
        XCTAssertTrue(app.staticTexts["prototype.mode.onboarding.title"].waitForExistence(timeout: 20))
    }

    func testDeepLinkReplacementCanBeCancelledAndAnotherLinkChangesTheDraft() throws {
        let app = launch()
        addSubscription(app)
        app.buttons["prototype.mode"].tap()
        XCTAssertTrue(app.buttons["prototype.mode.close"].waitForExistence(timeout: 5))
        try openSubscriptionLink("http://localhost:18081/subscription/changed", in: app)
        let input = app.textFields["prototype.subscription.url"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        XCTAssertEqual(input.value as? String, "http://localhost:18081/subscription/changed")
        try openSubscriptionLink("http://localhost:18081/subscription/restricted", in: app)
        XCTAssertEqual(input.value as? String, "http://localhost:18081/subscription/restricted")
        app.buttons["Отмена"].tap()
        XCTAssertTrue(app.buttons["prototype.mode"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Обзор"].exists)
        XCTAssertFalse(app.staticTexts["Обновлённый обзор"].exists)
    }

    func testDeepLinkSurvivesColdLaunchWithSavedSubscription() throws {
        let app = launch()
        addSubscription(app)
        app.launchEnvironment["PROTOTYPE_UI_RESET"] = "0"
        app.terminate()
        let source = "http://localhost:18081/subscription/changed"
        try openSubscriptionLink(source, in: app)
        let input = app.textFields["prototype.subscription.url"]
        XCTAssertTrue(input.waitForExistence(timeout: 15))
        XCTAssertEqual(input.value as? String, source)
        app.buttons["prototype.subscription.fetch"].tap()
        XCTAssertTrue(app.staticTexts["Обновлённый обзор"].waitForExistence(timeout: 20))
        XCTAssertFalse(app.staticTexts["prototype.mode.onboarding.title"].exists)
    }

    func testUnsupportedDeepLinkKeepsSavedSubscription() throws {
        let app = launch()
        addSubscription(app)
        app.launchEnvironment["PROTOTYPE_UI_RESET"] = "0"
        app.open(try XCTUnwrap(URL(string: "vipin://connect?url=https%3A%2F%2Fexample.org")))
        XCTAssertTrue(app.staticTexts["Не удалось открыть ссылку добавления подписки."].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Обзор"].exists)
        XCTAssertFalse(app.textFields["prototype.subscription.url"].exists)
    }

    private func openSubscriptionLink(_ source: String, in app: XCUIApplication) throws {
        var link = URLComponents()
        link.scheme = "vipin"
        link.host = "add-subscription"
        link.queryItems = [URLQueryItem(name: "url", value: source)]
        // XCTest relaunches the application when opening a URL.
        app.launchEnvironment["PROTOTYPE_UI_RESET"] = "0"
        app.open(try XCTUnwrap(link.url))
    }

    func testSubscriptionOnboardingOpensModesAndEndsAfterSelection() {
        let app = launch()
        addSubscription(app, name: "bundle", dismissOnboarding: false)
        let hint = app.staticTexts["prototype.mode.onboarding.title"]
        XCTAssertTrue(hint.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["prototype.mode.close"].isHittable)
        capture(app, "Mode onboarding")
        app.buttons["prototype.ui.option02"].tap()
        XCTAssertTrue(app.buttons["prototype.mode"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["prototype.mode"].value as? String, "Обход БС")
        XCTAssertFalse(hint.exists)
        app.buttons["prototype.subscription.refresh"].tap()
        app.buttons["prototype.mode"].tap()
        XCTAssertTrue(app.buttons["prototype.ui.option01"].waitForExistence(timeout: 5))
        XCTAssertFalse(hint.exists)
        app.terminate()
        let restored = launch(reset: false)
        XCTAssertTrue(restored.buttons["prototype.mode"].waitForExistence(timeout: 10))
        XCTAssertFalse(restored.staticTexts["prototype.mode.onboarding.title"].exists)
    }

    func testSubscriptionOnboardingCanBeDismissedWithLargeText() {
        let app = launch(largeText: true)
        addSubscription(app, dismissOnboarding: false)
        let done = app.buttons["prototype.mode.onboarding.done"]
        XCTAssertTrue(done.waitForExistence(timeout: 5))
        capture(app, "Mode onboarding large text")
        done.tap()
        XCTAssertTrue(app.buttons["prototype.mode"].waitForExistence(timeout: 5))
        XCTAssertTrue(tabButton(app, "Профиль").isHittable)
        app.buttons["prototype.mode"].tap()
        XCTAssertTrue(app.buttons["prototype.ui.option01"].waitForExistence(timeout: 5))
        XCTAssertFalse(done.exists)
    }

    func testSubscriptionWithoutModesDoesNotShowOnboarding() {
        let app = launch()
        addSubscription(app, name: "empty-lists", dismissOnboarding: false)
        XCTAssertTrue(app.buttons["prototype.mode"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["prototype.mode.onboarding.title"].exists)
        XCTAssertTrue(tabButton(app, "Профиль").isHittable)
    }

    func testCanSelectWDTTWhenItBecomesAvailableAfterImportWithoutModes() throws {
        let app = launch()
        addSubscription(app, name: "empty", dismissOnboarding: false)
        let mode = app.buttons["prototype.mode"]
        let connect = app.buttons["prototype.start"]
        XCTAssertTrue(mode.waitForExistence(timeout: 5))
        XCTAssertEqual(mode.value as? String, "Выберите режим")

        try openSubscriptionLink("http://localhost:18081/subscription/vk", in: app)
        let input = app.textFields["prototype.subscription.url"]
        XCTAssertTrue(input.waitForExistence(timeout: 10))
        app.buttons["prototype.subscription.fetch"].tap()
        XCTAssertTrue(input.waitForNonExistence(timeout: 15))
        XCTAssertEqual(mode.value as? String, "Выберите режим")
        XCTAssertFalse(connect.isEnabled)

        mode.tap()
        let wdtt = app.buttons["prototype.ui.option02"]
        XCTAssertTrue(wdtt.waitForExistence(timeout: 5))
        XCTAssertTrue(wdtt.isEnabled)
        wdtt.tap()
        XCTAssertTrue(mode.waitForExistence(timeout: 5))
        XCTAssertEqual(mode.value as? String, "Обход БС")
        XCTAssertTrue(connect.isEnabled)
    }

    func testRevokedWDTTDisablesOnlyThatModeAndSurvivesRelaunch() async throws {
        let setup = launch()
        addSubscription(setup, name: "device-access")
        setup.buttons["prototype.mode"].tap()
        XCTAssertTrue(setup.buttons["prototype.ui.option02"].isEnabled)
        setup.terminate()
        let app = launch(reset: false)
        XCTAssertTrue(app.buttons["prototype.subscription.refresh"].waitForExistence(timeout: 10))
        try await control("device-revoked")
        app.buttons["prototype.subscription.refresh"].tap()
        app.buttons["prototype.mode"].tap()
        let denied = app.buttons["prototype.ui.option02"]
        XCTAssertTrue(denied.waitForExistence(timeout: 10))
        let revoked = expectation(for: NSPredicate(format: "enabled == false"), evaluatedWith: denied)
        await fulfillment(of: [revoked], timeout: 10)
        XCTAssertFalse(denied.isEnabled)
        XCTAssertTrue(app.staticTexts["Доступ для этого устройства отозван"].exists)
        XCTAssertTrue(app.buttons["prototype.ui.option01"].isEnabled)
        capture(app, "Device access revoked")
        app.terminate()
        let restored = launch(reset: false)
        XCTAssertTrue(restored.buttons["prototype.mode"].waitForExistence(timeout: 10))
        restored.buttons["prototype.mode"].tap()
        XCTAssertFalse(restored.buttons["prototype.ui.option02"].isEnabled)
        XCTAssertTrue(restored.staticTexts["Доступ для этого устройства отозван"].exists)
        let identityURL = try XCTUnwrap(URL(string: "http://localhost:18081/identity"))
        let (identityData, _) = try await URLSession.shared.data(from: identityURL)
        let identity = try XCTUnwrap(JSONSerialization.jsonObject(with: identityData) as? [String: [String]])
        let hwids = try XCTUnwrap(identity["hwids"])
        XCTAssertEqual(hwids.count, 1, "HWID changed between requests or app launches")
        XCTAssertEqual(hwids.first?.count, 64)
    }

    func testFailoverDrawerShowsLiveServerStates() {
        let setup = launch()
        addSubscription(setup, name: "failover")
        setup.terminate()
        let snapshot = #"{"mode":"automatic","allDown":false,"selected":"node-2","selectedHealth":"up","selectedIndex":2,"total":4,"checking":"node-4","checkingIndex":4,"servers":[{"tag":"node-1","health":"down"},{"tag":"node-2","health":"up"},{"tag":"node-3","health":"unknown"},{"tag":"node-4","health":"down"}]}"#
        let app = launch(reset: false, vpnState: .connected, failover: snapshot)
        app.buttons["prototype.vpn.details"].tap()
        for (tag, state) in [("node-1", "Недоступен"), ("node-2", "Подключён"), ("node-3", "Резерв"), ("node-4", "Проверка…")] {
            let row = app.descendants(matching: .any)["prototype.vpn.server." + tag]
            XCTAssertTrue(row.waitForExistence(timeout: 5))
            XCTAssertTrue(row.label.contains(state), row.label)
        }
        capture(app, "sketch-new-failover")
    }

    func testCanAddSubscriptionImmediatelyAfterReset() {
        let app = launch()
        addSubscription(app)
        tabButton(app, "Профиль").tap()
        let reset = app.buttons["prototype.reset"]
        for _ in 0..<5 where !reset.isHittable { app.swipeUp() }
        reset.tap()
        app.alerts["Сбросить приложение?"].buttons["Сбросить"].tap()
        let input = app.textFields["prototype.subscription.url"]
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND enabled == true"), object: input)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 15), .completed)
        addSubscription(app, name: "vless")
    }

    func testDrawerQuotaRoutingAndFullReset() {
        let app = launch()
        addSubscription(app)
        let quota = app.descendants(matching: .any)["prototype.vpn.quota"]
        XCTAssertTrue(quota.waitForExistence(timeout: 5))
        XCTAssertTrue(quota.label.contains("Трафик на сегодня"))
        XCTAssertTrue(quota.label.contains("Осталось 2 ГБ из 2 ГБ"))
        XCTAssertFalse(app.staticTexts["Память"].isHittable)
        app.buttons["prototype.vpn.details"].tap()
        XCTAssertTrue(app.staticTexts["Серверы"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Память"].isHittable)
        XCTAssertFalse(app.staticTexts["Скачивание"].exists)
        XCTAssertFalse(app.staticTexts["Отправка"].exists)
        capture(app, "sketch-new-drawer")
        tabButton(app, "Роутинг").tap()
        XCTAssertTrue(app.buttons["prototype.routing.enabled"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["prototype.routing.enabled"].label, "RoskomVPN")
        capture(app, "sketch-new-routing")
        tabButton(app, "Профиль").tap()
        let reset = app.buttons["prototype.reset"]
        for _ in 0..<5 where !reset.isHittable { app.swipeUp() }
        XCTAssertTrue(reset.isHittable)
        reset.tap()
        app.alerts["Сбросить приложение?"].buttons["Отмена"].tap()
        XCTAssertTrue(tabButton(app, "Профиль").exists)
        capture(app, "sketch-new-profile")
        reset.tap()
        app.alerts["Сбросить приложение?"].buttons["Сбросить"].tap()
        let input = app.textFields["prototype.subscription.url"]
        XCTAssertTrue(input.waitForExistence(timeout: 15))
        let resetFinished = expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: input)
        wait(for: [resetFinished], timeout: 15)
        XCTAssertFalse(app.staticTexts["prototype.notice.message"].exists)
        capture(app, "subscription-after-full-reset")
        app.terminate()
        let restored = launch(reset: false)
        XCTAssertTrue(restored.textFields["prototype.subscription.url"].waitForExistence(timeout: 15))
    }

    func testLogButtonsShareCurrentAndSavedFiles() {
        let app = launch()
        addSubscription(app)
        tabButton(app, "Профиль").tap()
        let logs = app.buttons["prototype.logs"]
        for _ in 0..<5 where !logs.isHittable { app.swipeUp() }
        logs.tap()
        let current = app.buttons["Текущие логи"]
        let saved = app.buttons["Сохранённые логи"]
        XCTAssertTrue(current.waitForExistence(timeout: 5))
        XCTAssertTrue(saved.isHittable)
        XCTAssertEqual(current.frame.width, saved.frame.width, accuracy: 1)
        XCTAssertGreaterThanOrEqual(saved.frame.minY, current.frame.maxY)
        if UIDevice.current.userInterfaceIdiom == .phone {
            let firstTab = tabButton(app, "Подключение").frame
            let lastTab = tabButton(app, "Профиль").frame
            let tabItems = firstTab.union(lastTab)
            XCTAssertEqual(saved.frame.midX, tabItems.midX, accuracy: 2)
            XCTAssertEqual(saved.frame.minX, tabItems.minX, accuracy: 8)
            XCTAssertGreaterThanOrEqual(tabItems.minY - saved.frame.maxY, 16)
        }
        capture(app, "Log file sharing buttons")
        for (button, prefix) in [(current, "vpn-current-"), (saved, "vpn-diagnostics-")] {
            button.tap()
            let sheet = app.otherElements["ActivityListView"]
            XCTAssertTrue(sheet.waitForExistence(timeout: 10))
            let attachment = sheet.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", prefix)).firstMatch
            XCTAssertTrue(attachment.waitForExistence(timeout: 5))
            capture(app, "Shared file " + prefix)
            let close = sheet.buttons.matching(NSPredicate(format: "label IN %@", ["Закрыть", "Close"])).firstMatch
            if close.isHittable {
                close.tap()
            } else {
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.15)).tap()
            }
            XCTAssertTrue(sheet.waitForNonExistence(timeout: 5))
        }
    }

    func testFirstImportCanReadSavedDiagnosticsAndReturnToDraft() {
        let app = launch()
        let input = app.textFields["prototype.subscription.url"]
        XCTAssertTrue(input.waitForExistence(timeout: 10))
        let draft = "https://example.invalid/subscription"
        input.tap()
        input.typeText(draft + "\n")
        let logs = app.buttons["prototype.logs"]
        XCTAssertTrue(logs.waitForExistence(timeout: 5))
        for _ in 0..<3 where !logs.isHittable { app.swipeUp() }
        logs.tap()

        let diagnostics = app.buttons["prototype.logs.diagnostics"]
        XCTAssertTrue(diagnostics.waitForExistence(timeout: 5))
        diagnostics.tap()
        let text = app.textViews["prototype.logs.diagnostics.text"]
        XCTAssertTrue(text.waitForExistence(timeout: 15))
        XCTAssertTrue((text.value as? String)?.contains("VPN diagnostics") == true)
        app.buttons["Закрыть"].tap()
        XCTAssertTrue(text.waitForNonExistence(timeout: 5))
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        XCTAssertEqual(input.value as? String, draft)
    }

    func testIncompatibleSavedSubscriptionCanBeReimportedAfterTwoColdLaunches() {
        var app = launch(arguments: ["-UITestIncompatibleSubscription"])
        let message = "Не удалось прочитать сохранённую подписку. Вставьте ссылку ещё раз или откройте «Логи»."
        XCTAssertTrue(app.staticTexts["prototype.notice.message"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["prototype.notice.message"].label, message)
        app.terminate()
        app = launch(reset: false)
        XCTAssertTrue(app.staticTexts["prototype.notice.message"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["prototype.notice.message"].label, message)
        app.buttons["prototype.notice.close"].tap()
        app.buttons["prototype.logs"].tap()
        XCTAssertTrue(app.buttons["prototype.logs.diagnostics"].waitForExistence(timeout: 10))
        app.navigationBars.buttons.firstMatch.tap()
        addSubscription(app)
        app.terminate()
        app = launch(reset: false)
        XCTAssertTrue(tabButton(app, "Профиль").waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["prototype.notice.message"].exists)
    }

    func testSavedDiagnosticsCanBeReadAndSharedWhileDisconnected() {
        let app = launch()
        addSubscription(app)
        tabButton(app, "Профиль").tap()
        let logs = app.buttons["prototype.logs"]
        for _ in 0..<5 where !logs.isHittable { app.swipeUp() }
        XCTAssertTrue(logs.waitForExistence(timeout: 5))
        logs.tap()
        XCTAssertTrue(app.staticTexts["VPN отключён"].waitForExistence(timeout: 5))
        app.buttons["prototype.logs.diagnostics"].tap()
        let text = app.textViews["prototype.logs.diagnostics.text"]
        XCTAssertTrue(text.waitForExistence(timeout: 15))
        XCTAssertTrue((text.value as? String)?.contains("[app] application loaded") == true)
        XCTAssertTrue((text.value as? String)?.contains("VPN diagnostics") == true)
        app.buttons["prototype.logs.diagnostics.clear"].tap()
        let confirmation = app.alerts["Удалить сохранённые отчёты?"]
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5))
        confirmation.buttons["Отмена"].tap()
        app.buttons["prototype.logs.diagnostics.share"].tap()
        XCTAssertTrue(app.otherElements["ActivityListView"].waitForExistence(timeout: 10))
        capture(app, "Saved diagnostics share sheet")
    }

    override func setUp() async throws {
        continueAfterFailure = false
        try await control("normal")
    }

    private func control(_ variant: String) async throws {
        let url = try XCTUnwrap(URL(string: "http://localhost:18081/control/" + variant))
        let (_, response) = try await URLSession.shared.data(from: url)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
    }

    private func launch(reset: Bool = true, vpnState: NEVPNStatus? = nil, largeText: Bool = false, connectionStatus: String? = nil, failover: String? = nil, arguments: [String] = []) -> XCUIApplication {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchEnvironment["PROTOTYPE_UI_TESTING"] = "1"
        app.launchEnvironment["PROTOTYPE_UI_RESET"] = reset ? "1" : "0"
        if let vpnState {
            app.launchEnvironment["PROTOTYPE_UI_VPN_STATE"] = String(vpnState.rawValue)
        }
        if let connectionStatus {
            app.launchEnvironment["PROTOTYPE_UI_STATUS"] = connectionStatus
        }
        if let failover { app.launchEnvironment["PROTOTYPE_UI_FAILOVER"] = failover }
        app.launchArguments += ["-AppleLanguages", "(ru)", "-AppleLocale", "ru_RU"]
        app.launchArguments += arguments
        if largeText {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        }
        app.launch()
        let portrait = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            let frame = app.windows.firstMatch.frame
            return frame.height > frame.width
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [portrait], timeout: 10), .completed)
        return app
    }

    private func tabButton(_ app: XCUIApplication, _ title: String) -> XCUIElement {
        // iPad exposes the native top tabs as buttons rather than a TabBar.
        app.buttons.matching(NSPredicate(format: "label == %@", title)).firstMatch
    }

    private func addSubscription(_ app: XCUIApplication, name: String = "both", server: String = "http://localhost:18081", dismissOnboarding: Bool = true) {
        let input = app.textFields["prototype.subscription.url"]
        XCTAssertTrue(input.waitForExistence(timeout: 15))
        input.tap()
        if !app.keyboards.firstMatch.waitForExistence(timeout: 3) {
            input.tap()
        }
        input.typeText(server + "/subscription/" + name)
        app.buttons["prototype.subscription.fetch"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["prototype.mode.drawer"].waitForExistence(timeout: 20))
        if dismissOnboarding {
            let done = app.buttons["prototype.mode.onboarding.done"]
            if done.waitForExistence(timeout: 5) { done.tap() }
        }
        if dismissOnboarding {
            XCTAssertTrue(tabButton(app, "Профиль").waitForExistence(timeout: 20))
        }
    }

    private func capture(_: XCUIApplication, _ name: String) {
        // Capture the display: application-only captures can crop rotated scenes.
        let screenshot = XCUIScreen.main.screenshot()
        if name.hasPrefix("sketch-") {
            let path = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(name + ".png")
            try? screenshot.pngRepresentation.write(to: path)
        }
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func assertPortraitOnPhone(_ app: XCUIApplication) {
        // iPadOS windowing can expose landscape window bounds around a portrait scene.
        // Check the layout and controls on iPad instead of assuming phone window geometry.
        guard UIDevice.current.userInterfaceIdiom == .phone else { return }
        let portrait = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            app.windows.firstMatch.frame.height > app.windows.firstMatch.frame.width
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [portrait], timeout: 10), .completed)
    }

    func testHoldingConnectionButtonActivatesOnRelease() {
        let app = launch(arguments: ["-prototype.privacy.reviewed.2026-10-22", "NO"])
        addSubscription(app)
        let button = app.buttons["prototype.start"]
        XCTAssertTrue(button.isEnabled)
        let frame = button.frame
        let card = app.descendants(matching: .any)["prototype.vpn.card"]
        XCTAssertLessThan(frame.maxY, card.frame.maxY, "The entire capsule should sit inside the card border")
        let version = app.staticTexts["prototype.app.version"]
        XCTAssertTrue(version.exists)
        XCTAssertNotNil((version.value as? String)?.range(of: #"^\d+(\.\d+)* \(\d+(\.\d+)*\)$"#, options: .regularExpression))
        let versionFrame = version.frame
        XCTAssertGreaterThanOrEqual(versionFrame.minY, card.frame.maxY)
        if UIDevice.current.userInterfaceIdiom == .phone {
            XCTAssertLessThanOrEqual(versionFrame.maxY, tabButton(app, "Подключение").frame.minY)
        }
        capture(app, "Connection card with app version")
        button.press(forDuration: 1.5)
        let confirmation = app.alerts["Перед подключением"]
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5))
        confirmation.buttons["Отмена"].tap()
        XCTAssertEqual(button.frame, frame)
        XCTAssertEqual(button.value as? String, "Отключено")
        let start = button.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        for offset in [CGVector(dx: 0, dy: -18), CGVector(dx: 40, dy: 0)] {
            start.press(forDuration: 0.1, thenDragTo: start.withOffset(offset),
                        withVelocity: .slow, thenHoldForDuration: 0.3)
            XCTAssertFalse(confirmation.exists, "Dragging inside the capsule must also cancel activation")
        }
        start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -180)),
                    withVelocity: .fast, thenHoldForDuration: 0)
        let details = app.buttons["prototype.vpn.details"]
        XCTAssertEqual(details.value as? String, "Развёрнуто")
        XCTAssertFalse(confirmation.exists)
        XCTAssertEqual(version.frame, versionFrame)
    }

    func testConnectionHealthStatesKeepDisconnectAvailable() {
        let setup = launch()
        addSubscription(setup)
        let start = setup.buttons["prototype.start"]
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        XCTAssertEqual(start.value as? String, "Отключено")
        setup.terminate()
        for value in ["Проверка соединения…", "Сервер недоступен", "Подключено"] {
            let app = launch(reset: false, vpnState: .connected, connectionStatus: value)
            let status = app.descendants(matching: .any).matching(identifier: "prototype.status").firstMatch
            XCTAssertTrue(status.waitForExistence(timeout: 10))
            XCTAssertEqual(status.value as? String, value)
            XCTAssertTrue(app.buttons["prototype.stop"].isEnabled)
            XCTAssertEqual(app.buttons["prototype.stop"].value as? String, value)
            XCTAssertTrue(app.buttons["prototype.stop"].isHittable)
            capture(app, "Connection health: " + value)
            app.buttons["prototype.mode"].tap()
            XCTAssertTrue(app.buttons["prototype.ui.option01"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.buttons["prototype.ui.option01"].isEnabled)
            XCTAssertTrue(app.buttons["prototype.ui.option02"].isEnabled)
            app.terminate()
        }
    }

    func testCanChooseAnotherModeWhileConnecting() {
        let setup = launch()
        addSubscription(setup)
        setup.terminate()

        let app = launch(reset: false, vpnState: .connecting)
        let stop = app.buttons["prototype.stop"]
        XCTAssertTrue(stop.waitForExistence(timeout: 10))
        XCTAssertEqual(stop.value as? String, "Подключение…")
        let mode = app.buttons["prototype.mode"]
        XCTAssertEqual(mode.value as? String, "Обычный ВПН")
        mode.tap()
        let bypass = app.buttons["prototype.ui.option02"]
        XCTAssertTrue(bypass.waitForExistence(timeout: 5))
        XCTAssertTrue(bypass.isEnabled)
        bypass.tap()
        XCTAssertTrue(mode.waitForExistence(timeout: 5))
        XCTAssertEqual(mode.value as? String, "Обход БС")
    }

    func testCurrentStandaloneServerUsesNeutralContent() {
        let app = launch()
        addSubscription(app, name: "synthetic-e2e-subscription-token", server: "http://localhost:18082")
        XCTAssertTrue(app.staticTexts["Подписка"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Обзор"].exists)
        tabButton(app, "Профиль").tap()
        XCTAssertTrue(app.staticTexts["Количество серверов"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["17"].exists)
        XCTAssertEqual(app.buttons["prototype.ui.button02"].label, "Открыть список")
        capture(app, "standalone-server-neutral-profile")
        app.buttons["prototype.ui.item02"].tap()
        XCTAssertEqual(app.buttons["prototype.ui.button03"].label, "Документация")
        app.buttons["Отмена"].tap()
        tabButton(app, "Подключение").tap()
        app.buttons["prototype.mode"].tap()
        XCTAssertTrue(app.buttons["prototype.ui.option01"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["prototype.ui.option01"].label, "Вариант 1")
        XCTAssertEqual(app.buttons["prototype.ui.option02"].label, "Вариант 2")
    }

    func testNativeTabBarSwitchesTabsAndRetainsRoutingChoice() throws {
        let app = launch()
        addSubscription(app)
        let tabs = app.tabBars.firstMatch
        XCTAssertTrue(tabs.waitForExistence(timeout: 5))
        XCTAssertEqual(tabs.buttons.count, 3)
        XCTAssertTrue(tabs.buttons["Подключение"].isSelected)
        // The mode header starts below the status bar on both SE and Face ID phones.
        let screenWidth = app.frame.width
        let statusArea = CGRect(x: 0, y: 0, width: screenWidth / 4, height: app.buttons["prototype.mode"].frame.minY)
        try assertStatusBarInk(in: statusArea, screenWidth: screenWidth, light: true)
        capture(app, "native-tabs-connection")

        tabs.buttons["Роутинг"].tap()
        let picker = app.otherElements["prototype.routing.mode"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        app.buttons["prototype.routing.russiaInside"].tap()
        XCTAssertTrue(tabs.buttons["Роутинг"].isSelected)
        try assertStatusBarInk(in: statusArea, screenWidth: screenWidth, light: false)
        capture(app, "native-tabs-routing")

        tabs.buttons["Профиль"].tap()
        XCTAssertTrue(app.buttons["prototype.subscription.refresh"].waitForExistence(timeout: 5))
        XCTAssertTrue(tabs.buttons["Профиль"].isSelected)
        try assertStatusBarInk(in: statusArea, screenWidth: screenWidth, light: false)
        capture(app, "native-tabs-profile")

        tabs.buttons["Роутинг"].tap()
        XCTAssertTrue(app.buttons["prototype.routing.russiaInside"].isSelected)
        tabs.buttons["Подключение"].tap()
        XCTAssertTrue(app.buttons["prototype.start"].waitForExistence(timeout: 5))
        XCTAssertTrue(tabs.buttons["Подключение"].isSelected)
        try assertStatusBarInk(in: statusArea, screenWidth: screenWidth, light: true)
    }

    private func assertStatusBarInk(in area: CGRect, screenWidth: CGFloat, light: Bool, file: StaticString = #filePath, line: UInt = #line) throws {
        let display = try XCTUnwrap(XCUIScreen.main.screenshot().image.cgImage)
        let scale = CGFloat(display.width) / screenWidth
        let crop = try XCTUnwrap(display.cropping(to: area.applying(CGAffineTransform(scaleX: scale, y: scale))))
        var pixels = [UInt8](repeating: 0, count: crop.width * crop.height)
        try pixels.withUnsafeMutableBytes { buffer in
            let gray = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: crop.width, height: crop.height, bitsPerComponent: 8,
                                               bytesPerRow: crop.width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue))
            gray.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
        }
        // Require visible strokes in the expected color, occupying less area than the background.
        let ink = pixels.filter { light ? $0 > 225 : $0 < 45 }.count
        XCTAssertTrue(ink > 20 && ink < pixels.count / 2, "Expected \(light ? "light" : "dark") status bar text and icons", file: file, line: line)
    }

    func testSketchScreenMatrix() {
        let app = launch()
        XCTAssertTrue(app.textFields["prototype.subscription.url"].waitForExistence(timeout: 15))
        capture(app, "sketch-00")
        let input = app.textFields["prototype.subscription.url"]
        input.tap()
        if !app.keyboards.firstMatch.waitForExistence(timeout: 3) {
            input.tap()
        }
        input.typeText("http://localhost:18081/subscription/both\n")
        capture(app, "sketch-00a")
        app.buttons["prototype.subscription.fetch"].tap()
        XCTAssertTrue(tabButton(app, "Профиль").waitForExistence(timeout: 20))
        let card = app.descendants(matching: .any)["prototype.vpn.card"]
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        capture(app, "sketch-04")
        XCTAssertEqual(card.frame.height, 198, accuracy: 2, "Sketch compact card is 198 pt")
        let bottom = card.frame.maxY
        app.buttons["prototype.vpn.details"].tap()
        let expanded = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            abs(card.frame.height - 418) < 2
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [expanded], timeout: 5), .completed)
        XCTAssertEqual(card.frame.maxY, bottom, accuracy: 2)
        capture(app, "sketch-05")
        tabButton(app, "Профиль").tap()
        capture(app, "sketch-06")
        app.buttons["prototype.ui.item02"].tap()
        XCTAssertTrue(app.buttons["prototype.ui.button03"].waitForExistence(timeout: 5))
        capture(app, "sketch-07")
        app.buttons["Отмена"].tap()
        app.terminate()
        let connected = launch(reset: false, vpnState: .connected)
        XCTAssertTrue(connected.buttons["prototype.stop"].waitForExistence(timeout: 10))
        capture(connected, "sketch-01")
        connected.buttons["prototype.vpn.details"].tap()
        sleep(1)
        capture(connected, "sketch-02")
        connected.buttons["prototype.vpn.details"].tap()
        connected.buttons["prototype.mode"].tap()
        XCTAssertTrue(connected.buttons["prototype.mode.close"].waitForExistence(timeout: 5))
        sleep(1)
        capture(connected, "sketch-03")
        connected.terminate()
        let setupRestricted = launch()
        addSubscription(setupRestricted, name: "restricted")
        setupRestricted.terminate()
        let restricted = launch(reset: false, vpnState: .connected)
        XCTAssertTrue(restricted.buttons["prototype.stop"].waitForExistence(timeout: 10))
        restricted.buttons["prototype.mode"].tap()
        XCTAssertTrue(restricted.buttons["prototype.ui.button05"].waitForExistence(timeout: 10))
        sleep(1)
        capture(restricted, "sketch-03a")
    }

    func testOnboardingFailureRetainsInputAndCompleteSubscriptionSurvivesRestart() {
        let app = launch()
        let input = app.textFields["prototype.subscription.url"]
        XCTAssertTrue(input.waitForExistence(timeout: 15))
        input.tap()
        let source = "http://localhost:18081/subscription/error"
        if !app.keyboards.firstMatch.waitForExistence(timeout: 3) {
            input.tap()
        }
        input.typeText(source)
        app.buttons["prototype.subscription.fetch"].tap()
        XCTAssertTrue(app.staticTexts["Не удалось получить подписку (HTTP 404)."].waitForExistence(timeout: 15))
        capture(app, "00a - failed onboarding")
        app.buttons["prototype.import.close"].tap()
        XCTAssertEqual(input.value as? String, source)
        app.terminate()
        let clean = launch()
        capture(clean, "00 - initial")
        addSubscription(clean)
        capture(clean, "04 - disconnected compact")
        clean.terminate()
        let restored = launch(reset: false)
        XCTAssertTrue(tabButton(restored, "Профиль").waitForExistence(timeout: 15))
        XCTAssertFalse(restored.textFields["prototype.subscription.url"].exists)
    }

    func testProfileNavigationReplacementCancellationAndNativeDialog() throws {
        let app = launch()
        addSubscription(app)
        app.buttons["prototype.subscription.profile"].tap()
        XCTAssertTrue(app.buttons["prototype.ui.button01"].waitForExistence(timeout: 5))
        XCTAssertGreaterThanOrEqual(app.buttons["prototype.ui.button02"].frame.height, 44)
        try app.performAccessibilityAudit(for: [.hitRegion])
        capture(app, "06 - profile")
        app.buttons["prototype.ui.item01"].tap()
        XCTAssertTrue(app.textFields["prototype.subscription.url"].waitForExistence(timeout: 5))
        app.buttons["Отмена"].tap()
        XCTAssertTrue(app.buttons["prototype.ui.button01"].waitForExistence(timeout: 5))
        app.buttons["prototype.ui.item02"].tap()
        XCTAssertTrue(app.buttons["prototype.ui.button03"].waitForExistence(timeout: 5))
        capture(app, "07 - native account dialog")
        if app.buttons["Отмена"].exists {
            app.buttons["Отмена"].tap()
        } else {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.15)).tap()
        }
        app.buttons["prototype.logs"].tap()
        XCTAssertTrue(app.staticTexts["VPN отключён"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["prototype.vless.paste"].exists)
        let back = app.navigationBars.buttons.firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 5))
        back.tap()
        app.buttons["prototype.settings"].tap()
        XCTAssertTrue(app.navigationBars["Настройки приложения"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.navigationBars.buttons.firstMatch.isHittable)
    }

    func testClearSubscriptionLinkEditsOnlyTheDraft() {
        let app = launch()
        addSubscription(app)
        tabButton(app, "Профиль").tap()
        let edit = app.buttons["prototype.ui.item01"]
        edit.tap()
        let input = app.textFields["prototype.subscription.url"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        let original = input.value as? String
        XCTAssertEqual(original, "http://localhost:18081/subscription/both")
        let clear = app.buttons["Очистить"]
        XCTAssertTrue(clear.isHittable)
        capture(app, "Edit subscription link with Clear button")
        clear.tap()
        XCTAssertEqual(input.value as? String, input.placeholderValue)
        XCTAssertFalse(app.buttons["prototype.subscription.fetch"].isEnabled)
        XCTAssertTrue(app.buttons["prototype.subscription.paste"].isEnabled)
        input.typeText("https://example.org/new")
        XCTAssertEqual(input.value as? String, "https://example.org/new")
        app.buttons["Отмена"].tap()
        edit.tap()
        XCTAssertEqual(input.value as? String, original)
    }

    func testModeHeaderReservesSystemStatusArea() {
        let app = launch()
        addSubscription(app)
        XCTAssertGreaterThanOrEqual(app.buttons["prototype.mode"].frame.minY, 44)
        capture(app, "status bar above connection mode")
    }

    func testConnectionBackgroundIsFixedAndRotationKeepsPortrait() {
        let app = launch()
        defer { XCUIDevice.shared.orientation = .portrait }
        addSubscription(app)
        XCTAssertEqual(app.scrollViews.containing(.staticText, identifier: "Подписка").count, 0)
        let original = app.windows.firstMatch.frame
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertGreaterThan(app.windows.firstMatch.frame.height, app.windows.firstMatch.frame.width)
        XCTAssertEqual(app.windows.firstMatch.frame.width, original.width, accuracy: 2)
        capture(app, "portrait - fixed connection background")
    }

    func testVPNDetailsOpenAndCloseByDraggingHeader() {
        let app = launch()
        addSubscription(app)
        let card = app.descendants(matching: .any)["prototype.vpn.card"]
        let compactHeight = card.frame.height
        let bottom = card.frame.maxY
        for _ in 0 ..< 5 {
            let handle = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: card.frame.midX, dy: card.frame.minY + 8))
            handle.press(forDuration: 0.1, thenDragTo: handle.withOffset(CGVector(dx: 0, dy: -150)))
            let expanded = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                card.frame.height > compactHeight + 100
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [expanded], timeout: 5), .completed)
            XCTAssertEqual(card.frame.maxY, bottom, accuracy: 2)
            capture(app, "gesture-expanded VPN details")
            let expandedHandle = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: card.frame.midX, dy: card.frame.minY + 8))
            expandedHandle.press(forDuration: 0.1, thenDragTo: expandedHandle.withOffset(CGVector(dx: 0, dy: 150)))
            let collapsed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                abs(card.frame.height - compactHeight) < 2
            }, object: nil)
            let collapseResult = XCTWaiter.wait(for: [collapsed], timeout: 5)
            capture(app, "gesture-collapsed VPN details")
            let state = String(describing: app.buttons["prototype.vpn.details"].value)
            XCTAssertEqual(collapseResult, .completed, "Card height: \(card.frame.height), compact: \(compactHeight), state: \(state)")
            XCTAssertEqual(card.frame.maxY, bottom, accuracy: 2)
        }
    }

    func testModeHeaderMovesBelowChoicesWhenDrawerOpens() {
        let app = launch()
        addSubscription(app)
        let header = app.buttons["prototype.mode"]
        let collapsedTop = header.frame.minY
        header.tap()
        let openedHeader = app.buttons["prototype.mode.close"]
        XCTAssertTrue(openedHeader.waitForExistence(timeout: 5))
        let moved = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            openedHeader.frame.minY > collapsedTop + 100
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [moved], timeout: 5), .completed)
        XCTAssertLessThan(app.buttons["prototype.ui.option01"].frame.maxY, openedHeader.frame.minY)
        capture(app, "drawer - red surface and white mode cards")
        openedHeader.tap()
        XCTAssertTrue(header.waitForExistence(timeout: 5))
        XCTAssertEqual(header.frame.minY, collapsedTop, accuracy: 2)
    }

    func testVPNDetailsSwipeAcrossEntireCard() {
        let app = launch()
        addSubscription(app)
        let card = app.descendants(matching: .any)["prototype.vpn.card"]
        let details = app.buttons["prototype.vpn.details"]
        let connect = app.buttons["prototype.start"]
        let compactHeight = card.frame.height
        let buttonFrame = connect.frame
        for point in [CGVector(dx: 0.08, dy: 0.22), CGVector(dx: 0.5, dy: 0.5),
                      CGVector(dx: 0.03, dy: 0.7), CGVector(dx: 0.5, dy: 0.88)]
        {
            for (distance, expanded): (CGFloat, Bool) in [(-180, true), (180, false)] {
                let start = card.coordinate(withNormalizedOffset: point)
                start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: 0, dy: distance)),
                            withVelocity: .slow, thenHoldForDuration: 0.3)
                let settled = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                    (details.value as? String) == (expanded ? "Развёрнуто" : "Свёрнуто")
                        && (expanded ? card.frame.height > compactHeight + 100 : abs(card.frame.height - compactHeight) < 2)
                }, object: nil)
                XCTAssertEqual(XCTWaiter.wait(for: [settled], timeout: 5), .completed,
                               "Swipe at \(point), distance \(distance) must resize the card")
                XCTAssertEqual(connect.frame.minY, buttonFrame.minY, accuracy: 2)
                XCTAssertTrue(connect.isHittable)
                XCTAssertLessThan(details.frame.maxY, card.frame.minY + 64)
                XCTAssertGreaterThanOrEqual(details.frame.minY, card.frame.minY)
                XCTAssertEqual(app.descendants(matching: .any)["prototype.status"].value as? String, "Отключено")
            }
        }
        details.tap()
        XCTAssertEqual(details.value as? String, "Развёрнуто")
        details.tap()
        XCTAssertEqual(details.value as? String, "Свёрнуто")
        capture(app, "drawer - entire card accepts swipes")
    }

    func testVPNShortFlickSettlesAcrossHeaderEdgesAndContent() {
        let app = launch()
        addSubscription(app)
        let card = app.descendants(matching: .any)["prototype.vpn.card"]
        let details = app.buttons["prototype.vpn.details"]
        let compactHeight = card.frame.height
        let buttonTop = app.buttons["prototype.start"].frame.minY
        for (name, x, y): (String, CGFloat, CGFloat) in [
            ("details button", 0.5, 0.5), ("header", 0.25, 36), ("left edge", 0.02, 36),
            ("right edge", 0.98, 36), ("content", 0.5, 90), ("connect button", 0.5, -25),
        ] {
            for (distance, expanded): (CGFloat, Bool) in [(-80, true), (80, false)] {
                let start = name == "details button"
                    ? details.coordinate(withNormalizedOffset: CGVector(dx: x, dy: y))
                    : app.coordinate(withNormalizedOffset: .zero)
                    .withOffset(CGVector(dx: card.frame.minX + card.frame.width * x,
                                         dy: y < 0 ? card.frame.maxY + y : card.frame.minY + y))
                start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: distance)),
                            withVelocity: .fast, thenHoldForDuration: 0)
                let settled = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                    details.value as? String == (expanded ? "Развёрнуто" : "Свёрнуто")
                        && (expanded ? card.frame.height > compactHeight + 200 : abs(card.frame.height - compactHeight) < 2)
                }, object: nil)
                XCTAssertEqual(XCTWaiter.wait(for: [settled], timeout: 5), .completed,
                               "Short flick from \(name), distance \(distance) must finish after release")
                XCTAssertEqual(app.buttons["prototype.start"].frame.minY, buttonTop, accuracy: 2)
                XCTAssertEqual(app.descendants(matching: .any)["prototype.status"].value as? String, "Отключено")
            }
        }
        capture(app, "drawer - short flicks settle from all surfaces")
    }

    func testVPNDraggingKeepsConnectButtonAnchored() {
        let app = launch()
        addSubscription(app)
        let card = app.descendants(matching: .any)["prototype.vpn.card"]
        let button = app.buttons["prototype.start"]
        let originalButton = button.frame
        let compactHeight = card.frame.height
        for (distance, isExpanded): (CGFloat, Bool) in [(-45, false), (-180, true), (45, true), (180, false)] {
            let handle = app.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: card.frame.midX, dy: card.frame.minY + 8))
            handle.press(forDuration: 0.1, thenDragTo: handle.withOffset(CGVector(dx: 0, dy: distance)),
                         withVelocity: .slow, thenHoldForDuration: 0.5)
            XCTAssertEqual(button.frame.minY, originalButton.minY, accuracy: 2)
            XCTAssertEqual(button.frame.maxY, originalButton.maxY, accuracy: 2)
            XCTAssertTrue(button.isHittable)
            XCTAssertEqual(app.buttons["prototype.vpn.details"].value as? String, isExpanded ? "Развёрнуто" : "Свёрнуто")
            capture(app, "drawer - slow VPN drag \(distance)")
        }
        XCTAssertEqual(card.frame.height, compactHeight, accuracy: 2)
    }

    func testVPNFixedControlsCloseDrawerAfterScrollingLargeDetails() {
        let app = launch(largeText: true)
        addSubscription(app)
        let card = app.descendants(matching: .any)["prototype.vpn.card"]
        let details = app.buttons["prototype.vpn.details"]
        let compactHeight = card.frame.height
        for useConnectButton in [false, true] {
            details.tap()
            let scroll = card.scrollViews.firstMatch
            let memory = app.staticTexts["Память"]
            let memoryTop = memory.frame.minY
            scroll.swipeUp()
            XCTAssertLessThan(memory.frame.minY, memoryTop - 20, "Overflowing metrics must remain scrollable")
            let expandedHeight = card.frame.height
            scroll.swipeDown()
            XCTAssertEqual(card.frame.height, expandedHeight, accuracy: 2,
                           "Returning scrolled content to its start must not jump into a collapse")
            scroll.swipeUp()
            let start = useConnectButton
                ? app.buttons["prototype.start"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                : app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: card.frame.midX, dy: card.frame.minY + 8))
            let distance = useConnectButton ? min(180, app.windows.firstMatch.frame.maxY - app.buttons["prototype.start"].frame.midY - 20) : 180
            start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: 0, dy: distance)),
                        withVelocity: .slow, thenHoldForDuration: 0.3)
            let collapsed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                abs(card.frame.height - compactHeight) < 2 && details.value as? String == "Свёрнуто"
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [collapsed], timeout: 5), .completed)
        }
        capture(app, "drawer - fixed controls close scrolled large details")
    }

    func testDrawerModesDetailsScrimAndVPNExpansion() {
        let app = launch()
        addSubscription(app, name: "restricted")
        let card = app.descendants(matching: .any)["prototype.vpn.card"]
        let bottom = card.frame.maxY
        let compactHeight = card.frame.height
        app.buttons["prototype.vpn.details"].tap()
        let expanded = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            card.frame.height > compactHeight + 100
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [expanded], timeout: 5), .completed)
        XCTAssertEqual(card.frame.maxY, bottom, accuracy: 2)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Память")).firstMatch.waitForExistence(timeout: 5))
        capture(app, "05 - disconnected expanded")
        app.buttons["prototype.mode"].tap()
        let drawer = app.descendants(matching: .any)["prototype.mode.drawer"]
        XCTAssertTrue(drawer.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["prototype.ui.option02"].isEnabled)
        XCTAssertFalse(app.buttons["prototype.ui.option03"].isEnabled)
        XCTAssertEqual(app.buttons["prototype.ui.button05"].label, "Сменить тариф")
        XCTAssertTrue(app.staticTexts["Смените тариф, чтобы получить доступ к обходу белых списков"].exists)
        XCTAssertGreaterThanOrEqual(app.buttons["prototype.ui.option01.details"].frame.height, 44)
        capture(app, "03a - restricted drawer")
        app.buttons["prototype.ui.option01.details"].tap()
        XCTAssertTrue(app.navigationBars["Обычный ВПН"].waitForExistence(timeout: 5))
        app.buttons["Закрыть"].tap()
        XCTAssertTrue(app.buttons["prototype.mode"].waitForExistence(timeout: 5))
        let mode = app.buttons["prototype.mode"]
        let begin = mode.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.88))
        let distance: CGFloat = 150
        begin.press(forDuration: 0.1, thenDragTo: begin.withOffset(CGVector(dx: 0, dy: distance)))
        XCTAssertTrue(app.buttons["prototype.mode.close"].waitForExistence(timeout: 5))
        capture(app, "drawer - after opening by gesture")
        capture(app, "03 - gesture-opened drawer")
        app.buttons["prototype.ui.option01.details"].tap()
        XCTAssertTrue(app.navigationBars["Обычный ВПН"].waitForExistence(timeout: 5))
        app.buttons["Закрыть"].tap()
        XCTAssertTrue(app.buttons["prototype.mode"].waitForExistence(timeout: 5))
        app.buttons["prototype.mode"].tap()
        XCTAssertTrue(app.buttons["prototype.mode.close"].waitForExistence(timeout: 5))
        let close = app.buttons["prototype.mode.handle"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        close.press(forDuration: 0.1, thenDragTo: close.withOffset(CGVector(dx: 0, dy: -150)))
        XCTAssertTrue(app.buttons["prototype.mode"].waitForExistence(timeout: 5))
        app.buttons["prototype.mode"].tap()
        XCTAssertTrue(app.buttons["prototype.mode.close"].waitForExistence(timeout: 5))
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.82)).tap()
        XCTAssertTrue(app.buttons["prototype.mode"].waitForExistence(timeout: 5))
        XCTAssertTrue(tabButton(app, "Подключение").isSelected)
    }

    func testHiddenMenuKeepsLocalToolsAndEmptyTransportDisablesStart() {
        let app = launch()
        addSubscription(app, name: "hidden")
        tabButton(app, "Профиль").tap()
        XCTAssertTrue(app.buttons["prototype.logs"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["prototype.settings"].exists)
        XCTAssertFalse(app.buttons["prototype.ui.item03"].exists)
        app.terminate()
        let empty = launch()
        addSubscription(empty, name: "empty")
        XCTAssertFalse(empty.buttons["prototype.start"].isEnabled)
        XCTAssertTrue(empty.staticTexts["Нет доступных режимов"].exists)
    }

    func testBundledRoutingIsAvailableForBothModes() {
        let app = launch()
        addSubscription(app, name: "bundle-custom-ip")
        tabButton(app, "Роутинг").tap()
        XCTAssertTrue(app.staticTexts["Подписка"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["prototype.routing.enabled"].isSelected)
        app.buttons["prototype.routing.russiaInside"].tap()
        XCTAssertTrue(app.buttons["prototype.routing.russiaInside"].isSelected)
    }

    func testRoutingChoicePersistsWithoutStartingVPN() {
        let app = launch()
        addSubscription(app)
        tabButton(app, "Роутинг").tap()
        XCTAssertTrue(app.staticTexts["Встроенные правила"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Вместе с подпиской"].exists)
        let picker = app.otherElements["prototype.routing.mode"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        app.buttons["prototype.routing.russiaInside"].tap()
        XCTAssertTrue(app.buttons["prototype.routing.russiaInside"].isSelected)
        app.terminate()
        let restored = launch(reset: false)
        XCTAssertTrue(tabButton(restored, "Роутинг").waitForExistence(timeout: 15))
        tabButton(restored, "Роутинг").tap()
        XCTAssertTrue(restored.buttons["prototype.routing.russiaInside"].isSelected)
    }

    func testLiveRefreshFailureAndForegroundActivationRetainCache() async throws {
        let app = launch()
        addSubscription(app)
        tabButton(app, "Профиль").tap()
        try await control("changed")
        app.buttons["prototype.subscription.refresh"].tap()
        XCTAssertTrue(app.staticTexts["Обновлённый обзор"].waitForExistence(timeout: 10))
        try await control("invalid")
        app.buttons["prototype.subscription.refresh"].tap()
        XCTAssertTrue(app.staticTexts["Сервер вернул некорректное оформление подписки."].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Обновлённый обзор"].exists)
        try await control("normal")
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(app.staticTexts["Обновлённый обзор"].waitForExistence(timeout: 10))
        app.buttons["prototype.subscription.refresh"].tap()
        XCTAssertTrue(app.staticTexts["Обзор"].waitForExistence(timeout: 10))
    }

    func testErrorBannerPreservesLayoutAndSupportsDismissalAndTimeout() async throws {
        let app = launch()
        addSubscription(app)
        XCTAssertFalse(app.staticTexts["Осталось 2000000000 байт"].exists)
        let card = app.descendants(matching: .any)["prototype.vpn.card"]
        let cardFrame = card.frame
        let refreshFrame = app.buttons["prototype.subscription.refresh"].frame
        try await control("invalid")
        let message = app.staticTexts["prototype.notice.message"]
        let close = app.buttons["prototype.notice.close"]

        for dismissal in 0 ..< 3 {
            app.buttons["prototype.subscription.refresh"].tap()
            XCTAssertTrue(message.waitForExistence(timeout: 10))
            XCTAssertEqual(message.label, "Сервер вернул некорректное оформление подписки.")
            XCTAssertLessThan(message.frame.minY, refreshFrame.minY)
            XCTAssertEqual(card.frame.minY, cardFrame.minY, accuracy: 1)
            XCTAssertEqual(card.frame.height, cardFrame.height, accuracy: 1)
            XCTAssertEqual(app.buttons["prototype.subscription.refresh"].frame.minY, refreshFrame.minY, accuracy: 1)
            XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "label == %@", message.label)).count, 1)
            capture(app, "error-banner-\(dismissal)")
            if dismissal == 0 {
                close.tap()
            } else if dismissal == 1 {
                message.swipeUp()
            }
            XCTAssertTrue(message.waitForNonExistence(timeout: dismissal == 2 ? 12 : 3))
        }
    }

    func testConnectedRestrictionKeepsDisconnectAndPreventsNextStart() async throws {
        let initial = launch()
        addSubscription(initial)
        initial.terminate()
        let app = launch(reset: false, vpnState: .connected)
        XCTAssertTrue(app.buttons["prototype.stop"].waitForExistence(timeout: 15))
        capture(app, "01 - connected compact")
        app.buttons["prototype.vpn.details"].tap()
        capture(app, "02 - connected expanded")
        tabButton(app, "Профиль").tap()
        try await control("ban-current")
        app.buttons["prototype.subscription.refresh"].tap()
        tabButton(app, "Подключение").tap()
        XCTAssertTrue(app.buttons["prototype.stop"].isEnabled)
        XCTAssertTrue(app.staticTexts["Выбранный режим недоступен. Для следующего подключения выберите другой режим."].waitForExistence(timeout: 10))
        app.terminate()
        let stopped = launch(reset: false)
        XCTAssertTrue(stopped.buttons["prototype.start"].waitForExistence(timeout: 15))
        XCTAssertFalse(stopped.buttons["prototype.start"].isEnabled)
    }

    func testAdaptiveLongContentStaysPortraitWhenDeviceRotates() {
        let app = launch()
        defer { XCUIDevice.shared.orientation = .portrait }
        addSubscription(app, name: "long")
        let mode = app.buttons["prototype.mode"]
        XCTAssertTrue(mode.waitForExistence(timeout: 5))
        XCTAssertFalse(mode.frame.intersects(tabButton(app, "Профиль").frame))
        XCTAssertLessThanOrEqual(mode.frame.maxY, app.staticTexts["Подписка"].frame.minY)
        capture(app, "adaptive - connection")
        mode.tap()
        XCTAssertTrue(app.buttons["prototype.mode.close"].waitForExistence(timeout: 5))
        capture(app, "adaptive - long mode text")
        XCUIDevice.shared.orientation = .landscapeLeft
        assertPortraitOnPhone(app)
        app.descendants(matching: .any)["prototype.mode.drawer"].scrollViews.firstMatch.swipeDown()
        XCTAssertTrue(app.buttons["prototype.mode.close"].isHittable)
        capture(app, "adaptive - portrait after rotation drawer")
        app.buttons["prototype.mode.close"].tap()
        XCTAssertTrue(app.buttons["prototype.mode"].waitForExistence(timeout: 5))
        let profile = tabButton(app, "Профиль")
        profile.tap()
        let selected = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in profile.isSelected }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [selected], timeout: 5), .completed)
        let logs = app.buttons["prototype.logs"]
        for _ in 0 ..< 8 {
            if logs.isHittable {
                break
            }
            app.scrollViews.firstMatch.swipeUp()
        }
        XCTAssertTrue(logs.isHittable)
        capture(app, "adaptive - portrait after rotation profile")
    }

    func testExpandedCardStaysBelowModeHeaderWhenDeviceRotates() {
        let app = launch()
        defer { XCUIDevice.shared.orientation = .portrait }
        addSubscription(app)
        XCUIDevice.shared.orientation = .landscapeLeft
        assertPortraitOnPhone(app)
        app.buttons["prototype.vpn.details"].tap()
        sleep(1)
        let card = app.descendants(matching: .any)["prototype.vpn.card"]
        capture(app, "adaptive - portrait after rotation expanded VPN")
        let mode = app.buttons["prototype.mode"]
        if UIDevice.current.userInterfaceIdiom == .phone {
            XCTAssertGreaterThanOrEqual(card.frame.minY, mode.frame.maxY)
        } else {
            XCTAssertFalse(card.frame.intersects(mode.frame))
        }
        XCTAssertTrue(app.buttons["prototype.vpn.details"].isHittable)
    }

    func testLongAccountDialogKeepsPortraitAndWholeCancelPillResponds() {
        let app = launch()
        defer { XCUIDevice.shared.orientation = .portrait }
        addSubscription(app, name: "long-dialog")
        tabButton(app, "Профиль").tap()
        app.buttons["prototype.ui.item02"].tap()
        XCTAssertTrue(app.buttons["Отмена"].waitForExistence(timeout: 5))
        XCUIDevice.shared.orientation = .landscapeLeft
        assertPortraitOnPhone(app)
        let cancel = app.buttons["Отмена"]
        capture(app, "adaptive - portrait after rotation account dialog")
        if UIDevice.current.userInterfaceIdiom == .phone {
            XCTAssertEqual(cancel.frame.width, min(540, app.windows.firstMatch.frame.width - 32), accuracy: 2)
            XCTAssertGreaterThanOrEqual(app.scrollViews["prototype.account.content"].frame.minY, 16)
        } else {
            // Window scaling and rotation make absolute screen dimensions unsuitable here.
            XCTAssertTrue(app.scrollViews["prototype.account.content"].isHittable)
            XCTAssertTrue(cancel.isHittable)
        }
        cancel.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5)).tap()
        XCTAssertTrue(app.buttons["prototype.ui.item02"].waitForExistence(timeout: 5))
    }
}
