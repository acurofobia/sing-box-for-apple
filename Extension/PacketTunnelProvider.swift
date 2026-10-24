import Darwin
import Foundation
import Libbox
import Library
import NetworkExtension

final class PacketTunnelProvider: ExtensionProvider {
    private var sessionID: Int64 = 0
    private var capture: PrototypeMemoryCapture?
    private let stateLock = NSLock()
    private var stopped = false
    private var startupFinished: AsyncStream<Void>?
    private var startingServer: LibboxCommandServer?

    override func prepareServiceStart(_ server: LibboxCommandServer) throws {
        try stateLock.withLock {
            guard !stopped else { throw CancellationError() }
            startingServer = server
        }
    }

    override func startTunnel(options: [String: NSObject]?) async throws {
        let completion = AsyncStream<Void>.makeStream()
        defer {
            completion.continuation.finish()
            stateLock.withLock { startupFinished = nil; startingServer = nil }
        }
        let generation = stateLock.withLock {
            startupFinished = completion.stream
            stopped = false
            return LibboxBeginVKTurnPrototype()
        }
        let settings = (protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration ?? [:]
        let baseline = settings["baseline"] as? Bool ?? false
        let mode = settings["mode"] as? String ?? "vk-turn"
        let vless = !baseline && mode == "vless"
        let connections = settings["connections"] as? Int ?? 30
        let directory = FilePath.sharedDirectory
        defer {
            // Every start regenerates config; also clear stale snapshots on failure.
            try? FileManager.default.removeItem(at: directory.appendingPathComponent("start_options.plist"))
        }
        let capture = try PrototypeMemoryCapture(directory: directory, baseline: baseline, connections: connections, vless: vless)
        self.capture = capture
        capture.start()
        do {
            let data = try Data(contentsOf: directory.appendingPathComponent("prototype-routing.json"))
            let route = try JSONSerialization.jsonObject(with: data)
            var input: [String: Any] = ["route": route, "baseline": baseline, "mode": mode, "generation": generation, "cache_path": directory.appendingPathComponent("Library/Caches/Prototype").path]
            var priorityFailoverJSON: String?
            if vless {
                let node = try Data(contentsOf: directory.appendingPathComponent("prototype-vless.json"))
                guard node.count <= 8 * 1024 * 1024,
                      let document = try JSONSerialization.jsonObject(with: node) as? [String: Any]
                else { throw VKTurnError.invalidField }
                if document["kind"] != nil || document["schemaVersion"] != nil {
                    guard let version = document["schemaVersion"] as? NSNumber,
                          CFGetTypeID(version) != CFBooleanGetTypeID(), version == 1,
                          document["kind"] as? String == "vless-failover", document["state"] as? String == "available",
                          document["reason"] == nil || document["reason"] is NSNull,
                          let nodes = document["outbounds"] as? [[String: Any]], nodes.count == 4,
                          let policy = document["failover"] as? [String: Any], let primary = policy["primary"] as? String
                    else { throw VKTurnError.invalidField }
                    input["vless_outbounds"] = nodes
                    input["vless_primary"] = primary
                    let policyData = try JSONSerialization.data(withJSONObject: policy)
                    guard let policyText = String(bytes: policyData, encoding: .utf8) else { throw VKTurnError.invalidField }
                    priorityFailoverJSON = policyText
                } else {
                    input["vless"] = document
                }
            } else if !baseline {
                let configuration = try VKTurnConfigurationStore.load()
                guard let proxyText = configuration.proxyConfig,
                      let proxyData = proxyText.data(using: .utf8),
                      var proxy = try JSONSerialization.jsonObject(with: proxyData) as? [String: Any]
                else {
                    throw VKTurnError.invalidField
                }
                proxy["num_conns"] = connections
                input["proxy"] = proxy
                if !configuration.isWrapA {
                    guard let privateKey = configuration.privateKey, let publicKey = configuration.peerPublicKey,
                          let address = configuration.tunnelAddress else { throw VKTurnError.invalidField }
                    input["wireguard"] = ["private_key": privateKey, "public_key": publicKey,
                                          "preshared_key": configuration.presharedKey ?? "", "address": address, "mtu": 1280]
                }
            }
            guard let json = try String(data: JSONSerialization.data(withJSONObject: input), encoding: .utf8) else {
                throw VKTurnError.invalidField
            }
            let session = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<LibboxVKTurnPrototypeSession, Error>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    var error: NSError?
                    let prepared = LibboxStartVKTurnPrototype(json, &error)
                    if let error {
                        continuation.resume(throwing: error)
                    } else if let prepared {
                        continuation.resume(returning: prepared)
                    } else {
                        continuation.resume(throwing: VKTurnError.invalidField)
                    }
                }
            }
            let accepted = stateLock.withLock {
                guard !stopped else { return false }
                sessionID = session.id_
                return true
            }
            guard accepted else {
                LibboxStopVKTurnPrototype(session.id_)
                throw CancellationError()
            }
            capture.setSession(session.id_)
            let cacheDirectory = FilePath.prototypeRuleSetDirectory
            try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
            var dnsConfiguration = Data(session.configuration.utf8)
            if !baseline {
                dnsConfiguration = try PrototypeRouting.configurationWithDNSPolicy(dnsConfiguration)
            }
            let configuration = try PrototypeRouting.configurationWithPersistentCache(dnsConfiguration, directory: cacheDirectory)
            guard let configText = String(bytes: configuration, encoding: .utf8) else { throw VKTurnError.invalidField }
            var effective = options ?? [:]
            // Derive policy exclusively from this runtime document, never start options.
            effective.removeValue(forKey: "priorityFailoverJSON")
            if let priorityFailoverJSON {
                var validationError: NSError?
                LibboxValidatePriorityFailover(configText, priorityFailoverJSON, &validationError)
                if let validationError {
                    throw validationError
                }
                effective["priorityFailoverJSON"] = NSString(string: priorityFailoverJSON)
            }
            effective["configContent"] = NSString(string: configText)
            effective["systemProxyEnabled"] = NSNumber(value: false)
            try await super.startTunnel(options: effective)
            if priorityFailoverJSON != nil {
                capture.setFailoverServer(commandServer)
            }
            if !baseline {
                capture.setHealthServer(commandServer)
            }
            LibboxSetVKTurnPrototypeLogServer(commandServer)
            commandServer?.writeMessage(4, message: "[VPN] Connected: " + (vless ? "VLESS" : "VK TURN"))
            #if DEBUG
            if !baseline {
                let profileDirectory = directory.appendingPathComponent("Library/Caches/Prototype/OOMVerification").path
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    DispatchQueue.global(qos: .utility).async {
                        var error: NSError?
                        LibboxVerifyVKTurnPrototypeOOMProfiles(profileDirectory, &error)
                        if let error {
                            continuation.resume(throwing: error)
                        } else {
                            continuation.resume()
                        }
                    }
                }
            }
            #endif
            guard !stateLock.withLock({ stopped }) else { throw CancellationError() }
            capture.setPhase(baseline ? "baseline" : vless ? "vless" : "combined")
        } catch {
            capture.setHealthServer(nil)
            capture.setFailoverServer(nil)
            if commandServer != nil {
                await super.stopTunnel(with: .providerFailed)
            }
            let id = stateLock.withLock { let id = sessionID; sessionID = 0; return id }
            LibboxStopVKTurnPrototype(id)
            LibboxSetVKTurnPrototypeLogServer(nil)
            capture.fail(error.localizedDescription)
            throw error
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason) async {
        let (id, startup, server) = stateLock.withLock {
            stopped = true
            let id = sessionID
            sessionID = 0
            return (id, startupFinished, startingServer)
        }
        // Cancel the core context before joining startup. This also latches a
        // stop that races between server publication and StartOrReloadService.
        server?.cancelServiceStart()
        // Cancel TURN before WireGuard joins its send/receive workers.
        LibboxCancelVKTurnPrototype()
        LibboxStopVKTurnPrototype(id)
        // Startup may be awaiting provisioning or setTunnelNetworkSettings.
        // Let it finish before tearing down the superclass's command server.
        if let startup {
            for await _ in startup {}
        }
        stateLock.withLock { startingServer = nil }
        LibboxSetVKTurnPrototypeLogServer(nil)
        capture?.setHealthServer(nil)
        capture?.setFailoverServer(nil)
        await super.stopTunnel(with: reason)
        capture?.stop()
        capture = nil
    }
}

