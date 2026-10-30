import Library
import NetworkExtension
import SwiftUI

enum PrototypeConnectionMode: String, CaseIterable {
    case vkTurn = "vk-turn"
    case vless

    var optionID: String {
        self == .vless ? "option01" : "option02"
    }

    static func from(optionID: String) -> Self? {
        switch optionID {
        case "option01": return .vless
        case "option02": return .vkTurn
        default: return nil
        }
    }

    var title: String {
        self == .vless ? "VLESS" : "VK TURN"
    }
}

@main
struct PrototypeApplication: App {
    var body: some Scene {
        WindowGroup { PrototypeView() }
    }
}

@MainActor
final class PrototypeModel: ObservableObject {
    @Published var status = "Отключено"
    @Published var error: String? {
        didSet { if let error, error != oldValue { VPNDiagnostics.applicationError(error) } }
    }
    @Published var footprint = "—"
    private let connections = 30
    @Published var busy = true
    private var managersLoaded = false
    @Published private(set) var subscription = PrototypeSubscription()
    var hasLink: Bool {
        subscription.vkTurnLink != nil
    }

    var hasVLESS: Bool {
        subscription.vlessOutbound != nil || subscription.vlessProvisioning?.isAvailable == true
    }

    func isAvailable(_ mode: PrototypeConnectionMode) -> Bool {
        subscription.isAvailable(optionID: mode.optionID)
    }

    @Published private(set) var subscriptionLoading = false
    @Published private(set) var replacingSubscription = false
    @Published private(set) var resetting = false
    @Published private(set) var subscriptionError: String? {
        didSet { if let subscriptionError, subscriptionError != oldValue { VPNDiagnostics.applicationError("subscription: " + subscriptionError) } }
    }
    @Published private(set) var hasSelectedMode = false
    @Published private(set) var vpnState: NEVPNStatus = .disconnected
    @Published private(set) var connectedAt: Date?
    @Published private(set) var failoverStatus: PriorityFailoverStatus?
    @Published private(set) var retainedModeTitle: String?
    private var loaded = false
    private var connectionGeneration: UInt64 = 0
    private var hasInitializedSelection = false
    private lazy var preferences: UserDefaults = {
        #if DEBUG && targetEnvironment(simulator)
            if ProcessInfo.processInfo.environment["PROTOTYPE_UI_TESTING"] == "1",
               let defaults = UserDefaults(suiteName: "PrototypeUITests")
            {
                return defaults
            }
        #endif
        return .standard
    }()

    private lazy var store = PrototypeSubscriptionStore(cacheURL: cacheURL)
    private var deviceAccessStore: SubscriptionDeviceAccessStore {
        SubscriptionDeviceAccessStore(cacheURL: cacheURL)
    }
    private var cacheURL: URL {
        #if DEBUG && targetEnvironment(simulator)
            if ProcessInfo.processInfo.environment["PROTOTYPE_UI_TESTING"] == "1" {
                return FileManager.default.temporaryDirectory.appendingPathComponent("prototype-ui-tests/subscription.json")
            }
        #endif
        return FilePath.sharedDirectory.appendingPathComponent("prototype-subscription.json")
    }

    var modeTitle: String {
        guard hasSelectedMode else { return String(localized: "Выберите режим") }
        return subscription.uiDocument?.blocks.first(where: { $0.id == "block04" })?.items?.first(where: { $0.id == connectionMode.optionID })?.title
            ?? retainedModeTitle ?? (hasSelectedMode ? connectionMode.title : String(localized: "Выберите режим"))
    }

    var canStart: Bool {
        hasSelectedMode && isAvailable(connectionMode) && !busy && !replacingSubscription && (vpnState == .disconnected || vpnState == .invalid)
    }

    var canStop: Bool {
        vpnState != .disconnected && vpnState != .invalid
    }

    var modeWarning: String? {
        guard hasSelectedMode else { return String(localized: "Нет доступных режимов") }
        guard !isAvailable(connectionMode) else { return nil }
        return String(localized: "Выбранный режим недоступен. Для следующего подключения выберите другой режим.")
    }

    @Published private(set) var connectionMode: PrototypeConnectionMode = .vkTurn
    @Published private(set) var routingMode: PrototypeRoutingMode = .enabled
    private var manager: NETunnelProviderManager?
    private var lastDiagnosticState: NEVPNStatus?
    private var disconnectDiagnosticTask: Task<Void, Never>?

