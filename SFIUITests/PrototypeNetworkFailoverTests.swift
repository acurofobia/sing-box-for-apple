import XCTest

@MainActor
final class PrototypeNetworkFailoverTests: XCTestCase {
    private struct Candidate: Codable {
        let tag: String
        let server: String
        let port: Int
    }

    private struct Failover: Decodable, Equatable {
        let selected: String?
        let selectedHealth: String?
        let checking: String?
        let allDown: Bool
        let selectedIndex: Int?
    }

    private struct Snapshot: Decodable {
        let phase: String
        let updatedAt: Date
        let failover: Failover?
        let candidates: [Candidate]
        let captureName: String?
    }

    private struct StageRequest: Encodable {
        let run: String
        let sequence: Int
        let stage: String
        let candidates: [Candidate]
        let blockedTags: [String]
    }

    private struct StageReply: Decodable {
        let run: String
        let sequence: Int
        let error: String?
    }

    private let app = XCUIApplication()
    private let run = UUID().uuidString
    private var sequence = 0
    private var evidence: URL!
    private var candidates: [Candidate] = []
    private var observations: [[String: String]] = []
    private var lastState: Failover?

    func testNetworkFailuresAndRecoveryOnOpenWrt() async throws {
        #if targetEnvironment(simulator)
            throw XCTSkip("Requires an iPhone on the controlled OpenWrt Wi-Fi.")
        #else
            try XCTSkipUnless(ProcessInfo.processInfo.environment["PROTOTYPE_OPENWRT_CHECK"] == "1",
                              "Run only with the host firewall supervisor and cellular data disabled.")
            continueAfterFailure = false
            evidence = try XCTUnwrap(FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first)
                .appendingPathComponent("FailoverAcceptance", isDirectory: true)
            try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
            app.launchEnvironment["PROTOTYPE_OPENWRT_CHECK"] = "1"
            app.launch()
            XCTAssertTrue(app.tabBars.buttons["Подключение"].waitForExistence(timeout: 15))
            app.tabBars.buttons["Подключение"].tap()
            let wasRunning = app.buttons["prototype.stop"].exists
            defer {
                try? stage("cleanup", blocking: [])
                if !wasRunning { stopVPN() }
                try? saveObservations()
            }
            if !wasRunning { startVPN() }
            try loadCandidates()
            try stage("baseline", blocking: [])
            try await expectSelection(0)
            try await verifyTraffic("baseline")
            let initialCapture = try captureName()

            // Logical candidates may share a physical endpoint. Block each
            // reachable endpoint group without claiming independent node faults.
            var blocked = [candidates[0].tag]
            var nextIndex = 1
            while nextIndex < candidates.count {
                let endpoint = candidates[nextIndex]
                if candidates.filter({ blocked.contains($0.tag) }).contains(where: { $0.server == endpoint.server && $0.port == endpoint.port }) {
                    nextIndex += 1
                    continue
                }
                try stage("failover-\(nextIndex + 1)", blocking: blocked)
                try await expectSelection(nextIndex)
                XCTAssertEqual(try captureName(), initialCapture, "Failover restarted the VPN extension")
                try await verifyTraffic("server-\(nextIndex + 1)")
                blocked.append(endpoint.tag)
                nextIndex += 1
            }

            try stage("all-down", blocking: candidates.map(\.tag))
            try await waitForState("all-down") { $0.allDown && $0.checking == nil }
            try await verifyTraffic("all-down", shouldSucceed: false)
            attachScreen("All four servers blocked")
            XCTAssertEqual(try captureName(), initialCapture)

            let backupIndex = try XCTUnwrap(candidates.indices.dropFirst().first { index in
                candidates[index].server != candidates[0].server || candidates[index].port != candidates[0].port
            })
            try stage("recover-backup", blocking: [candidates[0].tag])
            try await expectSelection(backupIndex)
            try await verifyTraffic("recovered-backup")

            try stage("recover-primary", blocking: [])
            let restored = Date()
            try await expectSelection(0)
            XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(restored), 17, "Primary recovery bypassed its three-check threshold")
            try await verifyTraffic("recovered-primary")
            XCTAssertEqual(try captureName(), initialCapture)

