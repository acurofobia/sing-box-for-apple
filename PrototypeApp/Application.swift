import Library
import NetworkExtension
import SwiftUI
import UniformTypeIdentifiers

enum PrototypeConnectionMode: String, CaseIterable {
    case vkTurn = "vk-turn"
    case vless

    var title: String { self == .vless ? "VLESS" : "VK TURN" }
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
    var hasLink: Bool { subscription.vkTurnLink != nil }
    var hasVLESS: Bool { subscription.vlessOutbound != nil }
    func isAvailable(_ mode: PrototypeConnectionMode) -> Bool { mode == .vless ? hasVLESS : hasLink }
    @Published var exportURL: URL?
    @Published private(set) var connectionMode: PrototypeConnectionMode = .vkTurn
    @Published private(set) var routingMode: PrototypeRoutingMode = .enabled
    private var manager: NETunnelProviderManager?

    func load() async {
        busy = true
        defer { busy = false }
        connectionMode = PrototypeConnectionMode(rawValue: UserDefaults.standard.string(forKey: "prototype.connection.mode") ?? "") ?? .vkTurn
        routingMode = PrototypeRoutingMode(rawValue: UserDefaults.standard.string(forKey: "prototype.routing.mode") ?? "") ?? .enabled
        do {
            #if !targetEnvironment(simulator)
                let managers = try await NETunnelProviderManager.loadAllFromPreferences()
                manager = managers.first { ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == AppConfiguration.extensionBundleID }
            #endif
            // Simulator cannot run packet tunnels, but can import and display configurations.
            managersLoaded = true
            try ServiceSetup.apply(crashReportSource: "PrototypeApplication")
            let cache = FilePath.sharedDirectory.appendingPathComponent("prototype-subscription.json")
            if FileManager.default.fileExists(atPath: cache.path) {
                subscription = try JSONDecoder().decode(PrototypeSubscription.self, from: Data(contentsOf: cache))
            } else if manager?.connection.status == nil || manager?.connection.status == .disconnected || manager?.connection.status == .invalid {
                // Discard credentials injected by older prototype builds.
                try VKTurnConfigurationStore.clear()
                try removeRuntimeVLESS()
                let seed = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("prototype-settings.json")
                if FileManager.default.fileExists(atPath: seed.path) { try FileManager.default.removeItem(at: seed) }
            }
            if let settings = (manager?.protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration {
                if manager?.connection.status == .connected || manager?.connection.status == .connecting {
                    connectionMode = PrototypeConnectionMode(rawValue: settings["mode"] as? String ?? "") ?? .vkTurn
                }
            }
            await refresh()
        } catch { self.error = error.localizedDescription }
    }

    private func ensureStopped() throws {
        guard managersLoaded else { throw PrototypeSubscriptionError.notReady }
        let state = manager?.connection.status ?? .disconnected
        guard state == .disconnected || state == .invalid else { throw PrototypeSubscriptionError.stopBeforeImport }
    }

    private func removeRuntimeVLESS() throws {
        let url = FilePath.sharedDirectory.appendingPathComponent("prototype-vless.json")
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }

    private func save(_ updated: PrototypeSubscription) throws {
        try ensureStopped()
        let directory = FilePath.sharedDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try removeRuntimeVLESS()
        try VKTurnConfigurationStore.clear()
        try JSONEncoder().encode(updated).write(to: directory.appendingPathComponent("prototype-subscription.json"),
                                               options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        subscription = updated
        if !isAvailable(connectionMode) {
            if hasVLESS { connectionMode = .vless } else if hasLink { connectionMode = .vkTurn }
            UserDefaults.standard.set(connectionMode.rawValue, forKey: "prototype.connection.mode")
        }
        error = nil
    }

    func saveLink(_ text: String) throws {
        _ = try VKTurnConfiguration.importLink(text)
        var updated = subscription
        updated.sourceURL = nil
        updated.singBoxURL = nil
        updated.warnings = []
        updated.vkTurnLink = text.trimmingCharacters(in: .whitespacesAndNewlines)
        try save(updated)
    }

    func importVLESS(_ data: Data) throws {
        guard let node = try PrototypeSubscription.extractVLESS(data) else { throw PrototypeSubscriptionError.invalidVLESS }
        var updated = subscription
        updated.sourceURL = nil
        updated.singBoxURL = nil
        updated.warnings = []
        updated.vlessOutbound = node
        try save(updated)
    }

    func clearConfigurations() throws { try save(PrototypeSubscription()) }

    func updateSubscription(_ text: String) async {
        guard !busy else { return }
        busy = true
        error = nil
        defer { busy = false }
        do {
            try ensureStopped()
            let updated = try await PrototypeSubscription.download(text.trimmingCharacters(in: .whitespacesAndNewlines))
            try save(updated)
        } catch let issue as PrototypeSubscriptionError {
            error = issue.localizedDescription
        } catch {
            // URLSession errors may contain the credential-bearing subscription URL.
            self.error = "Не удалось обновить подписку. Проверьте сеть и сервер. Сохранённые конфиги не изменены."
        }
    }

    func setRoutingMode(_ mode: PrototypeRoutingMode) async {
        guard managersLoaded, !busy, mode != routingMode else { return }
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
            if restart { try await stopForModeChange() }
            // The extension also reads this file when VPN is started from system Settings.
            try writeRouting(route)
            routingMode = mode
            UserDefaults.standard.set(mode.rawValue, forKey: "prototype.routing.mode")
            if restart { await start() }
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
        guard mode != .vkTurn || hasLink, mode != .vless || hasVLESS else {
            error = "Импортируйте конфигурацию для выбранного режима."
            return
        }
        busy = true
        error = nil
        defer { busy = false }
        do {
            let state = manager?.connection.status ?? .disconnected
            guard state == .connected || state == .disconnected || state == .invalid else {
                throw NSError(domain: "Prototype", code: 1, userInfo: [NSLocalizedDescriptionKey: "Дождитесь завершения текущего подключения."])
            }
            let restart = state == .connected
            if restart { try await stopForModeChange() }
            connectionMode = mode
            UserDefaults.standard.set(mode.rawValue, forKey: "prototype.connection.mode")
            if restart { await start() }
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
        busy = true; error = nil; exportURL = nil
        defer { busy = false }
        do {
            try ensureStopped()
            guard isAvailable(connectionMode) else { throw PrototypeSubscriptionError.missingConfiguration }
            try writeRouting(prepareRouting(routingMode))
            let directory = FilePath.sharedDirectory
            footprint = "—"
            let statusURL = directory.appendingPathComponent("prototype-status.json")
            if FileManager.default.fileExists(atPath: statusURL.path) {
                try FileManager.default.removeItem(at: statusURL)
            }
            if connectionMode == .vless {
                guard let node = subscription.vlessOutbound else { throw PrototypeSubscriptionError.missingConfiguration }
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
            try manager.connection.startVPNTunnel()
        } catch { self.error = error.localizedDescription }
    }

    func stop() {
        manager?.connection.stopVPNTunnel()
    }

    func refresh() async {
        footprint = "—"
        guard let manager else { return }
        switch manager.connection.status {
        case .connected: status = "Подключено"
        case .connecting: status = "Подключение…"
        case .disconnecting: status = "Отключение…"
        case .reasserting: status = "Восстановление…"
        default: status = "Отключено"
        }
        let directory = FilePath.sharedDirectory
        if let data = try? Data(contentsOf: directory.appendingPathComponent("prototype-status.json")) {
            struct CaptureStatus: Decodable { let footprintBytes: UInt64; let phase: String; let error: String?; let updatedAt: Date }
            if let capture = try? JSONDecoder().decode(CaptureStatus.self, from: data) {
                if manager.connection.status != .disconnected, manager.connection.status != .invalid,
                   Date().timeIntervalSince(capture.updatedAt) <= 5 {
                    footprint = String(format: "%.1f МиБ", Double(capture.footprintBytes) / 1_048_576)
                }
                if let message = capture.error {
                    error = message
                }
            }
        }
    }

    func exportCapture() {
        do {
            let directory = FilePath.sharedDirectory.appendingPathComponent("Library/Caches/Prototype")
            let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])
                .filter { $0.pathExtension == "csv" }
                .sorted { $0.lastPathComponent > $1.lastPathComponent }
            guard let latest = files.first else { throw CocoaError(.fileNoSuchFile) }
            let destination = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent(latest.lastPathComponent)
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: latest, to: destination)
            exportURL = destination
        } catch { self.error = error.localizedDescription }
    }
}

struct PrototypeView: View {
    @StateObject private var model = PrototypeModel()
    @State private var link = ""
    @State private var showLinks = false
    @State private var subscriptionURL = ""
    @State private var jsonText = ""
    @State private var showJSON = false
    @State private var showFileImporter = false
    private enum Input { case subscription, vkTurn }
    @FocusState private var focusedInput: Input?
    var body: some View {
        TabView {
            vpnView
                .tabItem { Label("VPN", systemImage: "shield.lefthalf.filled") }
            PrototypeRoutingView(model: model)
                .tabItem { Label("Роутинги", systemImage: "arrow.triangle.branch") }
        }
        .task {
            await model.load()
            subscriptionURL = model.subscription.sourceURL ?? ""
            while !Task.isCancelled {
                await model.refresh()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private var vpnView: some View {
        NavigationStack {
            Form {
                Section("Режим подключения") {
                    Picker("Режим подключения", selection: Binding(
                        get: { model.connectionMode },
                        set: { mode in Task { await model.switchConnection(to: mode) } }
                    )) {
                        ForEach(PrototypeConnectionMode.allCases, id: \.self) { mode in
                            if #available(iOS 17.0, *) {
                                Text(mode.title).tag(mode)
                                    .selectionDisabled(!model.isAvailable(mode))
                            } else {
                                Text(mode.title).tag(mode)
                                    .disabled(!model.isAvailable(mode))
                            }
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("prototype.mode")
                    .disabled(model.busy || (!model.hasLink && !model.hasVLESS) ||
                        (model.status != "Отключено" && model.status != "Подключено"))
                }
                Section("Подписка") {
                    TextField("http(s)://…/subscription/…", text: $subscriptionURL)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .keyboardType(.URL).submitLabel(.done)
                        .focused($focusedInput, equals: .subscription)
                        .onSubmit { focusedInput = nil }
                        .accessibilityIdentifier("prototype.subscription.url")
                    Button("Получить конфиги") {
                        let source = subscriptionURL
                        focusedInput = nil
                        Task { await model.updateSubscription(source) }
                    }
                    .accessibilityIdentifier("prototype.subscription.fetch")
                    .disabled(subscriptionURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.busy || model.status != "Отключено")
                    ForEach(model.subscription.warnings, id: \.self) { Text($0).foregroundStyle(.orange) }
                    Button("Удалить конфиги", role: .destructive) {
                        do { try model.clearConfigurations(); subscriptionURL = ""; link = ""; jsonText = "" } catch { model.error = error.localizedDescription }
                    }
                    .accessibilityIdentifier("prototype.configs.clear")
                    .disabled(model.busy || model.status != "Отключено")
                }
                Section("VLESS") {
                    Text(model.hasVLESS ? "Конфигурация импортирована" : "Конфигурация отсутствует")
                    Button("Импортировать JSON-файл") { showFileImporter = true }
                        .disabled(model.busy || model.status != "Отключено")
                    Button("Вставить JSON") { showJSON = true }
                        .accessibilityIdentifier("prototype.vless.paste")
                        .disabled(model.busy || model.status != "Отключено")
                }
                Section("VK TURN") {
                    Group {
                        if showLinks { TextField("wdtt://… или vkturnproxy://…", text: $link) } else { SecureField("wdtt://… или vkturnproxy://…", text: $link) }
                    }
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .keyboardType(.URL).submitLabel(.done)
                        .focused($focusedInput, equals: .vkTurn)
                        .onSubmit { focusedInput = nil }
                    Button(model.hasLink ? "Заменить ссылку" : "Сохранить ссылку") {
                        let importedLink = link
                        focusedInput = nil
                        do {
                            try model.saveLink(importedLink)
                            link = ""
                            model.error = nil
                        } catch {
                            model.error = error.localizedDescription
                        }
                    }.disabled(link.isEmpty || model.busy || model.status != "Отключено")
                        .accessibilityIdentifier("prototype.vk.save")
                }
                Section("Состояние") {
                    LabeledContent("VPN", value: model.status)
                        .accessibilityIdentifier("prototype.status")
                        .accessibilityValue(model.status)
                    LabeledContent("Память расширения", value: model.footprint)
                    Button("Подключить") { Task { await model.start() } }
                        .accessibilityIdentifier("prototype.start")
                        .disabled(model.busy || model.status != "Отключено" || !model.isAvailable(model.connectionMode))
                    Button("Отключить") { model.stop() }
                        .accessibilityIdentifier("prototype.stop")
                        .disabled(model.busy || model.status == "Отключено")
                    Button("Подготовить отчёт памяти") { model.exportCapture() }
                    if let url = model.exportURL {
                        ShareLink("Экспортировать CSV", item: url)
                    }
                }
                if let error = model.error {
                    Section("Ошибка") { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                }
            }.navigationTitle("VPN")
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { showLinks.toggle() } label: {
                            Label(showLinks ? "Скрыть ссылки" : "Показать ссылки", systemImage: showLinks ? "eye.slash" : "eye")
                        }
                        .accessibilityIdentifier("prototype.links.reveal")
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        NavigationLink {
                            PrototypeLogView(model: model)
                        } label: {
                            Label("Логи", systemImage: "text.alignleft")
                        }
                        .accessibilityIdentifier("prototype.logs")
                    }
                }
        }
        .sheet(isPresented: $showJSON) {
            NavigationStack {
                TextEditor(text: $jsonText)
                    .font(.system(.caption, design: .monospaced))
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier("prototype.vless.json")
                    .padding()
                    .navigationTitle("Импорт VLESS")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("Отмена") { showJSON = false; jsonText = "" } }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Импортировать") {
                                do {
                                    try model.importVLESS(Data(jsonText.utf8))
                                    jsonText = ""
                                    showJSON = false
                                } catch {
                                    model.error = PrototypeSubscriptionError.invalidVLESS.localizedDescription
                                    showJSON = false
                                    jsonText = ""
                                }
                            }.disabled(jsonText.isEmpty)
                        }
                    }
            }
        }
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.json]) { result in
            do {
                let url = try result.get()
                let accessed = url.startAccessingSecurityScopedResource()
                defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                try model.importVLESS(Data(contentsOf: url))
            } catch { model.error = PrototypeSubscriptionError.invalidVLESS.localizedDescription }
        }
    }
}
