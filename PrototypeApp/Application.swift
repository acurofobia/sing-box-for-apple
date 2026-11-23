import Library
import Network
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
    @Published private(set) var recovery: Recovery?
    private var recoveryRequest: (source: String, replacing: Bool)?
    private var recoveryTask: Task<Void, Never>?
    private var recoveryCancelled = false
    private var recoveryOfferSequence: UInt64 = 0
    private let journalKey = "prototype.serviceWDTT.pending"
    private var pendingRecovery: RecoveryJournal? {
        get { preferences.data(forKey: journalKey).flatMap { try? JSONDecoder().decode(RecoveryJournal.self, from: $0) } }
        set {
            if let newValue { preferences.set(try? JSONEncoder().encode(newValue), forKey: journalKey) }
            else { preferences.removeObject(forKey: journalKey) }
        }
    }
    @Published var status = "Отключено"
    @Published var error: String? {
        didSet { if let error, error != oldValue { VPNDiagnostics.applicationError(error) } }
    }
    // Reuse the pipeline so SwiftUI does not resubscribe and replay errors on every body update.
    lazy var errorChanges = $error.removeDuplicates()
    @Published var footprint = "—"
    private let connections = 30
    @Published var busy = true
    private var managersLoaded = false
    private var vpnLoadTask: Task<Void, Never>?
    var isCheckingVPN: Bool { !managersLoaded && busy }
    private var startingConnection = false
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
    struct ImportProgress {
        let id = UUID()
        var download = StepState.waiting
        var save = StepState.waiting
        var error: String?
    }

    @Published private(set) var importProgress: ImportProgress?
    @Published private(set) var resetting = false
    @Published private(set) var subscriptionError: String? {
        didSet { if let subscriptionError, subscriptionError != oldValue { VPNDiagnostics.applicationError("subscription: " + subscriptionError) } }
    }
    lazy var subscriptionErrorChanges = $subscriptionError.removeDuplicates()
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
        // The system reply is recorded separately when available. Only gather local crash files for this export.
        recordVPNState(force: true)
        let crashes = CrashReportManager()
        await crashes.refresh()
    }

    func load() async {
        guard !loaded else { return }
        loaded = true
        VPNDiagnostics.app("application loaded \(VPNDiagnostics.environment)")
        busy = true
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
            #if DEBUG && targetEnvironment(simulator)
                if ProcessInfo.processInfo.environment["PROTOTYPE_UI_TESTING"] == "1",
                   ProcessInfo.processInfo.environment["PROTOTYPE_UI_RESET"] == "1"
                {
                    try? FileManager.default.removeItem(at: cacheURL)
                    if ProcessInfo.processInfo.arguments.contains("-UITestIncompatibleSubscription") {
                        let fixture = #"{"sourceURL":"http://localhost:18081/subscription/both","warnings":[],"vlessProvisioning":false}"#
                        try FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try Data(fixture.utf8).write(to: cacheURL, options: .atomic)
                    }
                    hasSelectedMode = false
                }
            #endif
            try store.load()
            subscription = store.snapshot
            // Migrate the old global preference to the currently saved subscription.
            if let scoped = preferences.string(forKey: routingPreferenceKey) {
                routingMode = PrototypeRoutingMode(rawValue: scoped) ?? .enabled
            } else if subscription.sourceURL != nil {
                preferences.set(routingMode.rawValue, forKey: routingPreferenceKey)
            }
            chooseInitialMode()
            VPNDiagnostics.app("saved subscription loaded complete=\(subscription.isComplete)")
        } catch {
            VPNDiagnostics.applicationError("load application state", error: error)
            self.error = String(localized: "Не удалось прочитать сохранённую подписку. Вставьте ссылку ещё раз или откройте «Логи».")
        }
    }

    // Run after the cached interface is visible. iOS may never answer after a failed VPN switch.
    func loadVPN() async {
        if let vpnLoadTask {
            await vpnLoadTask.value
            return
        }
        guard !managersLoaded, !resetting else { return }
        busy = true
        // System discovery belongs to the model even if the view that requested it disappears.
        let task = Task { await loadSystemVPNPreferences() }
        vpnLoadTask = task
        await task.value
    }

    private func loadSystemVPNPreferences() async {
        defer { vpnLoadTask = nil; busy = false }
        do {
            VPNDiagnostics.app("loading system VPN preferences")
            #if !targetEnvironment(simulator)
                let managers = try await loadManagers()
                try Task.checkCancellation()
                manager = managers.first { ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == AppConfiguration.extensionBundleID }
            #endif
            try ServiceSetup.apply(crashReportSource: "PrototypeApplication")
            // Simulator cannot run packet tunnels, but can import and display configurations.
            managersLoaded = true
            if pendingRecovery == nil, let settings = (manager?.protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration,
               manager?.connection.status == .connected || manager?.connection.status == .connecting {
                connectionMode = PrototypeConnectionMode(rawValue: settings["mode"] as? String ?? "") ?? .vkTurn
                hasSelectedMode = true
            }
            refreshVPNState()
            // A subscription refresh may have revoked WDTT while iOS was returning the manager.
            if pendingRecovery == nil {
                await synchronizeDeviceAccess()
            }
            VPNDiagnostics.app("system VPN preferences loaded")
        } catch is CancellationError {
            return
        } catch {
            VPNDiagnostics.applicationError("load system VPN preferences", error: error)
            self.error = String(localized: "Не удалось загрузить настройки VPN из iOS. Сохранённая подписка доступна. Нажмите подключение, чтобы повторить попытку.")
        }
    }

    private func loadManagers() async throws -> [NETunnelProviderManager] {
        try await withVPNPreferenceTimeout { reply in
            NETunnelProviderManager.loadAllFromPreferences { managers, error in reply(managers ?? [], error) }
        }
    }

    private func withVPNPreferenceTimeout<Value: Sendable>(_ request: (@escaping @Sendable (Value, Error?) -> Void) -> Void) async throws -> Value {
        try Task.checkCancellation()
        // A task group would still wait for an unresponsive system callback when cancelled.
        let responses = AsyncThrowingStream<Value, Error> { continuation in
            let timeout = Task {
                do {
                    try await Task.sleep(for: .seconds(5))
                    continuation.finish(throwing: URLError(.timedOut))
                } catch {}
            }
            continuation.onTermination = { _ in timeout.cancel() }
            request { value, error in
                if let error {
                    continuation.finish(throwing: error)
                } else {
                    continuation.yield(value)
                    continuation.finish()
                }
            }
        }
        for try await value in responses {
            try Task.checkCancellation()
            return value
        }
        throw CancellationError()
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
        guard recovery == nil, pendingRecovery == nil, !subscriptionLoading, !resetting, let source = subscription.sourceURL, !store.isLoading else { return }
        await fetchSubscription(source, replacing: false, automatic: !force)
    }

    private func synchronizeDeviceAccess() async {
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
            subscription.vkTurnLink = nil
            subscription.wdttAccessState = decision.state
            try await deviceAccessStore.purgeRuntimeIfDenied(source: source)
            guard !resetting, subscription.sourceURL == source else { return }
            try store.load()
            subscription = store.snapshot
        } catch is CancellationError {
            return
        } catch {
            guard !resetting, subscription.sourceURL == source,
                  (try? deviceAccessStore.decision(forSource: source))?.state.isDenied == true else { return }
            subscriptionError = String(localized: "Доступ отозван. Не удалось полностью удалить сохранённую конфигурацию.")
        }
    }

    @discardableResult func replaceSubscription(_ source: String) async -> Bool {
        guard !resetting, recovery == nil, pendingRecovery == nil, importProgress == nil else { return false }
        let progress = ImportProgress()
        importProgress = progress
        if !managersLoaded { await loadVPN() }
        guard importProgress?.id == progress.id else { return false }
        guard !Task.isCancelled, !resetting, recovery == nil, pendingRecovery == nil else {
            importProgress = nil
            return false
        }
        do {
            try ensureStopped()
        } catch {
            importProgress = nil
            VPNDiagnostics.applicationError("check VPN before replacing subscription", error: error)
            subscriptionError = error.localizedDescription
            return false
        }
        importProgress?.download = .running
        let saved = await fetchSubscription(source.trimmingCharacters(in: .whitespacesAndNewlines), replacing: true) {
            self.importProgress?.download = .done
            self.importProgress?.save = .running
        }
        guard importProgress?.id == progress.id else { return false }
        if !saved, recovery == nil, let subscriptionError {
            if importProgress?.download == .done {
                importProgress?.save = .failed
            } else {
                importProgress?.download = .failed
                importProgress?.save = .skipped
            }
            importProgress?.error = subscriptionError
        } else {
            importProgress = nil
        }
        return saved
    }

    func cancelSubscriptionReplacement() {
        importProgress = nil
        guard replacingSubscription, recovery == nil else { return }
        recoveryOfferSequence &+= 1
        store.cancel()
        replacingSubscription = false
        subscriptionLoading = false
    }

    @discardableResult private func fetchSubscription(_ source: String, replacing: Bool, automatic: Bool = false, service: Bool = false, didDownload: @escaping @MainActor @Sendable () -> Void = {}) async -> Bool {
        let saved = await updateSubscription(source, replacing: replacing, automatic: automatic, service: service, didDownload: didDownload)
        if !service {
            await synchronizeDeviceAccess()
        }
        return saved
    }

    private func updateSubscription(_ source: String, replacing: Bool, automatic: Bool, service: Bool, didDownload: @escaping @MainActor @Sendable () -> Void) async -> Bool {
        recoveryOfferSequence &+= 1
        let sequence = recoveryOfferSequence
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
            #if DEBUG && !targetEnvironment(simulator)
                // Device acceptance exercises real provisioning and tunnels after a controlled initial failure.
                if !automatic, !service, ProcessInfo.processInfo.environment["PROTOTYPE_RECOVERY_SIMULATE_TIMEOUT"] == "1" {
                    throw URLError(.timedOut)
                }
            #endif
            let updated = try await store.update(source, replacing: replacing, automatic: automatic, service: service, didDownload: {
                didDownload()
                if service { self.advanceRecovery(from: .download, to: .save) }
            }, authorizeCommit: {
                if service {
                    guard !self.recoveryCancelled, self.manager?.connection.status == .connected else {
                        throw URLError(.networkConnectionLost)
                    }
                } else if replacing {
                    try self.ensureStopped()
                }
            })
            guard let updated else { return false }
            retainedModeTitle = modeTitle
            let sourceChanged = subscription.sourceURL != updated.sourceURL
            subscription = updated
            if sourceChanged {
                routingMode = PrototypeRoutingMode(rawValue: preferences.string(forKey: routingPreferenceKey) ?? "") ?? .enabled
                preferences.set(routingMode.rawValue, forKey: routingPreferenceKey)
            }
            for warning in updated.warnings { VPNDiagnostics.applicationError("subscription warning: " + warning) }
            chooseInitialMode()
            return true
        } catch let issue as PrototypeSubscriptionError {
            VPNDiagnostics.applicationError("update subscription", error: issue)
            subscriptionError = issue.localizedDescription
        } catch let issue as PrototypeUIError {
            VPNDiagnostics.applicationError("decode subscription UI", error: issue)
            subscriptionError = PrototypeUIError.invalidDocument.localizedDescription
        } catch let issue as URLError {
            let canRetry = !automatic && !service && Self.canRecover(issue.code)
            let online = canRetry ? await Self.hasNetworkPath() : true
            guard sequence == recoveryOfferSequence else { return false }
            if canRetry, online, !Task.isCancelled, !resetting, recovery == nil,
               (URL(string: source)?.scheme?.lowercased() == "https"), PrototypeServiceWDTT.preferred(for: subscription.sourceURL == source ? subscription : nil) != nil {
                recoveryRequest = (source, replacing)
                recovery = Recovery()
            } else {
                subscriptionError = Self.networkMessage(online ? issue.code : .notConnectedToInternet)
            }
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
        recoveryOfferSequence &+= 1
        busy = true
        error = nil
        connectionGeneration &+= 1
        store.cancel()
        defer { busy = false }
        do {
            // Late disconnect replies check cancellation and the connection generation before logging.
            disconnectDiagnosticTask?.cancel()
            disconnectDiagnosticTask = nil
            var managers: [NETunnelProviderManager] = []
            #if !targetEnvironment(simulator)
                // If discovery fails, leave local state intact so the user can retry the reset.
                managers = try await loadManagers().filter {
                    guard let identifier = ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier else { return false }
                    return [AppConfiguration.extensionBundleID, AppConfiguration.vkTurnExtensionBundleID].contains(identifier)
                }
            #endif
            VPNDiagnostics.expectStop()
            // iOS may commit a timed-out write. Rediscover before reusing a profile.
            managersLoaded = false
            for manager in managers {
                manager.isOnDemandEnabled = false
                try await withVPNPreferenceTimeout { reply in
                    manager.saveToPreferences { reply((), $0) }
                }
                manager.connection.stopVPNTunnel()
            }
            let deadline = ContinuousClock.now.advanced(by: .seconds(15))
            while managers.contains(where: { $0.connection.status != .disconnected && $0.connection.status != .invalid }) {
                guard ContinuousClock.now < deadline else {
                    throw NSError(domain: "Prototype", code: 3, userInfo: [NSLocalizedDescriptionKey: "VPN не отключился. Повторите сброс после отключения."])
                }
                try await Task.sleep(for: .milliseconds(100))
            }
            manager = nil
            failoverStatus = nil
            connectedAt = nil
            vpnState = .disconnected
            status = "Отключено"
            footprint = "—"
            for manager in managers {
                try await withVPNPreferenceTimeout { reply in
                    manager.removeFromPreferences { reply((), $0) }
                }
            }
            managersLoaded = true
            try await store.reset()
            subscription = PrototypeSubscription()
            try VKTurnConfigurationStore.clear()
            try await BlockingIO.run { try VPNDiagnostics.reset() }
            let fm = FileManager.default
            var directories = [FilePath.sharedDirectory.appendingPathComponent("Library/Caches"),
                               FilePath.sharedDirectory.appendingPathComponent("Library/Application Support")]
            directories += fm.urls(for: .cachesDirectory, in: .userDomainMask)
            directories += fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            directories += fm.urls(for: .documentDirectory, in: .userDomainMask)
            for file in try fm.contentsOfDirectory(at: FilePath.sharedDirectory, includingPropertiesForKeys: nil)
                where !["Library", "device-access.lock", "device-access-record.lock",
                        ".com.apple.mobile_container_manager.metadata.plist"].contains(file.lastPathComponent)
                    && !(file.lastPathComponent.hasPrefix("device-access-") && file.pathExtension == "json") {
                try fm.removeItem(at: file)
            }
            for directory in directories where fm.fileExists(atPath: directory.path) {
                // iOS owns the container directories and caches such as com.apple.dyld.
                for item in try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
                    if directory.lastPathComponent != "Documents", item.lastPathComponent.hasPrefix("com.apple.") { continue }
                    try fm.removeItem(at: item)
                }
            }
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
            subscription = PrototypeSubscription()
            subscriptionError = nil
            subscriptionLoading = false
            replacingSubscription = false
            hasSelectedMode = false
            hasInitializedSelection = false
            connectionMode = .vkTurn
            routingMode = .enabled
            retainedModeTitle = nil
            resetting = false
        } catch {
            resetting = false
            if manager != nil {
                refreshVPNState()
            }
            self.error = String(localized: "Не удалось полностью сбросить приложение: \(error.localizedDescription)")
        }
    }

    private var routingPreferenceKey: String {
        guard let source = subscription.sourceURL else { return "prototype.routing.mode" }
        return "prototype.routing.mode." + PrototypeRouting.sourceID(source)
    }

    func setRoutingMode(_ mode: PrototypeRoutingMode) async {
        guard !busy, mode != routingMode else { return }
        if !managersLoaded { await loadVPN() }
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
            preferences.set(mode.rawValue, forKey: routingPreferenceKey)
            if restart {
                await startConnection()
            }
        } catch {
            VPNDiagnostics.applicationError("change routing mode", error: error)
            self.error = error.localizedDescription
        }
    }

    private func prepareRouting(_ mode: PrototypeRoutingMode) throws -> Data {
        guard let source = subscription.sourceURL else { throw PrototypeSubscriptionError.missingConfiguration }
        return try PrototypeRouting.selection(mode: mode, routing: subscription.routing, source: source, snapshotURL: cacheURL, bundle: .main)
    }

    private func writeRouting(_ route: Data) throws {
        try FileManager.default.createDirectory(at: FilePath.sharedDirectory, withIntermediateDirectories: true)
        try route.write(to: FilePath.sharedDirectory.appendingPathComponent("prototype-routing.json"),
                        options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    func switchConnection(to mode: PrototypeConnectionMode) async {
        guard !busy, !hasSelectedMode || mode != connectionMode else { return }
        if !managersLoaded { await loadVPN() }
        guard managersLoaded, !busy, !hasSelectedMode || mode != connectionMode else { return }
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
            let restart = state == .connecting || state == .connected
            guard restart || state == .disconnected || state == .invalid else {
                throw NSError(domain: "Prototype", code: 1, userInfo: [NSLocalizedDescriptionKey: "Дождитесь завершения текущего подключения."])
            }
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
        guard !busy, !resetting else { return }
        if !managersLoaded {
            await loadVPN()
            guard managersLoaded else { return }
        }
        await startConnection()
    }

    private func startConnection() async {
        guard !startingConnection, !resetting else { return }
        let state = manager?.connection.status ?? .disconnected
        guard state == .disconnected || state == .invalid else { return }
        startingConnection = true
        VPNDiagnostics.app("user start requested mode=\(connectionMode.rawValue)")
        let generation = connectionGeneration
        busy = true; error = nil
        defer { startingConnection = false; busy = false }
        do {
            do {
                let lock = try await deviceAccessStore.acquireLock()
                defer { try? lock.close() }
                guard generation == connectionGeneration, !Task.isCancelled else { return }
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
                } else if let link = subscription.vkTurnLink {
                    try deviceAccessStore.checkWDTTAccessWhileLocked(source: subscription.sourceURL)
                    try VKTurnConfigurationStore.save(VKTurnConfiguration.importLink(link))
                }
            }
            let manager = manager ?? NETunnelProviderManager()
            let configuration = NETunnelProviderProtocol()
            configuration.providerBundleIdentifier = AppConfiguration.extensionBundleID
            configuration.serverAddress = "vipin"
            configuration.providerConfiguration = ["connections": connections, "mode": connectionMode.rawValue]
            configuration.providerConfiguration?["routingSource"] = subscription.sourceURL.map(PrototypeRouting.sourceID)
            manager.protocolConfiguration = configuration
            manager.localizedDescription = "vipin"
            manager.isEnabled = true
            try await manager.saveToPreferences()
            try await manager.loadFromPreferences()
            self.manager = manager
            refreshVPNState()
            guard generation == connectionGeneration else { return }
            guard manager.connection.status == .disconnected || manager.connection.status == .invalid else { return }
            guard isAvailable(connectionMode) else { throw PrototypeSubscriptionError.missingConfiguration }
            try manager.connection.startVPNTunnel()
        } catch {
            guard generation == connectionGeneration, !Task.isCancelled else { return }
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

    #if DEBUG && targetEnvironment(simulator)
        private var simulatedVPNState: NEVPNStatus? {
            guard let raw = ProcessInfo.processInfo.environment["PROTOTYPE_UI_VPN_STATE"].flatMap(Int.init),
                  let state = NEVPNStatus(rawValue: raw), state == .connecting || state == .connected else { return nil }
            return state
        }
    #endif

    func refreshVPNState() {
        guard !resetting else { return }
        var state = manager?.connection.status ?? .disconnected
        #if DEBUG && targetEnvironment(simulator)
            state = simulatedVPNState ?? state
        #endif
        if vpnState != state {
            vpnState = state
        }
        let date = manager?.connection.connectedDate
        if connectedAt != date {
            connectedAt = date
        }
        // Also read the last sample on disconnect: it may contain a tunnel startup error.
        refreshExtensionStatus()
    }

    func refreshExtensionStatus() {
        guard !resetting else { return }
        #if DEBUG
            PrototypeNetworkAcceptanceDiagnostics.export()
        #endif
        var nextFootprint = "—"
        var nextFailover: PriorityFailoverStatus?
        var nextStatus: String
        switch vpnState {
        case .connected: nextStatus = String(localized: "Проверка соединения…")
        case .connecting: nextStatus = "Подключение…"
        case .disconnecting: nextStatus = "Отключение…"
        case .reasserting: nextStatus = "Восстановление…"
        default: nextStatus = "Отключено"
        }
        if manager != nil, let data = try? Data(contentsOf: FilePath.sharedDirectory.appendingPathComponent("prototype-status.json")) {
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
                let isRecent = (0 ... 5).contains(Date().timeIntervalSince(capture.updatedAt))
                if canStop, isRecent,
                   connectedAt.map({ capture.updatedAt >= $0 }) ?? true
                {
                    nextFootprint = String(format: "%.1f МиБ", Double(capture.footprintBytes) / 1_048_576)
                    if connectionMode == .vless, capture.phase.hasPrefix("vless"),
                       vpnState != .disconnecting, capture.failover?.mode != "disabled"
                    {
                        nextFailover = capture.failover
                    }
                    if vpnState == .connected,
                       ["vless", "combined"].contains(capture.phase),
                       let healthy = capture.health, let checkedAt = capture.healthUpdatedAt,
                       (0 ... 20).contains(Date().timeIntervalSince(checkedAt)),
                       connectedAt.map({ checkedAt >= $0 }) ?? true
                    {
                        nextStatus = healthy ? String(localized: "Подключено") : String(localized: "Сервер недоступен")
                    }
                    if vpnState == .connected, capture.phase == "vless", capture.failover?.allDown == true {
                        nextStatus = String(localized: "Туннель поднят · все выходы недоступны")
                    }
                }
                if isRecent, let message = capture.error, error != message {
                    error = message
                }
            }
        }
        #if DEBUG && targetEnvironment(simulator)
            if simulatedVPNState != nil {
                nextStatus = ProcessInfo.processInfo.environment["PROTOTYPE_UI_STATUS"] ?? (vpnState == .connecting ? "Подключение…" : "Подключено")
                if let snapshot = ProcessInfo.processInfo.environment["PROTOTYPE_UI_FAILOVER"] {
                    nextFailover = try? JSONDecoder().decode(PriorityFailoverStatus.self, from: Data(snapshot.utf8))
                }
            }
        #endif
        if footprint != nextFootprint {
            footprint = nextFootprint
        }
        if failoverStatus != nextFailover {
            failoverStatus = nextFailover
        }
        if status != nextStatus {
            status = nextStatus
        }
    }
}

extension PrototypeModel {
    enum RecoveryStep: String, CaseIterable {
        case pause = "Отключаем основной VPN"
        case profile = "Добавляем VPN-конфигурацию в iOS"
        case connect = "Подключаем сервисный WDTT"
        case download = "Загружаем подписку"
        case save = "Проверяем и сохраняем"
        case disconnect = "Отключаем сервисный WDTT"
        case restore = "Восстанавливаем основной VPN"
    }

    enum StepState: String {
        case waiting = "Ожидает", running = "Выполняется", done = "Готово"
        case failed = "Ошибка", skipped = "Пропущено", cancelled = "Отменено"
    }

    struct Recovery {
        var states: [RecoveryStep: StepState] = [:]
        var steps: [RecoveryStep] { RecoveryStep.allCases.filter { states[$0] != nil } }
        var result: String?
        var updateOutcome: String?
        var canCancel = false
        var canRetryCleanup = false
        var imported = false
        var offered: Bool { states.isEmpty && result == nil }
    }

    private struct RecoveryJournal: Codable {
        let session: UUID
        let mode: String?
        let routing: String
        let sourceID: String?
        var serviceRequested = false
        var updated = false
    }

    private enum RecoveryError: LocalizedError {
        case profile, connection, timeout, cleanup, unavailable, busy
        var errorDescription: String? {
            switch self {
            case .profile: return String(localized: "Не удалось подготовить VPN-конфигурацию. Повторите попытку и разрешите добавление VPN, если iOS запросит подтверждение.")
            case .connection: return String(localized: "Не удалось подтвердить подключение к VPN.")
            case .timeout: return String(localized: "Истекло время ожидания подключения.")
            case .cleanup: return String(localized: "Не удалось подтвердить отключение сервисного WDTT.")
            case .unavailable: return String(localized: "Прежний режим VPN больше недоступен. Выберите доступный режим.")
            case .busy: return String(localized: "Дождитесь завершения переключения VPN и повторите попытку.")
            }
        }
    }

    static func canRecover(_ code: URLError.Code) -> Bool {
        [.cannotFindHost, .dnsLookupFailed, .cannotConnectToHost, .timedOut, .networkConnectionLost].contains(code)
    }

    private static func networkMessage(_ code: URLError.Code) -> String {
        switch code {
        case .notConnectedToInternet, .dataNotAllowed: return String(localized: "Нет доступа к сети. Проверьте подключение к интернету.")
        case .secureConnectionFailed, .serverCertificateHasBadDate, .serverCertificateUntrusted,
             .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid, .clientCertificateRejected,
             .clientCertificateRequired: return String(localized: "Не удалось установить защищённое соединение. Проверьте сертификат сервера подписки.")
        case .timedOut: return String(localized: "Сервер подписки не ответил вовремя.")
        case .cannotFindHost, .dnsLookupFailed: return String(localized: "Не удалось найти сервер подписки.")
        case .networkConnectionLost: return String(localized: "Соединение с сервером подписки прервалось.")
        default: return String(localized: "Не удалось подключиться к серверу подписки.")
        }
    }

    private static func hasNetworkPath() async -> Bool {
        let monitor = NWPathMonitor()
        let updates = AsyncStream<Bool> { continuation in
            monitor.pathUpdateHandler = { path in
                continuation.yield(path.status != .unsatisfied)
                continuation.finish()
            }
            continuation.onTermination = { _ in monitor.cancel() }
            monitor.start(queue: DispatchQueue(label: "vipin.subscription.network"))
        }
        for await reachable in updates { return reachable }
        return false
    }

    private func advanceRecovery(from: RecoveryStep, to: RecoveryStep) {
        recovery?.states[from] = .done
        recovery?.states[to] = .running
    }

    var canDismissRecovery: Bool { pendingRecovery?.serviceRequested != true }

    var recoveryProfileToStop: NETunnelProviderManager? {
        guard recovery?.canRetryCleanup == true, recovery?.states[.disconnect] == .failed,
              pendingRecovery?.serviceRequested == true, let manager,
              (manager.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == AppConfiguration.extensionBundleID,
              ![.disconnected, .invalid].contains(manager.connection.status) else { return nil }
        return manager
    }

    var recoveryWillPauseVPN: Bool { manager?.connection.status == .connected }

    func dismissRecovery() {
        guard recoveryTask == nil, pendingRecovery?.serviceRequested != true else { return }
        if recovery?.result != nil, pendingRecovery?.serviceRequested == false {
            pendingRecovery = nil
        }
        recoveryRequest = nil
        recovery = nil
    }

    func cancelRecovery() {
        guard recovery?.canCancel == true else { return }
        recoveryCancelled = true
        recovery?.canCancel = false
        if store.isLoading { store.cancel() }
    }

    func startRecovery() {
        guard let request = recoveryRequest, recovery?.offered == true,
              recoveryTask == nil, !resetting else { return }
        recoveryRequest = nil
        recoveryCancelled = false
        recoveryTask = Task { await runRecovery(source: request.source, replacing: request.replacing) }
    }

    private func runRecovery(source: String, replacing: Bool) async {
        defer { recoveryTask = nil }
        if !managersLoaded { await loadVPN() }
        guard managersLoaded, !busy, !store.isLoading, pendingRecovery == nil else {
            recovery?.result = RecoveryError.busy.localizedDescription
            return
        }
        let state = manager?.connection.status ?? .disconnected
        guard [.disconnected, .invalid, .connected].contains(state) else {
            recovery?.result = RecoveryError.busy.localizedDescription
            return
        }
        guard let key = PrototypeServiceWDTT.preferred(for: source == subscription.sourceURL ? subscription : nil),
              var origin = URLComponents(string: source), origin.host != nil else {
            recovery?.result = String(localized: "Ключ сервисного WDTT недоступен.")
            return
        }
        origin.path = ""; origin.query = nil; origin.fragment = nil
        guard let originString = origin.string else { recovery?.result = String(localized: "Некорректная ссылка подписки."); return }
        let activeConfiguration = (manager?.protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration
        let restoreMode = state == .connected ? (activeConfiguration?["mode"] as? String ?? connectionMode.rawValue) : nil
        var journal = RecoveryJournal(session: UUID(), mode: restoreMode, routing: routingMode.rawValue,
                                      sourceID: subscription.sourceURL.map(PrototypeRouting.sourceID))
        pendingRecovery = journal
        let needsProfile = manager?.protocolConfiguration == nil || manager?.isEnabled != true
        let steps = RecoveryStep.allCases.filter {
            switch $0 {
            case .profile: needsProfile
            case .pause, .restore: restoreMode != nil
            default: true
            }
        }
        recovery = Recovery(states: Dictionary(uniqueKeysWithValues: steps.map { ($0, .waiting) }), canCancel: true)
        let firstImport = !subscription.isComplete
        var outcome: String
        do {
            if restoreMode != nil {
                recovery?.states[.pause] = .running
                try await stopForModeChange()
                recovery?.states[.pause] = .done
            }
            try checkRecoveryCancelled()
            if needsProfile { recovery?.states[.profile] = .running }
            let serviceManager = try await managerForRecovery(needsProfile: needsProfile)
            if needsProfile { recovery?.states[.profile] = .done }
            try checkRecoveryCancelled()
            recovery?.states[.connect] = .running
            try ensureStopped()
            journal.serviceRequested = true
            pendingRecovery = journal
            try serviceManager.connection.startVPNTunnel(options: [
                "serviceWDTTLink": key.link as NSString, "serviceWDTTSource": originString as NSString,
                "serviceWDTTSession": journal.session.uuidString as NSString,
            ])
            try await waitForConnection(serviceManager, cancellable: true)
            guard try await serviceSession(serviceManager) == journal.session else { throw RecoveryError.connection }
            try checkRecoveryCancelled()
            advanceRecovery(from: .connect, to: .download)
            let updated = await fetchSubscription(source, replacing: replacing, service: true)
            if !updated {
                try checkRecoveryCancelled()
                throw RecoveryError.connection
            }
            recovery?.states[.save] = .done
            recovery?.imported = firstImport || replacing
            journal.updated = true
            pendingRecovery = journal
            outcome = String(localized: "Подписка обновлена.")
        } catch {
            let active = recovery?.steps.first { recovery?.states[$0] == .running }
            if let active { recovery?.states[active] = recoveryCancelled ? .cancelled : .failed }
            outcome = recoveryCancelled ? String(localized: "Обновление отменено.") : (subscriptionError ?? (error as? RecoveryError)?.localizedDescription ?? String(localized: "Не удалось обновить подписку через сервисный WDTT."))
        }
        recovery?.canCancel = false
        await finishRecovery(journal, outcome: outcome, ownsLiveStart: true)
    }

    private func checkRecoveryCancelled() throws {
        if recoveryCancelled { throw CancellationError() }
    }

    private func managerForRecovery(needsProfile: Bool) async throws -> NETunnelProviderManager {
        let value = manager ?? NETunnelProviderManager()
        if value.protocolConfiguration == nil {
            let configuration = NETunnelProviderProtocol()
            configuration.providerBundleIdentifier = AppConfiguration.extensionBundleID
            configuration.serverAddress = "vipin"
            configuration.providerConfiguration = ["connections": connections, "mode": connectionMode.rawValue]
            value.protocolConfiguration = configuration
            value.localizedDescription = "vipin"
        }
        if needsProfile {
            value.isEnabled = true
            do {
                try await value.saveToPreferences()
                try await value.loadFromPreferences()
            } catch {
                manager = nil
                managersLoaded = false
                throw RecoveryError.profile
            }
        }
        manager = value
        refreshVPNState()
        return value
    }

    private func waitForConnection(_ manager: NETunnelProviderManager, cancellable: Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(135))
        var progressed = false
        while manager.connection.status != .connected {
            if cancellable { try checkRecoveryCancelled() }
            let state = manager.connection.status
            if progressed && (state == .disconnected || state == .invalid) { throw RecoveryError.connection }
            progressed = progressed || state == .connecting || state == .reasserting
            guard ContinuousClock.now < deadline else { throw RecoveryError.timeout }
            try await Task.sleep(for: .milliseconds(150))
        }
    }

    private func serviceSession(_ manager: NETunnelProviderManager) async throws -> UUID? {
        guard let session = manager.connection as? NETunnelProviderSession else { throw RecoveryError.connection }
        let replies = AsyncStream<Data?> { continuation in
            do {
                try session.sendProviderMessage(Data("service-wdtt-session".utf8)) { bytes in
                    continuation.yield(bytes)
                    continuation.finish()
                }
            } catch { continuation.finish() }
            let timeout = Task {
                do { try await Task.sleep(for: .seconds(4)); continuation.finish() } catch {}
            }
            continuation.onTermination = { _ in timeout.cancel() }
        }
        for await reply in replies {
            guard let reply else { break }
            if reply.isEmpty { return nil } // The provider explicitly identifies an ordinary tunnel.
            if let value = String(data: reply, encoding: .utf8), let id = UUID(uuidString: value) { return id }
        }
        throw RecoveryError.connection
    }

    func checkRecoveryTransport() {
        if recovery?.states[.download] == .running, manager?.connection.status != .connected {
            store.cancel()
        }
    }

    func reconcileRecoveryOnActivation() async {
        guard pendingRecovery != nil, recovery == nil, recoveryTask == nil else { return }
        if !managersLoaded { await loadVPN() }
        resumeRecovery()
    }

    func resumeRecovery(stopping confirmedProfile: NETunnelProviderManager? = nil) {
        guard managersLoaded, let journal = pendingRecovery, recoveryTask == nil,
              recovery == nil || recovery?.canRetryCleanup == true else { return }
        if let confirmedProfile, confirmedProfile !== recoveryProfileToStop { return }
        let outcome = recovery?.updateOutcome ?? (journal.updated ? String(localized: "Подписка обновлена.") : String(localized: "Обновление прервано."))
        if recovery == nil { recovery = Recovery() }
        recovery?.result = nil
        recovery?.canRetryCleanup = false
        recoveryTask = Task {
            defer { recoveryTask = nil }
            await finishRecovery(journal, outcome: outcome, ownsLiveStart: false, confirmedProfile: confirmedProfile)
        }
    }

    private func disconnectService(_ session: UUID, ownsLiveStart: Bool, confirmedProfile: NETunnelProviderManager?) async throws {
        if let confirmedProfile, confirmedProfile !== manager { throw RecoveryError.cleanup }
        guard let manager else { return }
        guard (manager.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == AppConfiguration.extensionBundleID
        else { throw RecoveryError.cleanup }
        let state = manager.connection.status
        if state == .disconnected || state == .invalid {
            // A live start can still be pending before iOS reports .connecting.
            if ownsLiveStart, state == .disconnected { manager.connection.stopVPNTunnel() }
            return
        }
        if confirmedProfile == nil, !ownsLiveStart, state == .connecting {
            try await waitForConnection(manager, cancellable: false)
        }
        if confirmedProfile == nil, !(ownsLiveStart && (state == .connecting || state == .disconnecting)) {
            // Settings may already have started an ordinary tunnel on this profile.
            guard try await serviceSession(manager) == session else { return }
        }
        guard self.manager === manager else { throw RecoveryError.cleanup }
        try await stopForModeChange()
        guard [.disconnected, .invalid].contains(manager.connection.status) else { throw RecoveryError.cleanup }
    }

    private func finishRecovery(_ saved: RecoveryJournal, outcome: String, ownsLiveStart: Bool,
                                confirmedProfile: NETunnelProviderManager? = nil) async {
        var journal = saved
        recovery?.updateOutcome = outcome
        recovery?.canRetryCleanup = false
        var result = outcome
        for step in recovery?.steps ?? [] where recovery?.states[step] == .waiting { recovery?.states[step] = .skipped }
        do {
            if journal.serviceRequested {
                recovery?.states[.disconnect] = .running
                try await disconnectService(journal.session, ownsLiveStart: ownsLiveStart, confirmedProfile: confirmedProfile)
                journal.serviceRequested = false
                pendingRecovery = journal
                recovery?.states[.disconnect] = .done
            }
            await synchronizeDeviceAccess()
            if let raw = journal.mode, let mode = PrototypeConnectionMode(rawValue: raw) {
                recovery?.states[.restore] = .running
                guard subscription.sourceURL.map(PrototypeRouting.sourceID) == journal.sourceID,
                      isAvailable(mode) else { throw RecoveryError.unavailable }
                let state = manager?.connection.status ?? .disconnected
                if state == .disconnecting { try await stopForModeChange() }
                if manager?.connection.status != .connected {
                    if [.disconnected, .invalid].contains(manager?.connection.status ?? .disconnected) {
                        connectionMode = mode
                        if let routing = PrototypeRoutingMode(rawValue: journal.routing) { routingMode = routing }
                        await startConnection()
                        if error != nil { throw RecoveryError.connection }
                    }
                    guard let manager else { throw RecoveryError.connection }
                    try await waitForConnection(manager, cancellable: false)
                }
                recovery?.states[.restore] = .done
            }
            pendingRecovery = nil
        } catch {
            let step: RecoveryStep = journal.serviceRequested ? .disconnect : .restore
            recovery?.states[step] = .failed
            if step == .disconnect {
                result += " " + String(localized: "Не удалось подтвердить отключение сервисного WDTT.")
            } else if case RecoveryError.unavailable = error {
                result += " " + String(localized: "Прежний режим VPN больше недоступен.")
                pendingRecovery = nil
            } else { result += " " + String(localized: "Не удалось восстановить основной VPN.") }
            recovery?.canRetryCleanup = pendingRecovery != nil
        }
        recovery?.result = result
        refreshVPNState()
    }
}
