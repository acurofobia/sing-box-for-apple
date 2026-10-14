import Library
import SwiftUI
import UIKit

struct PrototypeLogView: View {
    @ObservedObject var model: PrototypeModel
    @StateObject private var client = CommandClient(.log, logMaxLines: 1000, localOnly: true)
    @Environment(\.scenePhase) private var scenePhase
    @State private var searchText = ""
    @State private var pausedLogs: [LogEntry]?

    private var logs: [LogEntry] { pausedLogs ?? client.logBuffer.entries }
    private var visibleLogs: [LogEntry] {
        searchText.isEmpty ? logs : logs.filter { $0.message.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        Group {
            if logs.isEmpty {
                Text(model.status == "Отключено" ? "VPN отключён" : "Ожидание записей…")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if visibleLogs.isEmpty {
                Text("Нет записей по запросу")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { reader in
                    List(visibleLogs) { entry in
                        Text(entry.message)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(entry.level == LogLevel.error.rawValue ? .red : .primary)
                            .textSelection(.enabled)
                            .id(entry.id)
                    }
                    .listStyle(.plain)
                    .onChange(of: client.logBuffer.totalCount) {
                        if pausedLogs == nil, let last = visibleLogs.last {
                            reader.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }
        }
        .navigationTitle("Логи · " + model.connectionMode.title)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: "Поиск")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    pausedLogs = pausedLogs == nil ? client.logBuffer.entries : nil
                } label: {
                    Label(pausedLogs == nil ? "Пауза" : "Продолжить", systemImage: pausedLogs == nil ? "pause.circle" : "play.circle")
                }
                .accessibilityIdentifier("prototype.logs.pause")
                Button {
                    UIPasteboard.general.string = visibleLogs.map(\.message).joined(separator: "\n")
                } label: {
                    Label("Скопировать журнал", systemImage: "doc.on.clipboard")
                }
                .disabled(visibleLogs.isEmpty)
            }
        }
        .task(id: scenePhase) {
            defer { client.disconnect() }
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                if model.status == "Подключено" || model.status == "Подключение…" {
                    if !client.isConnected { client.connect() }
                } else {
                    client.disconnect()
                }
                do { try await Task.sleep(for: .seconds(1)) }
                catch { return }
            }
        }
    }
}
