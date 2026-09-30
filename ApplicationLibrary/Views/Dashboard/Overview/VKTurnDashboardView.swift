import Libbox
import Library
import SwiftUI

#if os(iOS)
@MainActor
struct VKTurnDashboardView: View {
    @EnvironmentObject private var profile: ExtensionProfile
    @State private var stats: VKTurnStats?
    @State private var previousStats: VKTurnStats?
    @State private var previousSampleAt: Date?
    @State private var uploadRate: Int64 = 0
    @State private var downloadRate: Int64 = 0
    @State private var statsUnavailable = false
    @State private var uploadHistory: [CGFloat] = []
    @State private var downloadHistory: [CGFloat] = []

    var body: some View {
        VStack(spacing: 16) {
            DashboardCardView(title: "") {
                VStack(alignment: .leading, spacing: 8) {
                    DashboardCardHeader(icon: "network.badge.shield.half.filled", title: "VK TURN")
                    HStack(spacing: 8) {
                        Image(systemName: profile.status.isConnectedStrict ? "checkmark.circle.fill" : "circle.dotted")
                            .foregroundStyle(profile.status.isConnectedStrict ? .green : .secondary)
                        Text(profile.status.isConnectedStrict ? "Подключено" : "Подключение не активно")
                            .font(.subheadline)
                    }
                    if let authError = stats?.authError, !authError.isEmpty {
                        Text(authError).font(.footnote).foregroundStyle(.red)
                    } else if statsUnavailable {
                        Text("Статистика временно недоступна")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }

            if profile.status.isConnected {
                HStack(alignment: .top, spacing: 16) {
                    trafficCard(title: "Отправлено", icon: "arrow.up.circle.fill", rate: uploadRate,
                                total: stats?.txBytes, history: uploadHistory)
                    trafficCard(title: "Получено", icon: "arrow.down.circle.fill", rate: downloadRate,
                                total: stats?.rxBytes, history: downloadHistory)
                }
                HStack(alignment: .top, spacing: 16) {
                    statisticsCard(title: "Соединения", icon: "link.circle.fill") {
                        DashboardCardLine("Активные", stats.map { "\($0.activeConns) / \($0.totalConns)" } ?? "…")
                        DashboardCardLine("Переподключения", stats.map { "\($0.reconnects)" } ?? "…")
                    }
                    statisticsCard(title: "Задержка", icon: "waveform.path") {
                        DashboardCardLine("TURN", stats.map { milliseconds($0.turnRTTms) } ?? "…")
                        DashboardCardLine("DTLS", stats.map { milliseconds($0.dtlsHandshakeMs) } ?? "…")
                    }
                }
                HStack(alignment: .top, spacing: 16) {
                    statisticsCard(title: "Пул", icon: "square.stack.3d.up.fill") {
                        DashboardCardLine("Доступно", stats.map { "\($0.credPoolFilled) / \($0.credPoolSize)" } ?? "…")
                        DashboardCardLine("С ключами", stats.map { "\($0.credPoolWithCreds)" } ?? "…")
                        DashboardCardLine("Ретрансляторы", stats.map { "\($0.credPoolDistinctRelays)" } ?? "…")
                    }
                    statisticsCard(title: "Сессия", icon: "clock.fill") {
                        DashboardCardLine("Время работы", stats.map { uptime($0.tunnelUptimeSec) } ?? "…")
                        DashboardCardLine("Отказы квоты", stats.map { "\($0.credPoolQuotaRefusals)" } ?? "…")
                        if let stats, stats.credPoolMintPausedSec > 0 {
                            DashboardCardLine("Пауза пула", "\(stats.credPoolMintPausedSec) с")
                        }
                    }
                }
            }
        }
        .task(id: profile.status) {
            guard profile.status.isConnected else {
                stats = nil
                previousStats = nil
                previousSampleAt = nil
                statsUnavailable = false
                return
            }
            while !Task.isCancelled, profile.activeProvider == .vkTurn, profile.status.isConnected {
                if let current = try? await profile.vkTurnStats() {
                    let sampledAt = Date()
                    if let previousStats, let previousSampleAt {
                        let interval = max(0.1, sampledAt.timeIntervalSince(previousSampleAt))
                        uploadRate = Int64(Double(max(0, current.txBytes - previousStats.txBytes)) / interval)
                        downloadRate = Int64(Double(max(0, current.rxBytes - previousStats.rxBytes)) / interval)
                    }
                    self.previousStats = current
                    previousSampleAt = sampledAt
                    stats = current
                    statsUnavailable = false
                    uploadHistory.append(CGFloat(uploadRate))
                    downloadHistory.append(CGFloat(downloadRate))
                    if uploadHistory.count > 30 { uploadHistory.removeFirst() }
                    if downloadHistory.count > 30 { downloadHistory.removeFirst() }
                } else {
                    statsUnavailable = true
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    private func trafficCard(title: LocalizedStringKey, icon: String, rate: Int64,
                             total: Int64?, history: [CGFloat]) -> some View {
        DashboardCardView(title: "") {
            VStack(alignment: .leading, spacing: 8) {
                DashboardCardHeader(icon: icon, title: title)
                Text(total == nil ? "…" : "\(LibboxFormatBytes(rate))/s")
                    .font(.title2).fontWeight(.medium)
                Text(total.map(LibboxFormatBytes) ?? "…")
                    .font(.subheadline).foregroundStyle(.secondary)
                TrafficLineChart(data: history)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func statisticsCard<Content: View>(title: LocalizedStringKey, icon: String,
                                               @ViewBuilder content: @escaping () -> Content) -> some View {
        DashboardCardView(title: "") {
            VStack(alignment: .leading, spacing: 8) {
                DashboardCardHeader(icon: icon, title: title)
                content()
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func milliseconds(_ value: Double) -> String {
        String(format: "%.0f мс", value)
    }

    private func uptime(_ seconds: Int64) -> String {
        String(format: "%02d:%02d:%02d", seconds / 3600, (seconds / 60) % 60, seconds % 60)
    }
}
#endif