private final class PrototypeMemoryCapture {
    private let directory: URL
    private let file: FileHandle
    private let baseline: Bool
    private let connections: Int
    private let queue = DispatchQueue(label: "prototype.memory")
    private var timer: DispatchSourceTimer?
    private let started = ProcessInfo.processInfo.systemUptime
    private var phase: String
    private var lastError: String?
    private var sessionID: Int64 = 0
    private var finished = false
    private var nextMinuteSample = 780.0
    private var failoverServer: LibboxCommandServer?
    private let healthQueue = DispatchQueue(label: "PrototypeHealth", qos: .utility)
    private var healthServer: LibboxCommandServer?
    private var health: Bool?
    private var healthUpdatedAt: Date?
    private var healthChecking = false
    private var healthGeneration: UInt64 = 0
    private var nextHealthProbe = 0.0

    func setHealthServer(_ server: LibboxCommandServer?) {
        queue.sync {
            healthGeneration &+= 1
            healthServer = server
            health = nil
            healthUpdatedAt = nil
            healthChecking = false
            nextHealthProbe = 0
        }
    }

    func setFailoverServer(_ server: LibboxCommandServer?) {
        queue.sync { failoverServer = server }
    }

    init(directory: URL, baseline: Bool, connections: Int, vless: Bool = false) throws {
        self.directory = directory
        self.baseline = baseline
        self.connections = baseline || vless ? 0 : connections
        let mode = baseline ? "baseline" : vless ? "vless" : "combined"
        phase = mode + "-startup"
        let cache = directory.appendingPathComponent("Library/Caches/Prototype")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let name = "\(Int(Date().timeIntervalSince1970))-\(mode)-\(self.connections).csv"
        let url = cache.appendingPathComponent(name)
        try Data("elapsed_seconds,phase,metric,unit,footprint_bytes,requested_turn_connections,active_turn_connections,turn_tx_bytes,turn_rx_bytes\n".utf8)
            .write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        file = try FileHandle(forWritingTo: url)
        try file.seekToEnd()
    }

