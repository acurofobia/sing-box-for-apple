import Foundation
import Libbox
import NetworkExtension
import os
#if os(iOS)
    import FileProvider
    import Network
#endif

private let logger = Logger(category: "ExtensionProfile")

@MainActor
public class ExtensionProfile: ObservableObject {
    public static let controlKind = AppConfiguration.widgetControlKind

    private var manager: NEVPNManager?
    #if os(iOS)
        private var singManager: NETunnelProviderManager?
        private var vkManager: NETunnelProviderManager?
    #endif
    private var connection: NEVPNConnection?
    private var observers: [Any] = []
    private let isMock: Bool

    public enum ProviderKind: String, Sendable {
        case singBox, vkTurn

        public var title: String {
            switch self {
            case .singBox: return "sing-box"
            case .vkTurn: return "VK TURN"
            }
        }
    }

    @Published public private(set) var activeProvider: ProviderKind = .singBox
    @Published public private(set) var startupError: String?

    @Published public var status: NEVPNStatus
    @Published public var connectedDate: Date?

    public init(_ manager: NEVPNManager) {
        self.manager = manager
        connection = manager.connection
        status = manager.connection.status
        connectedDate = manager.connection.connectedDate
        isMock = false
    }

    #if os(iOS)
        private init(singManager: NETunnelProviderManager?, vkManager: NETunnelProviderManager?, active: ProviderKind) {
            self.singManager = singManager
            self.vkManager = vkManager
            activeProvider = active
            let selected = active == .vkTurn ? vkManager : singManager
            manager = selected
            connection = selected?.connection
            status = selected?.connection.status ?? .disconnected
            connectedDate = selected?.connection.connectedDate
            isMock = false
            if active == .vkTurn, status == .disconnected {
                startupError = VKTurnConfigurationStore.lastError
            }
        }
    #endif

    private init(mockStatus: NEVPNStatus, mockConnectedDate: Date?) {
        manager = nil
        connection = nil
        status = mockStatus
        connectedDate = mockConnectedDate
        isMock = true
    }

    private static var _mock: ExtensionProfile?

    public static var mock: ExtensionProfile {
        if _mock == nil {
            _mock = ExtensionProfile(mockStatus: .connected, mockConnectedDate: Date().addingTimeInterval(-3600))
        }
        return _mock!
    }

