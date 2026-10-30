import Library
import SwiftUI
import UIKit

struct PrototypeLogView: View {
    @ObservedObject var model: PrototypeModel
    @StateObject private var client = CommandClient(.log, logMaxLines: 1000, localOnly: true)
    @Environment(\.scenePhase) private var scenePhase
    @State private var searchText = ""
    @State private var pausedLogs: [LogEntry]?
    @State private var preparingDiagnostics = false
    @State private var diagnosticURL: URL?
    @State private var diagnosticPages: [String] = []
    @State private var diagnosticPage = 0
    @State private var showDiagnostics = false
    @State private var diagnosticError: String?
    @State private var confirmClear = false

    private var logs: [LogEntry] {
        pausedLogs ?? client.logBuffer.entries
    }

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
        .navigationTitle("Логи · " + model.modeTitle)
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
                Button {
                    Task { await prepareDiagnostics() }
                } label: {
                    Label("Сохранённая диагностика", systemImage: "doc.text.magnifyingglass")
                }
                .disabled(preparingDiagnostics)
                .accessibilityIdentifier("prototype.logs.diagnostics")
            }
        }
        .overlay {
            if preparingDiagnostics { ProgressView("Подготовка диагностики…") }
        }
        .alert("Не удалось открыть диагностику", isPresented: Binding(
            get: { diagnosticError != nil }, set: { if !$0 { diagnosticError = nil } }
        )) {
            Button("ОК", role: .cancel) { diagnosticError = nil }
        } message: { Text(diagnosticError ?? "") }
        .sheet(isPresented: $showDiagnostics, onDismiss: {
            if let diagnosticURL { try? FileManager.default.removeItem(at: diagnosticURL) }
            diagnosticURL = nil
            diagnosticPages = []
        }, content: {
            NavigationStack {
                VStack(spacing: 0) {
                    Text("Отчёты о неожиданных отключениях и ошибки приложения не удаляются при новых подключениях. После отправки их можно удалить вручную. Журнал может содержать адреса серверов и домены.")
                        .font(.footnote).foregroundStyle(.secondary).padding()
                    PrototypeLegalTextView(text: diagnosticPages.indices.contains(diagnosticPage) ? diagnosticPages[diagnosticPage] : "",
                                          detectLinks: false, monospaced: true,
                                          accessibilityIdentifier: "prototype.logs.diagnostics.text")
                        .id(diagnosticPage)
                    if diagnosticPages.count > 1 {
                        HStack {
                            Button { diagnosticPage -= 1 } label: { Label("Предыдущая", systemImage: "chevron.left") }
                                .disabled(diagnosticPage == 0)
                                .accessibilityIdentifier("prototype.logs.diagnostics.previous")
                            Spacer()
                            Text("\(diagnosticPage + 1) / \(diagnosticPages.count)").monospacedDigit()
                            Spacer()
                            Button { diagnosticPage += 1 } label: { Label("Следующая", systemImage: "chevron.right") }
                                .disabled(diagnosticPage + 1 == diagnosticPages.count)
                                .accessibilityIdentifier("prototype.logs.diagnostics.next")
                        }
                        .font(.footnote).padding()
                    }
                }
                .navigationTitle("Сохранённая диагностика")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Закрыть") { showDiagnostics = false }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(role: .destructive) { confirmClear = true } label: {
                            Label("Удалить сохранённые отчёты", systemImage: "trash")
                        }
                        .accessibilityIdentifier("prototype.logs.diagnostics.clear")
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        if let diagnosticURL {
                            ShareLink(item: diagnosticURL) { Label("Отправить файл", systemImage: "square.and.arrow.up") }
                                .accessibilityIdentifier("prototype.logs.diagnostics.share")
                        }
                    }
                }
                .alert("Удалить сохранённые отчёты?", isPresented: $confirmClear) {
                    Button("Отмена", role: .cancel) {}
                    Button("Удалить", role: .destructive) {
                        Task {
                            do {
                                try await BlockingIO.run { try VPNDiagnostics.clearPreservedReports() }
                                await prepareDiagnostics()
                            } catch {
                                VPNDiagnostics.applicationError("clear preserved diagnostics", error: error)
                                diagnosticError = error.localizedDescription
                            }
                        }
                    }
                } message: {
                    Text("Отчёты о неожиданных отключениях и сохранённые ошибки приложения будут удалены с устройства. Сначала отправьте нужный файл.")
                }
            }
        })
        .onReceive(client.$lastError.removeDuplicates()) { error in
            if let error { VPNDiagnostics.applicationError("log command channel \(error.kind): \(error.message)") }
        }
        .task(id: scenePhase) {
            defer { client.disconnect() }
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                if model.vpnState == .connected || model.vpnState == .connecting {
                    if !client.isConnected {
                        client.connect()
                    }
                } else {
                    client.disconnect()
                }
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    return
                }
            }
        }
    }

    @MainActor
    private func prepareDiagnostics() async {
        preparingDiagnostics = true
        defer { preparingDiagnostics = false }
        await model.collectDiagnostics()
        do {
            let result = try await BlockingIO.run {
                let url = try VPNDiagnostics.export()
                let text = try String(contentsOf: url, encoding: .utf8)
                var pages: [String] = []
                var start = text.startIndex
                while start < text.endIndex {
                    let end = text.index(start, offsetBy: 16_384, limitedBy: text.endIndex) ?? text.endIndex
                    pages.append(String(text[start..<end]))
                    start = end
                }
                return (url, pages)
            }
            if let diagnosticURL { try? FileManager.default.removeItem(at: diagnosticURL) }
            diagnosticURL = result.0
            diagnosticPages = result.1
            diagnosticPage = 0
            showDiagnostics = true
        } catch {
            VPNDiagnostics.applicationError("open diagnostic file", error: error)
            diagnosticError = error.localizedDescription
        }
    }
}