    func start() {
        queue.async { [self] in
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: .seconds(1))
            timer.setEventHandler { [weak self] in self?.sample() }
            self.timer = timer
            timer.resume()
        }
    }

    func setSession(_ id: Int64) {
        queue.async { [self] in sessionID = id }
    }

    func setPhase(_ value: String) {
        queue.async { [self] in phase = value }
    }

    func fail(_ message: String) {
        queue.async { [self] in lastError = message; phase = "failed"; sample(forceCSV: true); finish() }
    }

    func stop() {
        queue.sync { phase = "stopped"; sample(forceCSV: true); finish() }
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        failoverServer = nil
        healthServer = nil
        healthGeneration &+= 1
        timer?.cancel(); timer = nil
        try? file.synchronize()
        try? file.close()
    }

    private func sample(forceCSV: Bool = false) {
        guard !finished else { return }
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        if ["vless", "combined"].contains(phase), !healthChecking,
           elapsed >= nextHealthProbe, let server = healthServer
        {
            healthChecking = true
            let generation = healthGeneration
            healthQueue.async { [self] in
                var healthy = ObjCBool(false)
                do {
                    try server.probeOutbound("vk-wg", timeoutMilliseconds: 5000, ret0_: &healthy)
                } catch {
                    healthy = false
                }
                let result = healthy.boolValue
                queue.async { [self] in
                    guard !finished, generation == healthGeneration else { return }
                    healthChecking = false
                    health = result
                    healthUpdatedAt = Date()
                    nextHealthProbe = ProcessInfo.processInfo.systemUptime - started + 10
                    sample()
                }
            }
        }
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return }
        do {
            let stats = LibboxGetVKTurnPrototypeStats(sessionID)
            let active = stats?.activeConnections ?? 0
            let tx = stats?.txBytes ?? 0
            let rx = stats?.rxBytes ?? 0
            if forceCSV || elapsed <= 720 || elapsed >= nextMinuteSample {
                let line = "\(elapsed),\(phase),phys_footprint,bytes,\(info.phys_footprint),\(connections),\(active),\(tx),\(rx)\n"
                try file.write(contentsOf: Data(line.utf8))
                if elapsed > 720 {
                    nextMinuteSample = (floor(elapsed / 60) + 1) * 60
                }
            }
            struct Failover: Codable { let mode: String; let selected: String?; let primaryHealth: String?; let allDown: Bool }
            struct Status: Encodable {
                let footprintBytes: UInt64
                let phase: String
                let error: String?
                let updatedAt: Date
                let failover: Failover?
                let health: Bool?
                let healthUpdatedAt: Date?
            }
            var failover: Failover?
            var statusError: NSError?
            if let text = failoverServer?.priorityFailoverStatus(&statusError), statusError == nil {
                failover = try? JSONDecoder().decode(Failover.self, from: Data(text.utf8))
            }
            let data = try JSONEncoder().encode(Status(footprintBytes: info.phys_footprint, phase: phase, error: lastError, updatedAt: Date(), failover: failover, health: health, healthUpdatedAt: healthUpdatedAt))
            try data.write(to: directory.appendingPathComponent("prototype-status.json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch { timer?.cancel(); timer = nil }
    }
}