    func recordVPNState(force: Bool = false) {
        guard !resetting else { return }
        guard let connection = manager?.connection else { return }
        let state = connection.status
        guard force || state != lastDiagnosticState else { return }
        lastDiagnosticState = state
        VPNDiagnostics.observeConnection(disconnected: state == .disconnected || state == .invalid)
        VPNDiagnostics.app("VPN status=\(state.rawValue) (\(state)) connectedAt=\(connection.connectedDate?.ISO8601Format() ?? "none") enabled=\(manager?.isEnabled ?? false) onDemand=\(manager?.isOnDemandEnabled ?? false) disconnectOnSleep=\(manager?.protocolConfiguration?.disconnectOnSleep ?? false)")
        if force || state == .disconnected, #available(iOS 16.0, *) {
            let generation = connectionGeneration
            disconnectDiagnosticTask?.cancel()
            disconnectDiagnosticTask = Task {
                do {
                    try await connection.fetchLastDisconnectError()
                    guard !Task.isCancelled, generation == connectionGeneration else { return }
                    VPNDiagnostics.app("iOS returned no last disconnect error; termination cause is unknown")
                } catch {
                    guard !Task.isCancelled, generation == connectionGeneration else { return }
                    let error = error as NSError
                    VPNDiagnostics.applicationError("last VPN disconnect error", error: error)
                    VPNDiagnostics.app("last disconnect error domain=\(error.domain) code=\(error.code) description=\(error.localizedDescription)")
                }
            }
        }
    }

    func collectDiagnostics() async {
        recordVPNState(force: true)
        await disconnectDiagnosticTask?.value
        let crashes = CrashReportManager()
        await crashes.refresh()
    }

    func load() async {
        guard !loaded else { return }
        loaded = true
        VPNDiagnostics.app("application loaded \(VPNDiagnostics.environment)")
        busy = true
        defer { busy = false }
        #if DEBUG && targetEnvironment(simulator)
            if ProcessInfo.processInfo.environment["PROTOTYPE_UI_TESTING"] == "1",
               ProcessInfo.processInfo.environment["PROTOTYPE_UI_RESET"] == "1"
            {
                preferences.removePersistentDomain(forName: "PrototypeUITests")
            }
        #endif
        hasInitializedSelection = preferences.bool(forKey: "prototype.connection.selectionInitialized")
        hasSelectedMode = preferences.string(forKey: "prototype.connection.mode") != nil
        connectionMode = PrototypeConnectionMode(rawValue: preferences.string(forKey: "prototype.connection.mode") ?? "") ?? .vkTurn
        routingMode = PrototypeRoutingMode(rawValue: preferences.string(forKey: "prototype.routing.mode") ?? "") ?? .enabled
        do {
            #if !targetEnvironment(simulator)
                let managers = try await NETunnelProviderManager.loadAllFromPreferences()
                manager = managers.first { ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == AppConfiguration.extensionBundleID }
            #endif
            // Simulator cannot run packet tunnels, but can import and display configurations.
            managersLoaded = true
            try ServiceSetup.apply(crashReportSource: "PrototypeApplication")
            #if DEBUG && targetEnvironment(simulator)
                if ProcessInfo.processInfo.environment["PROTOTYPE_UI_TESTING"] == "1",
                   ProcessInfo.processInfo.environment["PROTOTYPE_UI_RESET"] == "1"
                {
                    try? FileManager.default.removeItem(at: cacheURL)
                    hasSelectedMode = false
                }
            #endif
            try store.load()
            subscription = store.snapshot
            chooseInitialMode()
            if let settings = (manager?.protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration, manager?.connection.status == .connected || manager?.connection.status == .connecting {
                connectionMode = PrototypeConnectionMode(rawValue: settings["mode"] as? String ?? "") ?? .vkTurn
                hasSelectedMode = true
            }
            await refresh()
        } catch {
            VPNDiagnostics.applicationError("load application state", error: error)
            self.error = String(localized: "Не удалось загрузить сохранённое состояние приложения.")
        }
    }

    private func ensureStopped() throws {
        guard managersLoaded else { throw PrototypeSubscriptionError.notReady }
        let state = manager?.connection.status ?? .disconnected
        guard state == .disconnected || state == .invalid else { throw PrototypeSubscriptionError.stopBeforeImport }
    }

    private func removeRuntimeVLESS() throws {
        let url = FilePath.sharedDirectory.appendingPathComponent("prototype-vless.json")
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    private func chooseInitialMode() {
        guard !hasSelectedMode, !hasInitializedSelection, subscription.isComplete else { return }
        hasInitializedSelection = true
        preferences.set(true, forKey: "prototype.connection.selectionInitialized")
        let items = subscription.uiDocument?.block("block04")?.items ?? []
        if let mode = items.compactMap({ PrototypeConnectionMode.from(optionID: $0.id) }).first(where: { isAvailable($0) }) {
            connectionMode = mode
            hasSelectedMode = true
            preferences.set(mode.rawValue, forKey: "prototype.connection.mode")
        }
    }

    func refreshSubscription(force: Bool = false) async {
        guard !resetting, let source = subscription.sourceURL, !store.isLoading else { return }
        await fetchSubscription(source, replacing: false, automatic: !force)
    }

    private func synchronizeDeviceAccess() {
        guard !resetting, let source = subscription.sourceURL,
              let decision = try? deviceAccessStore.decision(forSource: source), decision.state.isDenied else { return }
        // Invalidate queued WDTT starts before touching persistence or awaiting shutdown.
        let runningMode = (manager?.protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration?["mode"] as? String
        if connectionMode == .vkTurn || runningMode == "vk-turn" {
            connectionGeneration &+= 1
            if canStop, runningMode != "vless" {
                VPNDiagnostics.expectStop()
                manager?.connection.stopVPNTunnel()
            }
        }
        do {
            try deviceAccessStore.purgeRuntimeIfDenied(source: source)
            try store.load()
            subscription = store.snapshot
        } catch {
            // Keep the mode blocked in memory even if protected storage is unavailable.
            subscription.vkTurnLink = nil
            subscription.wdttAccessState = decision.state
            subscriptionError = String(localized: "Доступ отозван. Не удалось полностью удалить сохранённую конфигурацию.")
        }
    }

    @discardableResult func replaceSubscription(_ source: String) async -> Bool {
        guard !resetting else { return false }
        do {
            try ensureStopped()
        } catch {
            VPNDiagnostics.applicationError("replace subscription while VPN is active", error: error)
            subscriptionError = PrototypeSubscriptionError.stopBeforeImport.localizedDescription; return false
        }
        return await fetchSubscription(source.trimmingCharacters(in: .whitespacesAndNewlines), replacing: true)
    }

    func cancelSubscriptionReplacement() {
        guard replacingSubscription else { return }
        store.cancel()
        replacingSubscription = false
        subscriptionLoading = false
    }

    @discardableResult private func fetchSubscription(_ source: String, replacing: Bool, automatic: Bool = false) async -> Bool {
        defer { synchronizeDeviceAccess() }
        subscriptionLoading = true
        replacingSubscription = replacing
        subscriptionError = nil
        defer {
            subscriptionLoading = store.isLoading
            if !store.isLoading {
                replacingSubscription = false
            }
        }
        do {
            let updated = try await store.update(source, replacing: replacing, automatic: automatic) {
                if replacing {
                    try self.ensureStopped()
                }
            }
            guard let updated else { return false }
            retainedModeTitle = modeTitle
            subscription = updated
            for warning in updated.warnings { VPNDiagnostics.applicationError("subscription warning: " + warning) }
            chooseInitialMode()
            return true
        } catch let issue as PrototypeSubscriptionError {
            VPNDiagnostics.applicationError("update subscription", error: issue)
            subscriptionError = issue.localizedDescription
        } catch let issue as PrototypeUIError {
            VPNDiagnostics.applicationError("decode subscription UI", error: issue)
            subscriptionError = PrototypeUIError.invalidDocument.localizedDescription
        } catch {
            // System/network errors can include the credential-bearing URL.
            VPNDiagnostics.applicationError("update subscription", error: error)
            subscriptionError = String(localized: "Не удалось обновить подписку. Проверьте сеть и сервер. Сохранённые данные не изменены.")
        }
        return false
    }

    func resetApplication() async {
        guard !busy, !resetting else { return }
        resetting = true
        busy = true
        error = nil
        connectionGeneration &+= 1
        store.cancel()
        defer { busy = false; resetting = false }
        do {
            disconnectDiagnosticTask?.cancel()
            await disconnectDiagnosticTask?.value
            disconnectDiagnosticTask = nil
            var managers: [NETunnelProviderManager] = []
            #if !targetEnvironment(simulator)
                managers = try await NETunnelProviderManager.loadAllFromPreferences().filter {
                    guard let identifier = ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier else { return false }
                    return [AppConfiguration.extensionBundleID, AppConfiguration.vkTurnExtensionBundleID].contains(identifier)
                }
            #endif
            VPNDiagnostics.expectStop()
            for manager in managers {
                manager.isOnDemandEnabled = false
                try await manager.saveToPreferences()
                manager.connection.stopVPNTunnel()
            }
            let deadline = ContinuousClock.now.advanced(by: .seconds(15))
            while managers.contains(where: { $0.connection.status != .disconnected && $0.connection.status != .invalid }) {
                guard ContinuousClock.now < deadline else {
                    throw NSError(domain: "Prototype", code: 3, userInfo: [NSLocalizedDescriptionKey: "VPN не отключился. Повторите сброс после отключения."])
                }
                try await Task.sleep(for: .milliseconds(100))
            }
            for manager in managers { try await manager.removeFromPreferences() }
            try await store.reset()
            subscription = PrototypeSubscription()
            try VKTurnConfigurationStore.clear()
            try VPNDiagnostics.reset()
            let fm = FileManager.default
            var directories = [FilePath.sharedDirectory.appendingPathComponent("Library/Caches"),
                               FilePath.sharedDirectory.appendingPathComponent("Library/Application Support")]
            directories += fm.urls(for: .cachesDirectory, in: .userDomainMask)
            directories += fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            directories += fm.urls(for: .documentDirectory, in: .userDomainMask)
            for file in try fm.contentsOfDirectory(at: FilePath.sharedDirectory, includingPropertiesForKeys: nil)
                where file.lastPathComponent != "Library" && file.lastPathComponent != "device-access.lock"
                    && file.lastPathComponent != ".com.apple.mobile_container_manager.metadata.plist"
                    && !(file.lastPathComponent.hasPrefix("device-access-") && file.pathExtension == "json") {
                try fm.removeItem(at: file)
            }
            for directory in directories where fm.fileExists(atPath: directory.path) { try fm.removeItem(at: directory) }
            try ServiceSetup.apply(crashReportSource: "PrototypeApplication")
            URLCache.shared.removeAllCachedResponses()
            for cookie in HTTPCookieStorage.shared.cookies ?? [] { HTTPCookieStorage.shared.deleteCookie(cookie) }
            if let identifier = Bundle.main.bundleIdentifier { UserDefaults.standard.removePersistentDomain(forName: identifier) }
            UserDefaults(suiteName: AppConfiguration.appGroupID)?.removePersistentDomain(forName: AppConfiguration.appGroupID)
            #if DEBUG && targetEnvironment(simulator)
                if ProcessInfo.processInfo.environment["PROTOTYPE_UI_TESTING"] == "1" {
                    preferences.removePersistentDomain(forName: "PrototypeUITests")
                }
            #endif
            manager = nil
            subscription = PrototypeSubscription()
            subscriptionError = nil
            subscriptionLoading = false
            replacingSubscription = false
            hasSelectedMode = false
            hasInitializedSelection = false
            connectionMode = .vkTurn
            routingMode = .enabled
            retainedModeTitle = nil
            failoverStatus = nil
            connectedAt = nil
            vpnState = .disconnected
            status = "Отключено"
            footprint = "—"
        } catch {
            self.error = String(localized: "Не удалось полностью сбросить приложение: \(error.localizedDescription)")
        }
    }

    func setRoutingMode(_ mode: PrototypeRoutingMode) async {
        guard managersLoaded, !busy, mode != routingMode else { return }
        let generation = connectionGeneration
        busy = true
        error = nil
        defer { busy = false }
        do {
            let state = manager?.connection.status ?? .disconnected
            guard state == .connected || state == .disconnected || state == .invalid else {
                throw NSError(domain: "Prototype", code: 1, userInfo: [NSLocalizedDescriptionKey: "Дождитесь завершения текущего подключения."])
            }
            let route = try prepareRouting(mode)
            let restart = state == .connected
            if restart {
                try await stopForModeChange()
            }
            guard generation == connectionGeneration else { return }
            // The extension also reads this file when VPN is started from system Settings.
            try writeRouting(route)
            routingMode = mode
            preferences.set(mode.rawValue, forKey: "prototype.routing.mode")
            if restart {
                await startConnection()
            }
        } catch {
            VPNDiagnostics.applicationError("change routing mode", error: error)
            self.error = error.localizedDescription
        }
    }

    private func prepareRouting(_ mode: PrototypeRoutingMode) throws -> Data {
        guard let routeURL = Bundle.main.url(forResource: "routing", withExtension: "json") else {
            throw CocoaError(.fileNoSuchFile)
        }
        let rulesDirectory = FilePath.prototypeRuleSetDirectory.appendingPathComponent("Initial", isDirectory: true)
        let source = try Data(contentsOf: routeURL)
        let route = try PrototypeRouting.route(from: source, mode: mode, initialDirectory: rulesDirectory)
        struct Routing: Decodable {
            struct RuleSet: Decodable { let tag: String }
            let ruleSet: [RuleSet]
            enum CodingKeys: String, CodingKey { case ruleSet = "rule_set" }
        }
        let routing = try JSONDecoder().decode(Routing.self, from: route)
        try FileManager.default.createDirectory(at: rulesDirectory, withIntermediateDirectories: true)
        for rule in routing.ruleSet {
            guard let resource = Bundle.main.url(forResource: rule.tag, withExtension: "srs", subdirectory: "RuleSets")
                ?? Bundle.main.url(forResource: rule.tag, withExtension: "srs") else { throw CocoaError(.fileNoSuchFile) }
            try Data(contentsOf: resource).write(to: rulesDirectory.appendingPathComponent(rule.tag + ".srs"), options: .atomic)
        }
        return route
    }

    private func writeRouting(_ route: Data) throws {
        try FileManager.default.createDirectory(at: FilePath.sharedDirectory, withIntermediateDirectories: true)
        try route.write(to: FilePath.sharedDirectory.appendingPathComponent("prototype-routing.json"),
                        options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    func switchConnection(to mode: PrototypeConnectionMode) async {
        guard managersLoaded, !busy, mode != connectionMode else { return }
        guard isAvailable(mode) else {
            error = "Импортируйте конфигурацию для выбранного режима."
            return
        }
        let generation = connectionGeneration
        busy = true
        error = nil
        defer { busy = false }
        do {
            let state = manager?.connection.status ?? .disconnected
            guard state == .connected || state == .disconnected || state == .invalid else {
                throw NSError(domain: "Prototype", code: 1, userInfo: [NSLocalizedDescriptionKey: "Дождитесь завершения текущего подключения."])
            }
            let restart = state == .connected
            if restart {
                try await stopForModeChange()
            }
            guard generation == connectionGeneration else { return }
            guard isAvailable(mode) else { throw PrototypeSubscriptionError.missingConfiguration }
            connectionMode = mode
            hasSelectedMode = true
            preferences.set(mode.rawValue, forKey: "prototype.connection.mode")
            if restart {
                await startConnection()
            }
        } catch {
            VPNDiagnostics.applicationError("change VPN mode", error: error)
            self.error = error.localizedDescription
        }
    }

    private func stopForModeChange() async throws {
        VPNDiagnostics.expectStop()
        VPNDiagnostics.app("stop requested to change mode/routing")
        manager?.connection.stopVPNTunnel()
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while let state = manager?.connection.status, state != .disconnected, state != .invalid {
            guard ContinuousClock.now < deadline else {
                throw NSError(domain: "Prototype", code: 2, userInfo: [NSLocalizedDescriptionKey: "VPN не отключился за 15 секунд. Повторите переключение."])
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        try Task.checkCancellation()
    }

    func start() async {
        guard !busy else { return }
        await startConnection()
    }

    private func startConnection() async {
        VPNDiagnostics.app("user start requested mode=\(connectionMode.rawValue)")
        let generation = connectionGeneration
        busy = true; error = nil
        defer { busy = false }
        do {
            try ensureStopped()
            guard hasSelectedMode, !replacingSubscription, isAvailable(connectionMode) else { throw PrototypeSubscriptionError.missingConfiguration }
            try writeRouting(prepareRouting(routingMode))
            let directory = FilePath.sharedDirectory
            footprint = "—"
            let statusURL = directory.appendingPathComponent("prototype-status.json")
            if FileManager.default.fileExists(atPath: statusURL.path) {
                try FileManager.default.removeItem(at: statusURL)
            }
            try removeRuntimeVLESS()
            try deviceAccessStore.withLock { try VKTurnConfigurationStore.clear() }
            if connectionMode == .vless {
                try subscription.validateVLESS()
                let node: Data
                if let provisioning = subscription.vlessProvisioning, provisioning.isAvailable {
                    node = try JSONEncoder().encode(provisioning)
                } else if let outbound = subscription.vlessOutbound {
                    node = outbound
                } else {
                    throw PrototypeSubscriptionError.missingConfiguration
                }
                try node.write(to: directory.appendingPathComponent("prototype-vless.json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            } else if let link = subscription.vkTurnLink {
                try deviceAccessStore.withAllowedWDTT(source: subscription.sourceURL) {
                    try VKTurnConfigurationStore.save(VKTurnConfiguration.importLink(link))
                }
            }
            let manager = manager ?? NETunnelProviderManager()
            let configuration = NETunnelProviderProtocol()
            configuration.providerBundleIdentifier = AppConfiguration.extensionBundleID
            configuration.serverAddress = "vipin"
            configuration.providerConfiguration = ["connections": connections, "mode": connectionMode.rawValue]
            manager.protocolConfiguration = configuration
            manager.localizedDescription = "vipin"
            manager.isEnabled = true
            try await manager.saveToPreferences()
            try await manager.loadFromPreferences()
            self.manager = manager
            guard generation == connectionGeneration else { return }
            guard isAvailable(connectionMode) else { throw PrototypeSubscriptionError.missingConfiguration }
            try manager.connection.startVPNTunnel()
        } catch {
            VPNDiagnostics.applicationError("start VPN", error: error)
            self.error = error.localizedDescription
        }
    }

    func stop() {
        VPNDiagnostics.expectStop()
        VPNDiagnostics.app("user stop requested")
        connectionGeneration &+= 1
        manager?.connection.stopVPNTunnel()
    }

    func refresh() async {
        guard !resetting else { return }
        #if DEBUG
            defer { PrototypeNetworkAcceptanceDiagnostics.export() }
        #endif
        footprint = "—"
        failoverStatus = nil
        #if DEBUG && targetEnvironment(simulator)
            if ProcessInfo.processInfo.environment["PROTOTYPE_UI_CONNECTED"] == "1" {
                vpnState = .connected
                status = ProcessInfo.processInfo.environment["PROTOTYPE_UI_STATUS"] ?? "Подключено"
                if let snapshot = ProcessInfo.processInfo.environment["PROTOTYPE_UI_FAILOVER"] {
                    failoverStatus = try? JSONDecoder().decode(PriorityFailoverStatus.self, from: Data(snapshot.utf8))
                }
                return
            }
        #endif
        guard let manager else { return }
        vpnState = manager.connection.status
        connectedAt = manager.connection.connectedDate
        switch manager.connection.status {
        case .connected: status = String(localized: "Проверка соединения…")
        case .connecting: status = "Подключение…"
        case .disconnecting: status = "Отключение…"
        case .reasserting: status = "Восстановление…"
        default: status = "Отключено"
        }
        let directory = FilePath.sharedDirectory
        if let data = try? Data(contentsOf: directory.appendingPathComponent("prototype-status.json")) {
            struct CaptureStatus: Decodable {
                let footprintBytes: UInt64
                let phase: String
                let error: String?
                let updatedAt: Date
                let failover: PriorityFailoverStatus?
                let health: Bool?
                let healthUpdatedAt: Date?
            }
            if let capture = try? JSONDecoder().decode(CaptureStatus.self, from: data) {
                if manager.connection.status != .disconnected, manager.connection.status != .invalid,
                   (0 ... 5).contains(Date().timeIntervalSince(capture.updatedAt)),
                   connectedAt.map({ capture.updatedAt >= $0 }) ?? true
                {
                    footprint = String(format: "%.1f МиБ", Double(capture.footprintBytes) / 1_048_576)
                    if connectionMode == .vless, capture.phase.hasPrefix("vless"),
                       manager.connection.status != .disconnecting, capture.failover?.mode != "disabled"
                    {
                        failoverStatus = capture.failover
                    }
                    if manager.connection.status == .connected,
                       ["vless", "combined"].contains(capture.phase),
                       let healthy = capture.health, let checkedAt = capture.healthUpdatedAt,
                       (0 ... 20).contains(Date().timeIntervalSince(checkedAt)),
                       connectedAt.map({ checkedAt >= $0 }) ?? true
                    {
                        status = healthy ? String(localized: "Подключено") : String(localized: "Сервер недоступен")
                    }
                    if manager.connection.status == .connected, capture.phase == "vless", capture.failover?.allDown == true {
                        status = String(localized: "Туннель поднят · все выходы недоступны")
                    }
                }
                if let message = capture.error {
                    error = message
                }
            }
        }
    }
}