            try stage("cold-start-primary-down", blocking: [candidates[0].tag])
            stopVPN()
            startVPN()
            try await expectSelection(backupIndex)
            try await verifyTraffic("cold-start-backup")
            try stage("restore-all", blocking: [])
            try await expectSelection(0)
            try await verifyTraffic("final-primary")
            try saveObservations()
        #endif
    }

    private func loadCandidates() throws {
        let deadline = Date().addingTimeInterval(45)
        while Date() < deadline {
            if let data = try? Data(contentsOf: evidence.appendingPathComponent("telemetry.json")),
               let value = try? JSONDecoder().decode(Snapshot.self, from: data),
               (0 ... 5).contains(Date().timeIntervalSince(value.updatedAt))
            {
                candidates = value.candidates
                XCTAssertEqual(candidates.count, 4)
                return
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
        throw NSError(domain: "FailoverAcceptance", code: 3, userInfo: [NSLocalizedDescriptionKey: "No current telemetry from app"])
    }

    private func stage(_ name: String, blocking tags: [String]) throws {
        sequence += 1
        let request = StageRequest(run: run, sequence: sequence, stage: name, candidates: candidates, blockedTags: tags)
        try JSONEncoder().encode(request).write(to: evidence.appendingPathComponent("request.json"), options: .atomic)
        let deadline = Date().addingTimeInterval(45)
        while Date() < deadline {
            if let data = try? Data(contentsOf: evidence.appendingPathComponent("reply.json")),
               let reply = try? JSONDecoder().decode(StageReply.self, from: data), reply.run == run, reply.sequence == sequence
            {
                if let error = reply.error { throw NSError(domain: "FirewallSupervisor", code: 1, userInfo: [NSLocalizedDescriptionKey: error]) }
                observe("stage", detail: name)
                return
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
        throw NSError(domain: "FirewallSupervisor", code: 2, userInfo: [NSLocalizedDescriptionKey: "No host reply for \(name)"])
    }

    private func snapshot() throws -> Snapshot? {
        let value = try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: evidence.appendingPathComponent("telemetry.json")))
        guard (0 ... 5).contains(Date().timeIntervalSince(value.updatedAt)), value.phase == "vless" else { return nil }
        if let state = value.failover, state != lastState {
            observe("state", detail: "selected=\(state.selected ?? "-") health=\(state.selectedHealth ?? "-") checking=\(state.checking ?? "-") allDown=\(state.allDown)")
            lastState = state
        }
        return value
    }

    private func waitForState(_ name: String, matches: (Failover) -> Bool) async throws {
        let deadline = Date().addingTimeInterval(115)
        while Date() < deadline {
            if let state = try snapshot()?.failover, matches(state) { return }
            try await Task.sleep(for: .seconds(1))
        }
        XCTFail("Timed out waiting for \(name)")
        throw NSError(domain: "FailoverAcceptance", code: 1)
    }

    private func expectSelection(_ index: Int) async throws {
        let tag = candidates[index].tag
        try await waitForState(tag) { $0.selected == tag && $0.selectedHealth == "up" && !$0.allDown && $0.selectedIndex == index + 1 }
        let details = app.buttons["prototype.vpn.details"]
        if details.value as? String != "Развёрнуто" { details.tap() }
        let label = "Подключён: \(tag) (\(index + 1) из 4)"
        XCTAssertTrue(app.staticTexts[label].waitForExistence(timeout: 10), "Drawer disagrees with the core: \(label)")
        attachScreen(label)
        observe("selected", detail: label)
    }

    private func verifyTraffic(_ name: String, shouldSucceed: Bool = true) async throws {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: try XCTUnwrap(URL(string: "https://github.com/robots.txt?failover=" + UUID().uuidString)))
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.timeoutInterval = shouldSucceed ? 25 : 12
        do {
            let (data, response) = try await session.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            observe("traffic", detail: "\(name) HTTP=\(code) bytes=\(data.count)")
            XCTAssertTrue(shouldSucceed, "Proxied traffic succeeded with all four endpoints blocked")
            XCTAssertEqual(code, 200)
            XCTAssertGreaterThan(data.count, 0)
        } catch {
            observe("traffic", detail: "\(name) failed=\(String(describing: error))")
            if shouldSucceed { throw error }
        }
        try saveObservations()
    }

    private func captureName() throws -> String? {
        try snapshot()?.captureName
    }

    private func observe(_ kind: String, detail: String) {
        observations.append(["time": ISO8601DateFormatter().string(from: Date()), "kind": kind, "detail": detail])
    }

    private func saveObservations() throws {
        let data = try JSONSerialization.data(withJSONObject: observations, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: evidence.appendingPathComponent("observations.json"), options: .atomic)
    }

    private func attachScreen(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func stopVPN() {
        let button = app.buttons["prototype.stop"]
        if button.exists { button.tap() }
        XCTAssertTrue(app.buttons["prototype.start"].waitForExistence(timeout: 30))
    }

    private func startVPN() {
        app.buttons["prototype.start"].tap()
        let alert = app.alerts["Перед подключением"]
        if alert.waitForExistence(timeout: 1) { alert.buttons["Подключить"].tap() }
        let connected = app.descendants(matching: .any).matching(identifier: "prototype.status").firstMatch
        let expected = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in connected.value as? String == "Подключено" }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [expected], timeout: 120), .completed)
    }
}
