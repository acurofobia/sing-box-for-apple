import Library
import SwiftUI

struct PrototypeRoutingView: View {
    @ObservedObject var model: PrototypeModel

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Роутинг", selection: Binding(
                        get: { model.routingMode },
                        set: { mode in Task { await model.setRoutingMode(mode) } }
                    )) {
                        ForEach(PrototypeRoutingMode.allCases, id: \.self) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("prototype.routing.mode")
                    .disabled(model.busy)
                    Text(model.routingMode == .enabled
                        ? "Трафик распределяется по правилам: через VPN, напрямую или блокируется."
                        : "Домены из Russia inside (itdoginfo/allow-domains) идут через выбранный VPN. Весь остальной трафик — напрямую. Настройки DNS сохраняются.")
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Режим маршрутизации")
                } footer: {
                    Text("Выбор сохраняется. Если VPN подключён, он автоматически переподключится с новыми правилами.")
                }
                Section("Обновление списков") {
                    LabeledContent("Загрузка", value: "Через выбранный VPN")
                    LabeledContent("Интервал", value: "Раз в сутки")
                    Text("Списки выбранного режима обновляются автоматически, пока VPN подключён. При ошибке используются сохранённые списки, а при первом запуске — встроенные.")
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Роутинги")
        }
    }
}
