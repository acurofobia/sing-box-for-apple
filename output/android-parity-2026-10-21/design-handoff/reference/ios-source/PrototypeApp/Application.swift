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
    @Published var error: String?
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
    @Published private(set) var subscriptionError: String?
    @Published private(set) var hasSelectedMode = false
    @Published private(set) var vpnState: NEVPNStatus = .disconnected
    @Published private(set) var connectedAt: Date?
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

    func load() async {
        guard !loaded else { return }
        loaded = true
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
        } catch { self.error = String(localized: "Не удалось загрузить сохранённое состояние приложения.") }
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

    func refreshSubscription() async {
        guard let source = subscription.sourceURL, !store.isLoading else { return }
        await fetchSubscription(source, replacing: false)
    }

    @discardableResult func replaceSubscription(_ source: String) async -> Bool {
        do {
            try ensureStopped()
        } catch {
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

    @discardableResult private func fetchSubscription(_ source: String, replacing: Bool) async -> Bool {
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
            let updated = try await store.update(source, replacing: replacing) {
                if replacing {
                    try self.ensureStopped()
                }
            }
            guard let updated else { return false }
            retainedModeTitle = modeTitle
            subscription = updated
            chooseInitialMode()
            return true
        } catch let issue as PrototypeSubscriptionError {
            subscriptionError = issue.localizedDescription
        } catch is PrototypeUIError {
            subscriptionError = PrototypeUIError.invalidDocument.localizedDescription
        } catch {
            // System/network errors can include the credential-bearing URL.
            subscriptionError = String(localized: "Не удалось обновить подписку. Проверьте сеть и сервер. Сохранённые данные не изменены.")
        }
        return false
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
        } catch { self.error = error.localizedDescription }
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
        } catch { self.error = error.localizedDescription }
    }

    private func stopForModeChange() async throws {
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
            try VKTurnConfigurationStore.clear()
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
                try VKTurnConfigurationStore.save(VKTurnConfiguration.importLink(link))
            }
            let manager = manager ?? NETunnelProviderManager()
            let configuration = NETunnelProviderProtocol()
            configuration.providerBundleIdentifier = AppConfiguration.extensionBundleID
            configuration.serverAddress = "VK TURN routing prototype"
            configuration.providerConfiguration = ["connections": connections, "mode": connectionMode.rawValue]
            manager.protocolConfiguration = configuration
            manager.localizedDescription = "VK TURN Prototype"
            manager.isEnabled = true
            try await manager.saveToPreferences()
            try await manager.loadFromPreferences()
            self.manager = manager
            guard generation == connectionGeneration else { return }
            guard isAvailable(connectionMode) else { throw PrototypeSubscriptionError.missingConfiguration }
            try manager.connection.startVPNTunnel()
        } catch { self.error = error.localizedDescription }
    }

    func stop() {
        connectionGeneration &+= 1
        manager?.connection.stopVPNTunnel()
    }

    func refresh() async {
        footprint = "—"
        #if DEBUG && targetEnvironment(simulator)
            if ProcessInfo.processInfo.environment["PROTOTYPE_UI_CONNECTED"] == "1" {
                vpnState = .connected
                status = "Подключено"
                return
            }
        #endif
        guard let manager else { return }
        vpnState = manager.connection.status
        connectedAt = manager.connection.connectedDate
        switch manager.connection.status {
        case .connected: status = "Подключено"
        case .connecting: status = "Подключение…"
        case .disconnecting: status = "Отключение…"
        case .reasserting: status = "Восстановление…"
        default: status = "Отключено"
        }
        let directory = FilePath.sharedDirectory
        if let data = try? Data(contentsOf: directory.appendingPathComponent("prototype-status.json")) {
            struct Failover: Decodable { let mode: String; let selected: String?; let primaryHealth: String?; let allDown: Bool }
            struct CaptureStatus: Decodable { let footprintBytes: UInt64; let phase: String; let error: String?; let updatedAt: Date; let failover: Failover? }
            if let capture = try? JSONDecoder().decode(CaptureStatus.self, from: data) {
                if manager.connection.status != .disconnected, manager.connection.status != .invalid,
                   Date().timeIntervalSince(capture.updatedAt) <= 5
                {
                    footprint = String(format: "%.1f МиБ", Double(capture.footprintBytes) / 1_048_576)
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
