import Library
import SwiftUI
import UIKit

struct PrototypeLogView: View {
    private enum ExportAction: Sendable { case readSaved, shareCurrent, shareSaved }

    @ObservedObject var model: PrototypeModel
    @StateObject private var client = CommandClient(.log, logMaxLines: 1000, localOnly: true)
    @Environment(\.scenePhase) private var scenePhase
    @State private var searchText = ""
    @State private var pausedLogs: [LogEntry]?
    @State private var preparingDiagnostics = false
    @State private var diagnosticURL: URL?
    @State private var savedReport: VPNDiagnostics.SavedReport?
    @State private var diagnosticText = ""
    @State private var loadingPage = false
    @State private var diagnosticPage = 0
    @State private var showDiagnostics = false
    @State private var sharingLogs = false
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
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                shareButton("Текущие логи", action: .shareCurrent)
                shareButton("Сохранённые логи", action: .shareSaved)
            }
            .frame(maxWidth: 326)
            .padding(.horizontal, 16)
            .padding(.top, 4).padding(.bottom, 18)
            .disabled(preparingDiagnostics)
            .background {
                LogFileSharePresenter(url: sharingLogs ? diagnosticURL : nil) {
                    sharingLogs = false
                    discardExport()
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
        .sheet(isPresented: $showDiagnostics, onDismiss: discardExport, content: {
            NavigationStack {
                VStack(spacing: 0) {
                    Text("Отчёты о неожиданных отключениях и ошибки приложения не удаляются при новых подключениях. После отправки их можно удалить вручную. Журнал может содержать адреса серверов и домены.")
                        .font(.footnote).foregroundStyle(.secondary).padding()
                    PrototypeLegalTextView(text: diagnosticText,
                                          detectLinks: false, monospaced: true,
                                          accessibilityIdentifier: "prototype.logs.diagnostics.text")
                        .id(diagnosticPage)
                    if let savedReport, savedReport.pageCount > 1 {
                        HStack {
                            Button { Task { await readPage(diagnosticPage - 1, from: savedReport) } } label: { Label("Предыдущая", systemImage: "chevron.left") }
                                .disabled(loadingPage || diagnosticPage == 0)
                                .accessibilityIdentifier("prototype.logs.diagnostics.previous")
                            Spacer()
                            Text("\(diagnosticPage + 1) / \(savedReport.pageCount)").monospacedDigit()
                            Spacer()
                            Button { Task { await readPage(diagnosticPage + 1, from: savedReport) } } label: { Label("Следующая", systemImage: "chevron.right") }
                                .disabled(loadingPage || diagnosticPage + 1 == savedReport.pageCount)
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
        .onChange(of: client.lastError, initial: true) { _, error in
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

    private func shareButton(_ title: LocalizedStringKey, action: ExportAction) -> some View {
        Button {
            Task { await prepareDiagnostics(action) }
        } label: {
            Label(title, systemImage: "square.and.arrow.up")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.white)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity, minHeight: 34)
                .background(PrototypeStyle.accent, in: Capsule())
                .shadow(color: .black.opacity(0.12), radius: 3, y: 2)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(PrototypeFlatStyle())
    }

    private func discardExport() {
        if let diagnosticURL { try? FileManager.default.removeItem(at: diagnosticURL) }
        diagnosticURL = nil
        savedReport = nil
        diagnosticText = ""
    }

    @MainActor
    private func readPage(_ page: Int, from report: VPNDiagnostics.SavedReport) async {
        guard !loadingPage else { return }
        loadingPage = true
        defer { loadingPage = false }
        do {
            let text = try await BlockingIO.run { try report.text(forPage: page) }
            guard savedReport?.url == report.url else { return }
            diagnosticText = text
            diagnosticPage = page
        } catch {
            guard savedReport?.url == report.url else { return }
            VPNDiagnostics.applicationError("read diagnostic page", error: error)
            diagnosticError = error.localizedDescription
        }
    }

    @MainActor
    private func prepareDiagnostics(_ action: ExportAction = .readSaved) async {
        guard !preparingDiagnostics else { return }
        preparingDiagnostics = true
        defer { preparingDiagnostics = false }
        let current = action == .shareCurrent ? logs.map(\.message) : nil
        if current == nil { await model.collectDiagnostics() }
        do {
            let result: (url: URL, report: VPNDiagnostics.SavedReport?, text: String) = try await BlockingIO.run {
                if let current { return (try VPNDiagnostics.exportCurrentLogs(current), nil, "") }
                guard action == .readSaved else { return (try VPNDiagnostics.export(), nil, "") }
                let report = try VPNDiagnostics.exportForReading()
                do {
                    return (report.url, report, try report.text(forPage: 0))
                } catch {
                    try? FileManager.default.removeItem(at: report.url)
                    throw error
                }
            }
            discardExport()
            diagnosticURL = result.url
            savedReport = result.report
            diagnosticText = result.text
            diagnosticPage = 0
            if action == .readSaved {
                showDiagnostics = true
            } else {
                sharingLogs = true
            }
        } catch {
            VPNDiagnostics.applicationError("open diagnostic file", error: error)
            diagnosticError = error.localizedDescription
        }
    }
}

private struct LogFileSharePresenter: UIViewControllerRepresentable {
    let url: URL?
    let finished: () -> Void

    func makeUIViewController(context _: Context) -> UIViewController {
        UIViewController()
    }

    func updateUIViewController(_ presenter: UIViewController, context _: Context) {
        guard let url, presenter.view.window != nil, presenter.presentedViewController == nil else { return }
        let sheet = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        sheet.popoverPresentationController?.sourceView = presenter.view
        sheet.popoverPresentationController?.sourceRect = presenter.view.bounds
        sheet.completionWithItemsHandler = { _, _, _, _ in finished() }
        presenter.present(sheet, animated: true)
    }
}
