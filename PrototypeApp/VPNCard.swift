import Libbox
import Library
import SwiftUI

struct PrototypeVPNCard: View {
    @ObservedObject var model: PrototypeModel
    let maximumHeight: CGFloat
    let showPrivacyPolicy: () -> Void
    @AppStorage("prototype.privacy.reviewed.2026-10-22") private var privacyReviewed = false
    @State private var showingPrivacyNotice = false
    @State private var headerContentHeight: CGFloat = 60
    @State private var footerContentHeight: CGFloat = 50
    @State private var metricsHeight: CGFloat = 88
    @State private var noticeHeight: CGFloat = 0
    @ScaledMetric(relativeTo: .body) private var rowHeight: CGFloat = 44
    @State private var testingPing = false
    @StateObject private var client = CommandClient([.status, .outbounds], localOnly: true)
    @State private var expanded = false
    @GestureState private var dragging = false
    @State private var expansion: CGFloat = 0
    @State private var dragStartExpansion: CGFloat?
    @State private var scrollOffset: CGFloat = 0
    @State private var scrollFrame: CGRect = .zero
    @State private var scrolling = false
    @State private var detailsHeight: CGFloat = 220
    @State private var cardOpacity: Double = 1
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    private var totalUpload: String {
        client.status.map { ByteCountFormatter.string(fromByteCount: $0.uplinkTotal, countStyle: .binary) } ?? "—"
    }

    private var totalDownload: String {
        client.status.map { ByteCountFormatter.string(fromByteCount: $0.downlinkTotal, countStyle: .binary) } ?? "—"
    }

    private var upload: String {
        client.status.map { ByteCountFormatter.string(fromByteCount: $0.uplink, countStyle: .binary) + "/с" } ?? "—"
    }

    private var download: String {
        client.status.map { ByteCountFormatter.string(fromByteCount: $0.downlink, countStyle: .binary) + "/с" } ?? "—"
    }

    private var revealedDetailsHeight: CGFloat {
        detailsHeight * expansion
    }

    private var availableContentHeight: CGFloat {
        max(0, maximumHeight - headerContentHeight - footerContentHeight)
    }

