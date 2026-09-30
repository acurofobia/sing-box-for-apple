import Foundation
import Library
import SwiftUI

#if os(iOS)
private func readVKTurnLog(from offset: UInt64) throws -> (data: Data, end: UInt64, reset: Bool, skipFirstLine: Bool) {
    guard let logURL = VKTurnConfigurationStore.logURL else { throw CocoaError(.fileNoSuchFile) }
    let file = try FileHandle(forReadingFrom: logURL)
    defer { try? file.close() }
    let size = try file.seekToEnd()
    let reset = size < offset
    var start = reset ? 0 : offset
    let limit: UInt64 = 512 * 1024
    let skipFirstLine = size - start > limit
    if skipFirstLine { start = size - limit }
    try file.seek(toOffset: start)
    let data = try file.read(upToCount: Int(size - start)) ?? Data()
    return (data, start + UInt64(data.count), reset || skipFirstLine, skipFirstLine)
}

@MainActor
struct VKTurnLogView: View {
    @State private var logs: [LogEntry] = []
    @State private var searchText = ""
    @State private var isPaused = false
    @State private var offset: UInt64 = 0
    @State private var pending = Data()

    private var visibleLogs: [LogEntry] {
        searchText.isEmpty ? logs : logs.filter { $0.message.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        Group {
            if logs.isEmpty {
                Text("Ожидание записей VK TURN…")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if visibleLogs.isEmpty {
                Text("Нет записей по запросу")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                LogTextView(logs: visibleLogs, font: .system(.caption2, design: .monospaced),
                            shouldAutoScroll: !isPaused, searchText: searchText)
            }
        }
        .searchable(text: $searchText)
        .toolbar {
            ToolbarItemGroup {
                Button {
                    isPaused.toggle()
                } label: {
                    Label(isPaused ? "Продолжить" : "Пауза", systemImage: isPaused ? "play.circle" : "pause.circle")
                }
                Button {
                    UIPasteboard.general.string = logs.map(\.message).joined(separator: "\n")
                } label: {
                    Label("Скопировать журнал", systemImage: "doc.on.clipboard")
                }
                .disabled(logs.isEmpty)
            }
        }
        .task {
            while !Task.isCancelled {
                if !isPaused {
                    let currentOffset = offset
                    if let result = try? await Task.detached(priority: .utility, operation: {
                        try readVKTurnLog(from: currentOffset)
                    }).value {
                        if result.reset {
                            logs = []
                            pending = Data()
                        }
                        offset = result.end
                        var data = pending + result.data
                        if result.skipFirstLine, let end = data.firstIndex(of: 10) {
                            data.removeSubrange(...end)
                        }
                        while let end = data.firstIndex(of: 10) {
                            let line = Data(data[..<end])
                            if let message = String(data: line, encoding: .utf8), !message.isEmpty {
                                logs.append(LogEntry(level: 4, message: message))
                            }
                            data.removeSubrange(...end)
                        }
                        pending = data
                        if logs.count > 1_000 { logs.removeFirst(logs.count - 1_000) }
                    }
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }
}
#endif
