#if os(iOS)
    import Combine
    import Library
    import NetworkExtension
    import SwiftUI
    import UIKit

    @MainActor
    public struct SubscriptionSettingsView: View {
        @EnvironmentObject private var environments: ExtensionEnvironments
        @ObservedObject private var subscription: ManagedSubscriptionViewModel
        @State private var connectionStatus: NEVPNStatus = .invalid
        @State private var sourceURL = ""

        public init(subscription: ManagedSubscriptionViewModel = .shared) { self.subscription = subscription }

        public var body: some View {
            FormView {
                Section("Единая подписка") {
                    SecureField("http://mac.local:8080/subscription/…", text: $sourceURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("subscription.url")
                    Button(subscription.isRefreshing ? "Обновление…" : "Сохранить и обновить") {
                        Task {
                            if await subscription.refresh(sourceURL: sourceURL.trimmingCharacters(in: .whitespacesAndNewlines)) {
                                environments.emptyProfiles = false
                                environments.profileUpdate.send()
                            }
                        }
                    }
                    .disabled(!canReplace || sourceURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || subscription.isRefreshing)
                    .accessibilityIdentifier("subscription.save")
                    if !canReplace {
                        Text("Остановите VPN перед заменой ссылки.").foregroundStyle(.secondary)
                    }
                    Text("Все параметры подключения загружаются по этой ссылке. Вне домашней сети используется сохранённая подписка.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if let error = subscription.errorMessage {
                    Section {
                        Text(error).foregroundStyle(.red)
                        Button("Открыть настройки iOS") {
                            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                        }
                    }
                }
            }
            .navigationTitle("Подписка")
            .onReceive(environments.extensionProfile?.$status.eraseToAnyPublisher() ?? Just(.invalid).eraseToAnyPublisher()) { connectionStatus = $0 }
            .onAppear { sourceURL = subscription.snapshot?.sourceURL ?? "" }
        }

        private var canReplace: Bool {
            return connectionStatus == .disconnected || connectionStatus == .invalid
        }
    }
#endif
