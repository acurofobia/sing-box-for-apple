#if os(iOS)
    import Combine
    import Library
    import NetworkExtension
    import SwiftUI

    @MainActor
    public struct SubscriptionDashboardView<Details: View>: View {
        @EnvironmentObject private var environments: ExtensionEnvironments
        @ObservedObject private var subscription: ManagedSubscriptionViewModel
        @ObservedObject private var internet = InternetAvailability.shared
        @State private var connectionStatus: NEVPNStatus = .invalid
        @State private var showDetails = false
        @State private var showSettings = false
        @State private var switching = false
        @State private var alert: AlertState?
        private let details: Details

        public init(subscription: ManagedSubscriptionViewModel = .shared, @ViewBuilder details: () -> Details) {
            self.subscription = subscription
            self.details = details()
        }

        public var body: some View {
            ScrollView {
                VStack(spacing: 20) {
                    if !environments.extensionProfileLoading, environments.extensionProfile == nil {
                        InstallProfileButton { await environments.reload() }
                    }
                    Text(vpnStatus).font(.headline).accessibilityIdentifier("subscription.vpnStatus")
                    Button {
                        Task { await toggleConnection() }
                    } label: {
                        Label(isConnected ? "Отключить" : "Подключить", systemImage: "power")
                            .font(.title2.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 100)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(switching || environments.extensionProfileLoading || environments.extensionProfile == nil ||
                              (!isConnected && subscription.snapshot == nil) || !isSwitchable)
                    .accessibilityIdentifier("subscription.connect")
                    Text(internet.status.title)
                        .foregroundStyle(internet.status == .available ? .green : .secondary)
                        .accessibilityIdentifier("subscription.internetStatus")
                    DashboardCardView(title: "Подписка") {
                        VStack(alignment: .leading, spacing: 8) {
                            if let snapshot = subscription.snapshot {
                                Text(snapshot.planName).font(.headline).accessibilityIdentifier("subscription.plan")
                                Text("Осталось дней: \(snapshot.remainingDays)").accessibilityIdentifier("subscription.days")
                                Text("Обновлено: \(snapshot.fetchedAt.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.footnote).foregroundStyle(.secondary)
                                if let warning = snapshot.warning { Text(warning).foregroundStyle(.orange) }
                            } else {
                                Text("Добавьте ссылку подписки для подключения.")
                            }
                            if let error = subscription.errorMessage {
                                Text(error).font(.footnote).foregroundStyle(.red).accessibilityIdentifier("subscription.error")
                            }
                            if let error = environments.extensionProfile?.startupError {
                                Text("Последняя ошибка подключения: \(error)").font(.footnote).foregroundStyle(.red)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    HStack {
                        Button {
                            Task {
                                _ = await subscription.refresh()
                                environments.emptyProfiles = subscription.snapshot == nil
                                environments.profileUpdate.send()
                            }
                        } label: {
                            Label(subscription.isRefreshing ? "Обновление…" : "Обновить", systemImage: "arrow.clockwise")
                        }
                        .disabled(subscription.isRefreshing || subscription.snapshot == nil)
                        .accessibilityIdentifier("subscription.refresh")
                        Spacer()
                        Button("Подробнее") { showDetails = true }
                            .accessibilityIdentifier("subscription.details")
                    }
                    Button(subscription.snapshot == nil ? "Добавить подписку" : "Изменить ссылку подписки") { showSettings = true }
                        .accessibilityIdentifier("subscription.settings")
                }.padding()
            }
            .onReceive(environments.extensionProfile?.$status.eraseToAnyPublisher() ?? Just(.invalid).eraseToAnyPublisher()) { status in
                // Recreated publishers replay their value when the view updates.
                guard connectionStatus != status else { return }
                connectionStatus = status
                internet.check()
            }
            .alert($alert)
            .sheet(isPresented: $showSettings) {
                NavigationSheet(title: "Подписка") { SubscriptionSettingsView(subscription: subscription).environmentObject(environments) }
            }
            .sheet(isPresented: $showDetails) {
                NavigationSheet(title: "Подробнее") { details.environmentObject(environments) }
            }
        }

        private var isConnected: Bool { connectionStatus.isConnected }
        private var isSwitchable: Bool {
            return connectionStatus == .connected || connectionStatus == .disconnected || connectionStatus == .invalid
        }
        private var vpnStatus: String {
            guard !switching else { return "Подключается…" }
            switch connectionStatus {
            case .connected: return "VPN подключён"
            case .connecting, .reasserting: return "Подключается…"
            case .disconnecting: return "Отключается…"
            default: return "VPN отключён"
            }
        }

        private func toggleConnection() async {
            guard let profile = environments.extensionProfile, !switching else { return }
            switching = true
            defer { switching = false }
            do {
                if profile.status.isConnected { try await profile.stop() } else { try await profile.startManual() }
            } catch {
                profile.recordStartupError(error.localizedDescription)
                alert = AlertState(errorMessage: error.localizedDescription)
            }
        }
    }
#endif
