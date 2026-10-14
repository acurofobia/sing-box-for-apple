import ApplicationLibrary
import Foundation
import Library
import XCTest

final class ManagedSubscriptionTests: XCTestCase {
    private let payload = Data("""
    {"schema_version":1,"plan_name":"Test plan","remaining_days":0,
     "sing_box":{"outbounds":[{"type":"direct","tag":"direct"}]},"vk_turn_link":null}
    """.utf8)

    private var payloadText: String { String(data: payload, encoding: .utf8) ?? "" }

    func testDecodeAndCacheRoundTrip() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let snapshot = try ManagedSubscriptionSnapshot.decode(payload, sourceURL: "http://mac.local/subscription/test")
        XCTAssertEqual(snapshot.remainingDays, 0)
        XCTAssertNil(snapshot.vkTurnLink)
        XCTAssertTrue(snapshot.singBoxConfiguration.contains("direct"))
        try snapshot.save(in: directory)
        XCTAssertEqual(try ManagedSubscriptionSnapshot.load(in: directory), snapshot)
    }

    func testRejectMalformedRequiredData() {
        for invalid in ["{}", "{\"schema_version\":2}", payloadText.replacingOccurrences(of: "\"remaining_days\":0", with: "\"remaining_days\":-1")] {
            XCTAssertThrowsError(try ManagedSubscriptionSnapshot.decode(Data(invalid.utf8), sourceURL: "http://mac.local/subscription/test"))
        }
    }

    func testMalformedOptionalVKStillAcceptsSingBox() throws {
        for invalid in ["42", "{}", "[]"] {
            let data = Data(payloadText.replacingOccurrences(of: "\"vk_turn_link\":null", with: "\"vk_turn_link\":\(invalid)").utf8)
            let snapshot = try ManagedSubscriptionSnapshot.decode(data, sourceURL: "http://mac.local/subscription/test")
            XCTAssertNil(snapshot.vkTurnLink)
            XCTAssertNotNil(snapshot.warning)
            XCTAssertEqual(snapshot.remainingDays, 0)
        }
    }

    func testStartPinsGenerationAndReloadCannotChangeConfig() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = try ManagedSubscriptionSnapshot.decode(payload, sourceURL: "http://mac.local/subscription/test")
        try original.save(in: directory, fileName: ManagedSubscriptionSnapshot.startFileName)
        let update = try ManagedSubscriptionSnapshot.decode(Data(payloadText.replacingOccurrences(of: "Test plan", with: "New plan").utf8), sourceURL: original.sourceURL)
        try update.save(in: directory)
        let options: [String: NSObject] = ["subscriptionGeneration": NSString(string: original.generation.uuidString)]
        XCTAssertEqual(try ManagedSubscriptionSnapshot.forStart(options: options, in: directory), original)
        XCTAssertEqual(try ManagedSubscriptionSnapshot.forStart(options: nil, in: directory), update)
        let incoming: [String: NSObject] = ["configContent": NSString(string: "arbitrary user profile"), "priorityFailoverJSON": NSString(string: "old-policy")]
        let active: [String: NSObject] = ["configContent": NSString(string: original.singBoxConfiguration)]
        let reload = try ManagedSubscriptionSnapshot.preservingActiveConfiguration(incoming, active: active)
        XCTAssertEqual(reload["configContent"] as? String, original.singBoxConfiguration)
        XCTAssertNil(reload["priorityFailoverJSON"])
    }

    func testLoadingInvalidVKAndRemovingFallback() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = makeService(directory: directory)
        SubscriptionURLProtocol.setResponse(data: Data(payloadText
            .replacingOccurrences(of: "\"vk_turn_link\":null", with: "\"vk_turn_link\":\"wdtt://example.com:443:a:b:password:call\"").utf8))
        let initial = try await service.refresh(sourceURL: "http://mac.local/subscription/test")
        XCTAssertNotNil(initial.vkTurnLink)
        SubscriptionURLProtocol.setResponse(data: Data(payloadText
            .replacingOccurrences(of: "\"vk_turn_link\":null", with: "\"vk_turn_link\":\"invalid\"").utf8))
        let invalidVK = try await service.refresh()
        XCTAssertNil(invalidVK.vkTurnLink)
        XCTAssertNotNil(invalidVK.warning)
        SubscriptionURLProtocol.setResponse(data: payload)
        let removed = try await service.refresh()
        XCTAssertNil(removed.vkTurnLink)
        XCTAssertNil(removed.warning)
        XCTAssertEqual(try ManagedSubscriptionSnapshot.load(in: directory), removed)
    }

    func testFailurePreservesEntirePreviousSnapshot() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = makeService(directory: directory)
        SubscriptionURLProtocol.setResponse(data: payload)
        let initial = try await service.refresh(sourceURL: "http://mac.local/subscription/test")
        for status in [200, 503] {
            SubscriptionURLProtocol.setResponse(data: Data("{}".utf8), status: status)
            do { _ = try await service.refresh(); XCTFail("Invalid update accepted") } catch {}
            XCTAssertEqual(try ManagedSubscriptionSnapshot.load(in: directory), initial)
        }
        SubscriptionURLProtocol.setResponse(data: Data("{\"schema_version\":1,\"plan_name\":\"Broken\",\"remaining_days\":2,\"sing_box\":{\"outbounds\":[{\"type\":\"invalid\"}]}}".utf8))
        do { _ = try await service.refresh(); XCTFail("Invalid sing-box config accepted") } catch {}
        XCTAssertEqual(try ManagedSubscriptionSnapshot.load(in: directory), initial)
    }

    func testConcurrentRefreshesUseOneRequest() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SubscriptionURLProtocol.self]
        let service = ManagedSubscriptionService(directory: directory, sessionConfiguration: configuration, isConnectionActive: {
            try await Task.sleep(nanoseconds: 50_000_000)
            return false
        })
        SubscriptionURLProtocol.setResponse(data: payload)
        async let first = service.refresh(sourceURL: "http://mac.local/subscription/test")
        async let second = service.refresh(sourceURL: "http://mac.local/subscription/test")
        let (a, b) = try await (first, second)
        XCTAssertEqual(a, b)
        XCTAssertEqual(SubscriptionURLProtocol.requestCount, 1)
    }

    func testSourceCannotBeReplacedDuringConnection() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let initial = try ManagedSubscriptionSnapshot.decode(payload, sourceURL: "http://mac.local/subscription/test")
        try initial.save(in: directory)
        let service = makeService(directory: directory, connected: true)
        SubscriptionURLProtocol.setResponse(data: payload)
        do {
            _ = try await service.refresh(sourceURL: "http://other.local/subscription/test")
            XCTFail("Subscription changed during VPN session")
        } catch {
            XCTAssertEqual(error as? ManagedSubscriptionError, .stopBeforeReplacing)
        }
        XCTAssertEqual(try ManagedSubscriptionSnapshot.load(in: directory), initial)
        _ = try await service.refresh()
        XCTAssertEqual(SubscriptionURLProtocol.requestCount, 1)
    }

    func testCaptivePortalDoesNotCountAsInternet() throws {
        let gstatic = try XCTUnwrap(URL(string: "https://www.gstatic.com/generate_204"))
        let portal = try XCTUnwrap(HTTPURLResponse(url: gstatic, statusCode: 200, httpVersion: nil, headerFields: nil))
        XCTAssertFalse(InternetAvailability.isExpectedResponse(url: gstatic, response: portal, data: Data("<html>Login</html>".utf8)))
        let success = try XCTUnwrap(HTTPURLResponse(url: gstatic, statusCode: 204, httpVersion: nil, headerFields: nil))
        XCTAssertTrue(InternetAvailability.isExpectedResponse(url: gstatic, response: success, data: Data()))
        let cloudflare = try XCTUnwrap(URL(string: "https://www.cloudflare.com/cdn-cgi/trace"))
        let trace = try XCTUnwrap(HTTPURLResponse(url: cloudflare, statusCode: 200, httpVersion: nil, headerFields: nil))
        XCTAssertTrue(InternetAvailability.isExpectedResponse(url: cloudflare, response: trace, data: Data("ip=1.1.1.1\nwarp=off\n".utf8)))
        XCTAssertFalse(InternetAvailability.isExpectedResponse(url: cloudflare, response: trace, data: Data("ip=invalid\n".utf8)))
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func makeService(directory: URL, connected: Bool = false) -> ManagedSubscriptionService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SubscriptionURLProtocol.self]
        return ManagedSubscriptionService(directory: directory, sessionConfiguration: configuration, isConnectionActive: { connected })
    }
}

