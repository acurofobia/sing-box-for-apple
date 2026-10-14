import Libbox
import Library
import NetworkExtension
import XCTest

final class PriorityFailoverTests: XCTestCase {
    private let config = """
    {
      // Libbox accepts comments.
      "outbounds": [
        {"type":"socks","tag":"p","server":"127.0.0.1","server_port":9},
        {"type":"socks","tag":"b1","server":"127.0.0.1","server_port":9},
        {"type":"socks","tag":"b2","server":"127.0.0.1","server_port":9},
        {"type":"socks","tag":"b3","server":"127.0.0.1","server_port":9},
        {"type":"selector","tag":"proxy","outbounds":["p","b1","b2","b3"],"default":"p"}
      ]
    }
    """

    func testPolicyValidationAndComments() throws {
        let policy = PriorityFailoverConfiguration(selector: "proxy", primary: "p", backups: ["b1", "b2", "b3"])
        try policy.validate(configContent: config)
        let metadata = try PriorityFailoverMetadata.read(configContent: config)
        XCTAssertEqual(metadata.selectors.first?.candidates, ["p", "b1", "b2", "b3"])
        XCTAssertThrowsError(try policy.validate(configContent: config.replacingOccurrences(of: "\"tag\":\"b3\"", with: "\"tag\":\"removed\"")))
    }

    func testPolicyJSONDefaults() throws {
        let policy = PriorityFailoverConfiguration(selector: "proxy", primary: "p", backups: ["b1", "b2", "b3"])
        let decoded = try JSONDecoder().decode(PriorityFailoverConfiguration.self, from: Data(policy.json().utf8))
        XCTAssertEqual(decoded, policy)
        XCTAssertEqual(decoded.intervalMilliseconds, 10000)
        XCTAssertEqual(decoded.timeoutMilliseconds, 5000)
        XCTAssertEqual(decoded.failureThreshold, 2)
        XCTAssertEqual(decoded.recoveryThreshold, 3)
    }

    func testOrdinaryConfigHasNoSelectors() throws {
        let metadata = try PriorityFailoverMetadata.read(configContent: "{\"outbounds\":[{\"type\":\"direct\",\"tag\":\"direct\"}]}")
        XCTAssertTrue(metadata.selectors.isEmpty)
    }

    func testProviderPreflightBridgeRejectsAllDown() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let setup = LibboxSetupOptions()
        setup.basePath = directory.path
        setup.workingPath = directory.path
        setup.tempPath = directory.path
        var setupError: NSError?
        LibboxSetup(setup, &setupError)
        if let setupError { throw setupError }
        let policy = PriorityFailoverConfiguration(selector: "proxy", primary: "p", backups: ["b1", "b2", "b3"])
        var error: NSError?
        var success = ObjCBool(true)
        LibboxProbePriorityFailover(config, try policy.json(), 5000, &success, &error)
        XCTAssertNil(error)
        XCTAssertFalse(success.boolValue)
    }

    @MainActor
    func testRemoteGroupsNeverControlLocalFailover() {
        let original = CommandTarget.remoteServer
        defer { CommandTarget.setRemoteServer(original) }
        let profile = ExtensionProfile.mock
        CommandTarget.setRemoteServer(nil)
        XCTAssertTrue(profile.canControlPriorityFailoverGroups)
        CommandTarget.setRemoteServer(RemoteServer(id: -1, url: "127.0.0.1:9"))
        XCTAssertFalse(profile.canControlPriorityFailoverGroups)
        profile.status = .disconnected
        XCTAssertFalse(profile.canControlPriorityFailoverGroups)
        profile.status = .connected
    }

    @MainActor
    func testNativeSettingsSaveAndReload() {
        let app = XCUIApplication()
        app.launchArguments = ["-PRIORITY_FAILOVER_UI_TEST", "-AppleLanguages", "(en)"]
        app.launch()
        let toggle = app.switches["priorityFailover.enabled"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 15))
        let primary = app.descendants(matching: .any)["priorityFailover.primary"]
        if !primary.exists {
            toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        }
        XCTAssertTrue(primary.waitForExistence(timeout: 5))
        let enabledScreenshot = XCTAttachment(screenshot: app.screenshot())
        enabledScreenshot.name = "Enabled priority settings"
        enabledScreenshot.lifetime = .keepAlways
        add(enabledScreenshot)
        let save = app.buttons["priorityFailover.save"]
        for _ in 0 ..< 6 where !save.isHittable { app.swipeUp() }
        XCTAssertTrue(save.isHittable)
        save.tap()
        let saved = app.staticTexts["Failover Settings Saved"]
        for _ in 0 ..< 4 where !saved.exists { app.swipeUp() }
        XCTAssertTrue(saved.waitForExistence(timeout: 10))
        app.terminate()
        app.launch()
        XCTAssertTrue(toggle.waitForExistence(timeout: 15))
        XCTAssertTrue(primary.waitForExistence(timeout: 5))
        let reloadedScreenshot = XCTAttachment(screenshot: app.screenshot())
        reloadedScreenshot.name = "Reloaded priority settings"
        reloadedScreenshot.lifetime = .keepAlways
        add(reloadedScreenshot)
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        save.tap()
        XCTAssertTrue(saved.waitForExistence(timeout: 10))
        app.terminate()
    }

}