    private var expansionTravel: CGFloat {
        min(detailsHeight, max(0, availableContentHeight - metricsHeight - noticeHeight))
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                Capsule().fill(Color(white: 0.81)).frame(width: 60, height: 4)
                    .frame(maxWidth: .infinity).frame(height: 16)
                HStack {
                    Text(verbatim: model.modeTitle).font(.system(size: 15))
                    Spacer()
                    Button { toggleExpanded() } label: {
                        HStack(spacing: 8) {
                            ZStack(alignment: .trailing) {
                                Text("Подробнее").hidden()
                                Text("Свернуть").hidden()
                                Text(expanded ? "Свернуть" : "Подробнее")
                                    .contentTransition(.identity)
                            }
                            Image(systemName: "chevron.up")
                                .rotationEffect(.degrees(180 * (reduceMotion ? (expanded ? 1 : 0) : expansion)))
                                .font(.system(size: 13, weight: .medium))
                        }.font(.system(size: 15)).frame(minHeight: rowHeight).contentShape(Rectangle())
                    }
                    .buttonStyle(PrototypeFlatStyle()).foregroundStyle(PrototypeStyle.accent)
                    .accessibilityLabel(expanded ? "Свернуть" : "Подробнее")
                    .accessibilityIdentifier("prototype.vpn.details")
                    .accessibilityValue(expanded ? String(localized: "Развёрнуто") : String(localized: "Свёрнуто"))
                }.padding(.horizontal, 16).frame(minHeight: rowHeight)
            }
            .contentShape(Rectangle())
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { headerContentHeight = $0 }
            .highPriorityGesture(expansionGesture)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    VStack(spacing: 0) {
                        separator
                        HStack {
                            Button {
                                guard let tag = outbound?.tag else { return }
                                testingPing = true
                                model.error = nil
                                Task {
                                    defer { testingPing = false }
                                    do {
                                        try await Task.detached {
                                            guard let command = LibboxNewStandaloneCommandClient() else { throw URLError(.cannotConnectToHost) }
                                            defer { try? command.disconnect() }
                                            try command.urlTest(tag)
                                        }.value
                                    } catch { model.error = String(localized: "Не удалось проверить пинг.") }
                                }
                            } label: {
                                if testingPing {
                                    ProgressView()
                                } else {
                                    Text("Проверить пинг")
                                }
                            }
                            .buttonStyle(PrototypeFlatStyle()).font(.system(size: 15)).foregroundStyle(PrototypeStyle.accent)
                            .disabled(outbound == nil || testingPing)
                            Spacer()
                            Text(verbatim: ping).foregroundStyle(PrototypeStyle.secondary)
                        }.padding(.horizontal, 16).frame(minHeight: rowHeight)
                        separator
                        metric("Память", value: model.canStop ? model.footprint : "—")
                    }
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { metricsHeight = $0 }
                    VStack(spacing: 0) {
                        metric("Сервер", value: server)
                        metric("Маршрут", value: model.routingMode.title)
                        metric("Трафик", value: model.canStop && client.status != nil ? totalDownload + " ↓ · " + totalUpload + " ↑" : "—")
                        metric("Скачивание", value: model.canStop ? download : "—")
                        metric("Отправка", value: model.canStop ? upload : "—")
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { detailsHeight = $0 }
                    .frame(height: revealedDetailsHeight, alignment: .top)
                    .clipped()
                    .accessibilityHidden(!expanded)
                    VStack(alignment: .leading, spacing: 0) {
                        if let warning = model.modeWarning {
                            Text(verbatim: warning).font(.footnote).foregroundStyle(.orange).padding(12)
                        }
                    }
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { noticeHeight = $0 }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollDisabled(dragStartExpansion != nil || expansion < 1)
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                max(0, geometry.contentOffset.y + geometry.contentInsets.top)
            } action: { _, offset in
                scrollOffset = offset
            }
            .frame(height: min(metricsHeight + expansionTravel * expansion + noticeHeight, availableContentHeight))
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { scrollFrame = $0 }
            .simultaneousGesture(expansionGesture)
            Button {
                if model.canStop {
                    model.stop()
                } else {
                    if privacyReviewed {
                        Task { await model.start() }
                    } else {
                        showingPrivacyNotice = true
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "power").font(.system(size: 18))
                    if model.canStop {
                        Text(verbatim: model.status)
                        Text("·")
                        if let start = model.connectedAt {
                            TimelineView(.periodic(from: .now, by: 1)) { timeline in
                                Text(duration(from: start, to: timeline.date)).monospacedDigit()
                            }
                        } else {
                            Text("—")
                        }
                    } else {
                        Text("Подключить")
                    }
                }
                .font(.system(size: 17)).foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: 50)
                .background(PrototypeStyle.accent, in: Capsule())
            }
            .buttonStyle(PrototypeFlatStyle())
            .disabled(model.canStop ? false : !model.canStart)
            .accessibilityLabel(model.canStop ? "Отключить" : "Подключить")
            .accessibilityIdentifier(model.canStop ? "prototype.stop" : "prototype.start")
            .alert("Перед подключением", isPresented: $showingPrivacyNotice) {
                Button("Подключить") {
                    privacyReviewed = true
                    Task { await model.start() }
                }
                Button("Политика конфиденциальности", action: showPrivacyPolicy)
                Button("Отмена", role: .cancel) {}
            } message: {
                Text("Трафик передаётся выбранным вами серверам. Режим VK TURN также использует инфраструктуру VK. Клиент сохраняет настройки и локальные журналы; автоматически разработчику они не отправляются. Разработчик не продаёт ваши данные и не использует VPN-трафик для рекламы или отслеживания.")
            }
            .overlay {
                Text(verbatim: model.status).hidden()
                    .accessibilityHidden(false).accessibilityIdentifier("prototype.status").accessibilityValue(model.status)
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { footerContentHeight = $0 }
            .highPriorityGesture(expansionGesture)
        }
        .font(.system(size: 17))
        .prototypeSurface()
        .clipShape(RoundedRectangle(cornerRadius: 24))
        .contentShape(RoundedRectangle(cornerRadius: 24))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("prototype.vpn.card")
        .opacity(cardOpacity)
        .onChange(of: dragging) { _, active in
            if !active {
                scrolling = false
                if dragStartExpansion != nil {
                    dragStartExpansion = nil
                    setExpanded(expanded)
                }
            }
        }
        .task(id: scenePhase) {
            defer { client.disconnect() }
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                if model.canStop {
                    if !client.isConnected {
                        client.connect()
                    }
                } else {
                    client.disconnect()
                }
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
    }

    private func duration(from start: Date, to now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        return String(format: "%02d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
    }

    private var separator: some View {
        PrototypeStyle.separator.frame(height: 0).overlay(alignment: .bottom) { PrototypeStyle.separator.frame(height: 1) }
    }

    private func metric(_ title: String, value: String) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(verbatim: title)
                Spacer()
                Text(verbatim: value).foregroundStyle(PrototypeStyle.secondary).lineLimit(1).minimumScaleFactor(0.7)
            }.padding(.horizontal, 16).frame(minHeight: rowHeight)
            separator
        }
    }

    private var expansionGesture: some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .global)
            .updating($dragging) { value, state, _ in
                if abs(value.translation.height) > abs(value.translation.width) {
                    state = true
                }
            }
            .onChanged { value in
                guard !scrolling, abs(value.translation.height) > abs(value.translation.width) else { return }
                if dragStartExpansion == nil {
                    let contentHeight = metricsHeight + detailsHeight + noticeHeight
                    if expanded, scrollFrame.contains(value.startLocation), contentHeight > availableContentHeight,
                       scrollOffset > 1 || value.translation.height < 0
                    {
                        scrolling = true
                        return
                    }
                    dragStartExpansion = expansion
                }
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    expansion = min(1, max(0, (dragStartExpansion ?? 0) - value.translation.height / max(1, expansionTravel)))
                    expanded = expansion > 0.5
                }
            }
            .onEnded { value in
                scrolling = false
                guard let start = dragStartExpansion else { return }
                let projectedExpansion = start - value.predictedEndTranslation.height / max(1, expansionTravel)
                dragStartExpansion = nil
                setExpanded(projectedExpansion > 0.5)
            }
    }

    private func toggleExpanded() {
        setExpanded(!expanded)
    }

    private func setExpanded(_ value: Bool) {
        if reduceMotion {
            withAnimation(.easeOut(duration: 0.06), completionCriteria: .removed) { cardOpacity = 0 } completion: {
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    expanded = value
                    expansion = value ? 1 : 0
                }
                withAnimation(.easeIn(duration: 0.06)) { cardOpacity = 1 }
            }
        } else {
            withAnimation(.spring(duration: 0.3)) {
                expanded = value
                expansion = value ? 1 : 0
            }
        }
    }

    /// Only a matching outbound from the running core is evidence of server/ping.
    private var outbound: LibboxOutboundGroupItem? {
        guard model.canStop else { return nil }
        return client.outbounds?.first { $0.type.lowercased() == "vless" && model.connectionMode == .vless }
    }

    private var server: String {
        outbound?.tag ?? "—"
    }

    private var ping: String {
        guard let outbound, outbound.urlTestDelay > 0 else { return "—" }
        return String(outbound.urlTestDelay) + " мс"
    }
}
