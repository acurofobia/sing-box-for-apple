import Libbox
import Library
import SwiftUI

#if os(iOS)
@MainActor
struct VPNChoiceView: View {
    @EnvironmentObject private var environments: ExtensionEnvironments
    @State private var onlyVKTurn = false
    @State private var link = ""
    @State private var hasConfiguration = false
    @State private var probeOutbound = ""
    @State private var defaultUsable = false
    @State private var candidates: [String] = []
    @State private var alert: AlertState?

    private struct ProbeDescription: Decodable {
        let defaultUsable: Bool
        let candidates: [String]
    }

    var body: some View {
        FormView {
            Section("VK TURN SRTP / WRAP-A") {
                SecureField("vkturnproxy://… или wdtt://…", text: $link)
                    .textContentType(.password)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                Button("Сохранить ссылку") {
                    do {
                        try VKTurnConfigurationStore.save(VKTurnConfiguration.importLink(link))
                        link = ""
                        hasConfiguration = true
                        Task { await updateAvailability() }
                    } catch {
                        alert = AlertState(action: "сохранить VK TURN", error: error)
                    }
                }
                .disabled(link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Text(hasConfiguration ? "Конфигурация сохранена в Keychain" : "Конфигурация не добавлена")
                    .foregroundStyle(.secondary)
            }

            if !onlyVKTurn {
                Section("Проверка sing-box") {
                    if defaultUsable || !candidates.isEmpty {
                        Picker("Проверяемый outbound", selection: $probeOutbound) {
                            if defaultUsable {
                                Text("route.final").tag("")
                            } else {
                                Text("Выберите outbound").tag("")
                            }
                            ForEach(candidates, id: \.self) { tag in
                                Text(tag).tag(tag)
                            }
                        }
                        .onChange(of: probeOutbound) { value in
                            Task { await SharedPreferences.probeOutboundTag.set(value) }
                        }
                    } else {
                        Text("Выберите профиль sing-box с outbound для проверки.")
                            .foregroundStyle(.secondary)
                    }
                    Text("Проверяются gstatic.com и cloudflare.com. Общий предел ожидания — 10 секунд.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Выбор VPN")
        .navigationBarTitleDisplayMode(.inline)
        .alert($alert)
        .task { await load() }
    }

    private func load() async {
        onlyVKTurn = await SharedPreferences.onlyVKTurn.get()
        probeOutbound = await SharedPreferences.probeOutboundTag.get()
        hasConfiguration = (try? VKTurnConfigurationStore.load()) != nil
        await updateAvailability()
        let id = await SharedPreferences.selectedProfileID.get()
        guard let profile = try? await ProfileManager.get(id),
              let content = try? await profile.readAsync() else { return }
        do {
            let description = try await Task.detached(priority: .userInitiated) {
                var error: NSError?
                let result = LibboxProbeOutbounds(content, &error)
                if let error { throw error }
                guard let data = result.data(using: .utf8) else { throw VKTurnError.invalidField }
                return try JSONDecoder().decode(ProbeDescription.self, from: data)
            }.value
            defaultUsable = description.defaultUsable
            candidates = description.candidates
            if !probeOutbound.isEmpty, !candidates.contains(probeOutbound) {
                probeOutbound = ""
                await SharedPreferences.probeOutboundTag.set("")
            }
        } catch {
            alert = AlertState(action: "прочитать outbound профиля", error: error)
        }
    }

    private func updateAvailability() async {
        let profiles = try? await ProfileManager.list()
        let hasSingProfile = profiles?.isEmpty == false
        environments.emptyProfiles = !hasSingProfile && !(onlyVKTurn && hasConfiguration)
    }
}
#endif