private final class SubscriptionURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var responseData = Data()
    private static var responseStatus = 200
    private static var count = 0
    static var requestCount: Int { lock.withLock { count } }

    static func setResponse(data: Data, status: Int = 200) {
        lock.withLock { responseData = data; responseStatus = status; count = 0 }
    }

    override static func canInit(with _: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let (data, status) = Self.lock.withLock {
            Self.count += 1
            return (Self.responseData, Self.responseStatus)
        }
        guard let url = request.url, let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@MainActor
final class ManagedSubscriptionUITests: XCTestCase {
    func testFirstLaunchRequiresSubscription() {
        let app = launch(extra: ["-SUBSCRIPTION_EMPTY"])
        let connect = app.buttons["subscription.connect"]
        XCTAssertTrue(connect.waitForExistence(timeout: 15))
        XCTAssertFalse(connect.isEnabled)
        app.buttons["subscription.settings"].tap()
        XCTAssertTrue(app.secureTextFields["subscription.url"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["subscription.save"].isEnabled)
    }

    func testCachedSubscriptionRemainsUsableWhenOffline() {
        let app = launch(extra: ["-SUBSCRIPTION_OFFLINE"])
        XCTAssertTrue(app.staticTexts["Saved plan"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["subscription.connect"].isEnabled)
        app.buttons["subscription.refresh"].tap()
        XCTAssertTrue(app.staticTexts["subscription.error"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Saved plan"].exists)
        XCTAssertTrue(app.buttons["subscription.connect"].isEnabled)
    }

    func testRefreshUpdatesMetadataAndZeroDaysDoNotBlock() {
        let app = launch()
        XCTAssertTrue(app.staticTexts["Saved plan"].waitForExistence(timeout: 15))
        app.buttons["subscription.refresh"].tap()
        XCTAssertTrue(app.staticTexts["Updated plan"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["subscription.connect"].isEnabled)
        XCTAssertTrue(app.staticTexts["Осталось дней: 0"].exists)
        XCTAssertFalse(app.switches["Только VK TURN"].exists)
        XCTAssertFalse(app.buttons["Import Profile"].exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Subscription dashboard"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    private func launch(extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-SUBSCRIPTION_UI_TEST", "-AppleLanguages", "(ru)"] + extra
        app.launch()
        return app
    }
}
