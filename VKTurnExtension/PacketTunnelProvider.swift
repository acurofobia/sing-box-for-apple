import Foundation
import NetworkExtension
import os

final class PacketTunnelProvider: NEPacketTunnelProvider {
    private let logger = Logger(subsystem: "VKTurnExtension", category: "PacketTunnel")
    private let lock = NSLock()
    private var handle: Int32?
    private var stopped = false

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        VKTurnConfigurationStore.setLastError(nil)
        if let logURL = VKTurnConfigurationStore.logURL {
            try? Data().write(to: logURL, options: .atomic)
            wgSetTimezoneOffset(Int32(TimeZone.current.secondsFromGMT()))
            logURL.path.withCString { wgSetLogFilePath($0) }
        }
        let configuration: VKTurnConfiguration
        do {
            let snapshot = try ManagedSubscriptionSnapshot.forStart(options: options)
            guard let link = snapshot.vkTurnLink else { throw VKTurnError.missingConfiguration }
            configuration = try VKTurnConfiguration.importLink(link)
            try VKTurnConfigurationStore.save(configuration)
        } catch {
            VKTurnConfigurationStore.setLastError(error.localizedDescription)
            completionHandler(Self.error(error.localizedDescription))
            return
        }
        guard let proxyConfig = configuration.proxyConfig,
              (configuration.isWrapA || configuration.wireGuardConfig != nil) else {
            VKTurnConfigurationStore.setLastError(VKTurnError.invalidField.localizedDescription)
            completionHandler(VKTurnError.invalidField)
            return
        }

        lock.lock()
        stopped = false
        lock.unlock()
        wgSetVKCookieAuth(0, "", "[]")
        let started = proxyConfig.withCString { wgStartVKBootstrap($0) }
        guard started > 0 else {
            let message = "VK TURN не смог начать подключение (код \(started))."
            VKTurnConfigurationStore.setLastError(message)
            completionHandler(Self.error(message))
            return
        }
        lock.lock()
        handle = started
        lock.unlock()

        let deadline = Date().addingTimeInterval(120)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let ready = wgWaitBootstrapReady(started, configuration.isWrapA ? 90_000 : 120_000)
            guard self.isCurrent(started) else {
                completionHandler(Self.error("Подключение VK TURN отменено."))
                return
            }
            guard ready == 1 else {
                self.fail(started, message: ready == 0
                    ? "VK TURN не подключился за 120 секунд. Проверьте ссылку и доступность VK; ручная капча пока не поддерживается."
                    : "Авторизация или соединение VK TURN не удались (код \(ready)).", completionHandler: completionHandler)
                return
            }

            var wireGuardConfig = configuration.wireGuardConfig ?? ""
            var tunnelAddress = configuration.tunnelAddress ?? ""
            var dnsServers = configuration.dnsServers ?? "1.1.1.1"
            var mtu = 1280
            if configuration.isWrapA {
                let remaining = max(0, min(30_000, Int(deadline.timeIntervalSinceNow * 1_000)))
                let provisionPointer = wgWaitWrapAProvision(started, Int32(remaining))
                let provision = provisionPointer.map { pointer -> String in
                    defer { free(UnsafeMutableRawPointer(mutating: pointer)) }
                    return String(cString: pointer)
                } ?? ""
                guard let data = provision.data(using: .utf8),
                      let values = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                      let uapi = values["uapi"] as? String, !uapi.isEmpty,
                      let address = values["address"] as? String,
                      VKTurnConfiguration.validTunnelAddress(address) else {
                    self.fail(started, message: "Сервер VK TURN не предоставил параметры WRAP-A за 120 секунд.", completionHandler: completionHandler)
                    return
                }
                wireGuardConfig = uapi
                tunnelAddress = address
                if let dns = values["dns"] as? String, !dns.isEmpty { dnsServers = dns }
                if let suggestedMTU = values["mtu"] as? Int { mtu = max(1280, min(1500, suggestedMTU)) }
            }