    public func register() {
        guard !isMock else { return }
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        #if os(iOS)
            let candidates: [(NETunnelProviderManager, ProviderKind)] = [
                singManager.map { ($0, .singBox) }, vkManager.map { ($0, .vkTurn) },
            ].compactMap { $0 }
        #else
            let candidates: [(NEVPNManager, ProviderKind)] = manager.map { [($0, .singBox)] } ?? []
        #endif
        for (candidate, kind) in candidates {
            let token = NotificationCenter.default.addObserver(
                forName: NSNotification.Name.NEVPNStatusDidChange,
                object: candidate.connection,
                queue: nil
            ) { [weak self] notification in
                guard notification.object is NEVPNConnection else { return }
                Task { @MainActor in
                    guard let self else { return }
                    #if os(iOS)
                        let changedManager = kind == .vkTurn ? self.vkManager : self.singManager
                    #else
                        let changedManager = self.manager
                    #endif
                    guard let changedManager else { return }
                    let changed = changedManager.connection
                    if changed.status.isStarted && self.activeProvider != kind {
                        self.selectActive(changedManager, kind: kind)
                    }
                    guard self.activeProvider == kind else { return }
                    self.connection = changed
                    self.status = changed.status
                    self.connectedDate = changed.connectedDate
                    if changed.status == .disconnected, kind == .singBox {
                        Self.schedulePromoteOOMDraft()
                    }
                    #if os(iOS)
                        if changed.status == .disconnected, kind == .vkTurn {
                            self.startupError = VKTurnConfigurationStore.lastError
                            if #available(iOS 16.0, *) {
                                do {
                                    try await changed.fetchLastDisconnectError()
                                } catch {
                                    if self.startupError == nil {
                                        self.startupError = error.localizedDescription
                                    }
                                }
                            }
                        }
                        if #available(iOS 16.0, *), changed.status == .connected || changed.status == .disconnected {
                            Self.signalFileProviderChanges()
                        }
                    #endif
                }
            }
            observers.append(token)
        }
    }

    private func selectActive(_ selected: NEVPNManager, kind: ProviderKind) {
        manager = selected
        connection = selected.connection
        activeProvider = kind
        status = selected.connection.status
        connectedDate = selected.connection.connectedDate
        startupError = nil
    }

    public func recordStartupError(_ message: String) {
        startupError = message
    }

    private static func schedulePromoteOOMDraft() {
        Task.detached {
            try? await Task.sleep(nanoseconds: 2 * NSEC_PER_SEC)
            #if os(macOS)
                if Variant.useSystemExtension {
                    guard HelperServiceManager.rootHelperStatus == .enabled else {
                        return
                    }
                    do {
                        try RootHelperClient.shared.promoteOOMDraft()
                    } catch {
                        logger.warning("promote OOM draft: \(error.localizedDescription)")
                    }
                    return
                }
            #endif
            LibboxPromoteOOMDraft()
        }
    }

    #if os(iOS)
        @available(iOS 16.0, *)
        private static func signalFileProviderChanges() {
            Task.detached {
                guard let domain = try? await NSFileProviderManager.domains()
                    .first(where: { $0.identifier.rawValue == AppConfiguration.fileProviderDomainID }),
                    let manager = NSFileProviderManager(for: domain)
                else {
                    return
                }
                try? await manager.signalEnumerator(for: .workingSet)
            }
        }
    #endif

    nonisolated deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    private static func makeDefaultOnDemandRules() -> [NEOnDemandRule] {
        let rule = NEOnDemandRuleConnect()
        rule.interfaceTypeMatch = .any
        rule.probeURL = URL(string: "http://captive.apple.com")
        return [rule]
    }

    private func setOnDemandRules(useDefaultRules: Bool) async {
        guard let manager else { return }
        if useDefaultRules {
            manager.onDemandRules = Self.makeDefaultOnDemandRules()
        } else {
            let rules = await SharedPreferences.onDemandRules.get()
            manager.onDemandRules = rules.isEmpty ? Self.makeDefaultOnDemandRules() : rules.map { $0.toNERule() }
        }
    }

    public func updateOnDemand(enabled: Bool, useDefaultRules: Bool) async throws {
        guard let manager else { return }
        manager.isOnDemandEnabled = enabled
        if !enabled {
            if let proto = manager.protocolConfiguration as? NETunnelProviderProtocol {
                var config = proto.providerConfiguration ?? [:]
                if config.removeValue(forKey: "wasOnDemandEnabled") != nil {
                    proto.providerConfiguration = config
                }
            }
        }
        await setOnDemandRules(useDefaultRules: useDefaultRules)
        try await manager.saveToPreferences()
    }

    @available(iOS 16.0, macOS 13.0, tvOS 17.0, *)
    public func fetchLastDisconnectError() async throws {
        guard let connection else { return }
        try await connection.fetchLastDisconnectError()
    }

    public func start() async throws {
        if isMock {
            status = .connecting
            try await Task.sleep(nanoseconds: 500_000_000)
            status = .connected
            connectedDate = Date()
            return
        }
        guard let manager else { return }
        if activeProvider == .singBox {
            try await fetchProfile()
        }
        manager.isEnabled = true
        let alwaysOn = await SharedPreferences.alwaysOn.get()
        let onDemandEnabled = await SharedPreferences.onDemandEnabled.get()
        if alwaysOn || onDemandEnabled {
            manager.isOnDemandEnabled = true
            await setOnDemandRules(useDefaultRules: alwaysOn)
        }
        if let proto = manager.protocolConfiguration as? NETunnelProviderProtocol {
            var config = proto.providerConfiguration ?? [:]
            if config.removeValue(forKey: "wasOnDemandEnabled") != nil {
                proto.providerConfiguration = config
            }
        }
        #if !os(tvOS)
            if let protocolConfiguration = manager.protocolConfiguration {
                let includeAllNetworks = await SharedPreferences.includeAllNetworks.get()
                protocolConfiguration.includeAllNetworks = activeProvider == .vkTurn || includeAllNetworks
                protocolConfiguration.excludeLocalNetworks = await SharedPreferences.excludeLocalNetworks.get()
                let enforceRoutes = await SharedPreferences.enforceRoutes.get()
                protocolConfiguration.enforceRoutes = activeProvider == .singBox && enforceRoutes
                if #available(iOS 16.4, macOS 13.3, *) {
                    protocolConfiguration.excludeAPNs = await SharedPreferences.excludeAPNs.get()
                    protocolConfiguration.excludeCellularServices = await SharedPreferences.excludeCellularServices.get()
                }
                if #available(iOS 17.4, macOS 14.4, *) {
                    protocolConfiguration.excludeDeviceCommunication = await SharedPreferences.excludeDeviceCommunication.get()
                }
            }
        #endif
        try await manager.saveToPreferences()
        let options = activeProvider == .singBox ? try await prepareStartOptions() : nil
        try manager.connection.startVPNTunnel(options: options)
    }

    public func reloadService() async throws {
        if isMock {
            return
        }
        let options = try await prepareStartOptions()
        let data = try ExtensionStartOptions.encode(options)
        guard let session = connection as? NETunnelProviderSession else {
            throw NSError(domain: "ExtensionStartOptions", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "Tunnel session unavailable",
            ])
        }
        let response = try await withCheckedThrowingContinuation { continuation in
            do {
                try session.sendProviderMessage(data) { response in
                    continuation.resume(returning: response)
                }
            } catch {
                continuation.resume(throwing: error)
            }
        }
        if let response, !response.isEmpty {
            let message = String(data: response, encoding: .utf8) ?? "Unknown error"
            throw NSError(domain: "ExtensionStartOptions", code: -1, userInfo: [
                NSLocalizedDescriptionKey: message,
            ])
        }
    }

    private func prepareStartOptions() async throws -> [String: NSObject] {
        var options: [String: NSObject] = [
            "manualStart": NSNumber(value: true),
            "locale": NSString(string: ApplicationLocale.preferredIdentifier),
        ]

        let profileID = await SharedPreferences.selectedProfileID.get()
        guard let profile = try await ProfileManager.get(profileID) else {
            throw NSError(domain: "ExtensionProfile", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "Missing selected profile",
            ])
        }

        let configContent = try await profile.readAsync()
        options["configContent"] = NSString(string: configContent)

        #if os(macOS)
            options["oomKillerEnabled"] = await NSNumber(value: SharedPreferences.oomKillerEnabled.get())
            options["oomMemoryLimitMB"] = await NSNumber(value: SharedPreferences.oomMemoryLimitMB.get())
            options["oomKillerKillConnections"] = await NSNumber(value: SharedPreferences.oomKillerKillConnections.get())
        #endif
        options["powerReportEnabled"] = await NSNumber(value: SharedPreferences.powerReportEnabled.get())
        options["systemProxyEnabled"] = await NSNumber(value: SharedPreferences.systemProxyEnabled.get())
        options["excludeDefaultRoute"] = await NSNumber(value: SharedPreferences.excludeDefaultRoute.get())
        options["autoRouteUseSubRangesByDefault"] = await NSNumber(value: SharedPreferences.autoRouteUseSubRangesByDefault.get())
        options["excludeAPNsRoute"] = await NSNumber(value: SharedPreferences.excludeAPNsRoute.get())

        #if !os(tvOS)
            options["includeAllNetworks"] = await NSNumber(value: SharedPreferences.includeAllNetworks.get())
        #endif

        #if os(tvOS)
            options["commandServerPort"] = await NSNumber(value: SharedPreferences.commandServerPort.get())
            options["commandServerSecret"] = await NSString(string: SharedPreferences.commandServerSecret.get())
        #endif

        return options
    }

    public func fetchProfile() async throws {
        let profileID = await SharedPreferences.selectedProfileID.get()
        if let profile = try await ProfileManager.get(profileID), profile.type == .icloud {
            _ = try await profile.readAsync()
        }
    }

    public func stop() async throws {
        if isMock {
            status = .disconnecting
            try await Task.sleep(nanoseconds: 300_000_000)
            status = .disconnected
            connectedDate = nil
            return
        }
        guard let manager else { return }
        if manager.isOnDemandEnabled {
            if let proto = manager.protocolConfiguration as? NETunnelProviderProtocol {
                var config = proto.providerConfiguration ?? [:]
                config["wasOnDemandEnabled"] = true
                proto.providerConfiguration = config
            }
            manager.isOnDemandEnabled = false
            try await manager.saveToPreferences()
        }
        if activeProvider == .singBox {
            do {
                try await Task.detached(priority: .userInitiated) {
                    try LibboxNewStandaloneCommandClient()!.serviceClose()
                }.value
            } catch {
                logger.debug("serviceClose error: \(error.localizedDescription)")
            }
        }
        manager.connection.stopVPNTunnel()
    }

    public func restart() async throws {
        try await stop()
        var waitSeconds = 0
        while status != .disconnected {
            try await Task.sleep(nanoseconds: NSEC_PER_SEC)
            waitSeconds += 1
            if waitSeconds >= 5 {
                throw NSError(domain: "ExtensionProfile", code: 0, userInfo: [NSLocalizedDescriptionKey: String(localized: "Restart service timeout")])
            }
        }
        try await start()
    }

    #if os(iOS)
        public func vkTurnStats() async throws -> VKTurnStats {
            guard activeProvider == .vkTurn,
                  let session = connection as? NETunnelProviderSession else {
                throw VKTurnError.missingConfiguration
            }
            let response = try await withCheckedThrowingContinuation { continuation in
                do {
                    try session.sendProviderMessage(Data("stats".utf8)) { data in
                        continuation.resume(returning: data)
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
            guard let response else { throw VKTurnError.invalidField }
            return try JSONDecoder().decode(VKTurnStats.self, from: response)
        }

        private struct ProbeMetadata: Decodable {
            let `default`: String
            let defaultUsable: Bool
            let candidates: [String]
        }

        public func startManual() async throws {
            guard await Self.hasPhysicalNetwork() else {
                throw NSError(domain: "VPNChoice", code: 1, userInfo: [NSLocalizedDescriptionKey: "Нет подключения к сети."])
            }
            startupError = nil
            let onlyVK = await SharedPreferences.onlyVKTurn.get()
            if onlyVK {
                _ = try VKTurnConfigurationStore.load()
                try await selectProvider(.vkTurn)
                try await start()
                return
            }

            let profileID = await SharedPreferences.selectedProfileID.get()
            var singWorks = false
            if let profile = try? await ProfileManager.get(profileID) {
                do {
                    let content = try await profile.readAsync()
                    let metadata = try await Task.detached(priority: .userInitiated) {
                        var error: NSError?
                        let result = LibboxProbeOutbounds(content, &error)
                        if let error { throw error }
                        guard let data = result.data(using: .utf8) else { throw VKTurnError.invalidField }
                        return try JSONDecoder().decode(ProbeMetadata.self, from: data)
                    }.value
                    let preferred = await SharedPreferences.probeOutboundTag.get()
                    let tag: String
                    if !preferred.isEmpty, metadata.candidates.contains(preferred) {
                        tag = preferred
                    } else if metadata.defaultUsable {
                        tag = ""
                    } else {
                        throw NSError(domain: "VPNChoice", code: 3, userInfo: [NSLocalizedDescriptionKey: "route.final ведёт напрямую или выбранный outbound отсутствует в профиле. Выберите проверяемый outbound в настройках VPN."])
                    }
                    singWorks = try await Task.detached(priority: .userInitiated) {
                        var error: NSError?
                        var success = ObjCBool(false)
                        LibboxProbeConfig(content, tag, 10_000, &success, &error)
                        if let error {
                            if error.localizedDescription.contains("choose a non-direct outbound") {
                                throw NSError(domain: "VPNChoice", code: 3, userInfo: [NSLocalizedDescriptionKey: "Выбранный outbound ведёт напрямую. Выберите другой outbound в настройках VPN."])
                            }
                            throw error
                        }
                        return success.boolValue
                    }.value
                } catch let error as NSError where error.domain == "VPNChoice" {
                    throw error
                } catch {
                    logger.warning("sing-box probe failed: \(error.localizedDescription)")
                }
            }
            if singWorks {
                try await selectProvider(.singBox)
                try await start()
                return
            }
            _ = try VKTurnConfigurationStore.load()
            try await selectProvider(.vkTurn)
            try await start()
        }

        private static func hasPhysicalNetwork() async -> Bool {
            await Task.detached(priority: .userInitiated) { physicalNetworkAvailable() }.value
        }

        private nonisolated static func physicalNetworkAvailable() -> Bool {
            let monitor = NWPathMonitor()
            let ready = DispatchSemaphore(value: 0)
            monitor.pathUpdateHandler = { _ in ready.signal() }
            monitor.start(queue: DispatchQueue(label: "VPNChoice.NetworkPath"))
            let received = ready.wait(timeout: .now() + 2) == .success
            let satisfied = monitor.currentPath.status == .satisfied
            monitor.cancel()
            return received && satisfied
        }

        private func selectProvider(_ kind: ProviderKind) async throws {
            let selected: NETunnelProviderManager
            if kind == .vkTurn {
                let configuration = try VKTurnConfigurationStore.load()
                if vkManager == nil {
                    let newManager = NETunnelProviderManager()
                    newManager.localizedDescription = "VK TURN"
                    let tunnel = NETunnelProviderProtocol()
                    tunnel.providerBundleIdentifier = AppConfiguration.vkTurnExtensionBundleID
                    tunnel.serverAddress = VKTurnConfigurationStore.serverAddress(for: configuration)
                    newManager.protocolConfiguration = tunnel
                    newManager.isEnabled = true
                    try await newManager.saveToPreferences()
                    try await newManager.loadFromPreferences()
                    vkManager = newManager
                    register()
                }
                guard let vkManager else { throw VKTurnError.missingConfiguration }
                selected = vkManager
                if let tunnel = selected.protocolConfiguration as? NETunnelProviderProtocol {
                    tunnel.serverAddress = VKTurnConfigurationStore.serverAddress(for: configuration)
                }
            } else {
                guard let singManager else { throw VKTurnError.invalidField }
                selected = singManager
            }
            let other = kind == .vkTurn ? singManager : vkManager
            if let other, other.isOnDemandEnabled {
                other.isOnDemandEnabled = false
                try await other.saveToPreferences()
            }
            selectActive(selected, kind: kind)
            await SharedPreferences.lastVPNProvider.set(kind.rawValue)
        }
    #else
        public func startManual() async throws { try await start() }
    #endif

    public static func load() async throws -> ExtensionProfile? {
        let managers = try await NETunnelProviderManager.loadAllFromPreferences()
        #if os(iOS)
            let sing = managers.first { ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == AppConfiguration.extensionBundleID }
            let vk = managers.first { ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == AppConfiguration.vkTurnExtensionBundleID }
            guard sing != nil || vk != nil else { return nil }
            let saved = await SharedPreferences.lastVPNProvider.get()
            let active: ProviderKind
            if vk?.connection.status.isConnected == true {
                active = .vkTurn
            } else if sing?.connection.status.isConnected == true {
                active = .singBox
            } else {
                active = saved == ProviderKind.vkTurn.rawValue && vk != nil ? .vkTurn : .singBox
            }
            let profile = ExtensionProfile(singManager: sing, vkManager: vk, active: active == .singBox && sing == nil ? .vkTurn : active)
            return profile
        #else
        if managers.isEmpty {
            return nil
        }
        let providerID = Variant.useSystemExtension ? AppConfiguration.systemExtensionBundleID : AppConfiguration.extensionBundleID
        guard let manager = managers.first(where: { ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == providerID }) else { return nil }
        let profile = ExtensionProfile(manager)
        if profile.status == .disconnected {
            schedulePromoteOOMDraft()
        }
        return profile
        #endif
    }

    public static func install() async throws {
        let providerID = Variant.useSystemExtension ? AppConfiguration.systemExtensionBundleID : AppConfiguration.extensionBundleID
        let existing = try await NETunnelProviderManager.loadAllFromPreferences()
        guard !existing.contains(where: { ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == providerID }) else { return }
        let manager = NETunnelProviderManager()
        manager.localizedDescription = Variant.applicationName
        let tunnelProtocol = NETunnelProviderProtocol()
        if Variant.useSystemExtension {
            tunnelProtocol.providerBundleIdentifier = providerID
        } else {
            tunnelProtocol.providerBundleIdentifier = providerID
        }
        tunnelProtocol.serverAddress = "sing-box"
        manager.protocolConfiguration = tunnelProtocol
        manager.isEnabled = true
        try await manager.saveToPreferences()
    }
}