            let turnIP = wgGetTURNServerIP(started).map { pointer -> String in
                defer { free(UnsafeMutableRawPointer(mutating: pointer)) }
                return String(cString: pointer)
            } ?? ""
            VKTurnConfigurationStore.rememberRelayAddress(turnIP)
            let settings = Self.makeSettings(address: tunnelAddress, dns: dnsServers, mtu: mtu,
                                             remote: turnIP.isEmpty ? "10.0.0.1" : turnIP)
            self.setTunnelNetworkSettings(settings) { [weak self] error in
                guard let self else { return }
                guard self.isCurrent(started) else {
                    completionHandler(Self.error("Подключение VK TURN отменено."))
                    return
                }
                if let error {
                    self.fail(started, message: error.localizedDescription, completionHandler: completionHandler)
                    return
                }
                guard let fd = Self.findTunFileDescriptor() else {
                    self.fail(started, message: "Не удалось получить TUN-интерфейс VK TURN.", completionHandler: completionHandler)
                    return
                }
                let result = wireGuardConfig.withCString { wgAttachWireGuard(started, $0, fd) }
                guard result == 1 else {
                    self.fail(started, message: "WireGuard через VK TURN не запустился (код \(result)).", completionHandler: completionHandler)
                    return
                }
                self.logger.info("VK TURN connected")
                completionHandler(nil)
            }
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        lock.lock()
        stopped = true
        let active = handle
        handle = nil
        lock.unlock()
        if let active { wgTurnOff(active) }
        completionHandler()
    }

    override func handleAppMessage(_ messageData: Data, completionHandler: (@Sendable (Data?) -> Void)?) {
        guard messageData == Data("stats".utf8) else {
            completionHandler?(nil)
            return
        }
        lock.lock()
        let active = handle
        lock.unlock()
        guard let active, let pointer = wgGetStats(active) else {
            completionHandler?(nil)
            return
        }
        let result = Data(String(cString: pointer).utf8)
        free(UnsafeMutableRawPointer(mutating: pointer))
        completionHandler?(result)
    }

    private func isCurrent(_ candidate: Int32) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return !stopped && handle == candidate
    }

    private func fail(_ candidate: Int32, message: String, completionHandler: @escaping (Error?) -> Void) {
        lock.lock()
        if handle == candidate { handle = nil }
        lock.unlock()
        wgTurnOff(candidate)
        VKTurnConfigurationStore.setLastError(message)
        logger.error("VK TURN start failed")
        completionHandler(Self.error(message))
    }

    private static func error(_ message: String) -> Error {
        NSError(domain: "VKTurnExtension", code: -1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private static func makeSettings(address tunnelAddress: String, dns dnsServers: String, mtu: Int,
                                     remote: String) -> NEPacketTunnelNetworkSettings {
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: remote)
        let parts = tunnelAddress.split(separator: "/")
        let address = String(parts[0])
        let prefix = Int(parts[1]) ?? 24
        let mask = (0..<4).map { index -> String in
            let bits = max(0, min(8, prefix - index * 8))
            return String(bits == 0 ? 0 : 256 - (1 << (8 - bits)))
        }.joined(separator: ".")
        let ipv4 = NEIPv4Settings(addresses: [address], subnetMasks: [mask])
        ipv4.includedRoutes = [NEIPv4Route.default()]
        settings.ipv4Settings = ipv4
        let dns = dnsServers.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
        settings.dnsSettings = NEDNSSettings(servers: dns)
        settings.mtu = NSNumber(value: mtu)
        return settings
    }

    private static func findTunFileDescriptor() -> Int32? {
        for fd: Int32 in 0...1024 {
            var name = [CChar](repeating: 0, count: Int(IFNAMSIZ))
            var length = socklen_t(name.count)
            if getsockopt(fd, 2, 2, &name, &length) == 0,
               String(cString: name).hasPrefix("utun") {
                return fd
            }
        }
        return nil
    }
}
