import Library
import NetworkExtension
import SwiftUI
import UIKit

private enum PrototypeTab: Hashable { case connection, routing, profile }

struct PrototypeView: View {
    @StateObject private var model = PrototypeModel()
    @StateObject private var presentation = PrototypePresentationCoordinator()
    @State private var tab: PrototypeTab = .connection
    @State private var ready = false
    @State private var inactive = false
    @State private var connectionTop: CGFloat = 0
    @State private var rootTop: CGFloat = 0
    @State private var importedSubscriptionSource: String?
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL

    private var document: PrototypeUIDocument? {
        model.subscription.uiDocument
    }

    private var sheet: Binding<PrototypePresentationCoordinator.Destination?> {
        Binding(get: {
            switch presentation.destination {
            case .subscription, .page, .legal: return presentation.destination
            default: return nil
            }
        }, set: {
            if $0 == nil {
                if presentation.destination == .subscription {
                    model.cancelSubscriptionReplacement()
                }
                presentation.dismiss()
            }
        })
    }

    private var dialog: PrototypeUIBlock? {
        if case let .dialog(id) = presentation.destination {
            return document?.block(id)
        }
        return nil
    }

    var body: some View {
        ZStack(alignment: .top) {
            Group {
                if !ready {
                    ProgressView()
                } else if model.subscription.isComplete {
                    TabView(selection: $tab) {
                        PrototypeConnectionView(model: model, presentation: presentation, edit: { tab = .profile })
                            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { connectionTop = $0 }
                            .tabItem { Label("Подключение", systemImage: "power") }.tag(PrototypeTab.connection)
                        PrototypeRoutingView(model: model)
                            .tabItem { Label("Роутинг", systemImage: "arrow.triangle.branch") }.tag(PrototypeTab.routing)
                        NavigationStack { PrototypeProfileView(model: model, presentation: presentation) }
                            .tabItem { Label("Профиль", systemImage: "person") }.tag(PrototypeTab.profile)
                    }
                } else {
                    NavigationStack {
                        PrototypeSubscriptionForm(model: model, replacing: false, importedSource: $importedSubscriptionSource, saved: {
                            tab = .connection
                            if document?.block("block04")?.items?.contains(where: { item in
                                guard item.isVisible, let mode = PrototypeConnectionMode.from(optionID: item.id) else { return false }
                                return model.isAvailable(mode)
                            }) == true {
                                presentation.showModeOnboarding()
                            }
                        })
                    }
                }
            }
            .allowsHitTesting(presentation.destination != .modes && dialog == nil)
            .disabled(model.resetting)
            .accessibilityHidden(presentation.destination == .modes || dialog != nil)
            if ready, model.subscription.isComplete,
               (tab == .connection && document?.block("block04") != nil) || presentation.destination == .modes
            {
                PrototypeModeDrawer(model: model, presentation: presentation)
                    .padding(.top, max(0, connectionTop - rootTop))
                    .zIndex(10)
            }
            if let dialog {
                PrototypeAccountDialog(block: dialog, dismiss: { presentation.dismiss() }, action: { presentation.dispatch($0, document: document) })
                    .zIndex(20)
            }
        }
        .coordinateSpace(name: "prototype.root")
        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { rootTop = $0 }
        .tint(PrototypeStyle.accent)
        .statusBarHidden(false)
        .preferredColorScheme(.light)
        .modifier(PrototypeNoticeModifier(presentation: presentation))
        .sheet(item: sheet, onDismiss: { presentation.completeDismissal() }, content: { destination in
            NavigationStack {
                switch destination {
                case .subscription:
                    PrototypeSubscriptionForm(model: model, replacing: true, importedSource: $importedSubscriptionSource, saved: { presentation.dismiss() })
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Отмена") { model.cancelSubscriptionReplacement(); presentation.dismiss() }
                            }
                        }
                        .onDisappear { model.cancelSubscriptionReplacement() }
                case let .page(id):
                    if let page = document?.pages.first(where: { $0.id == id }) {
                        ScrollView { Text(verbatim: page.text).frame(maxWidth: .infinity, alignment: .leading).padding() }
                            .navigationTitle(Text(verbatim: page.title))
                            .navigationBarTitleDisplayMode(.inline)
                            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Закрыть") { presentation.dismiss() } } }
                    }
                case let .legal(document):
                    PrototypeLegalView(document: document)
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Закрыть") { presentation.dismiss() } } }
                default: EmptyView()
                }
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
            .modifier(PrototypeNoticeModifier(presentation: presentation))
        })
        .onReceive(model.$error.removeDuplicates()) { error in
            if let error { presentation.notice = error }
        }
        .onReceive(model.$subscriptionError.removeDuplicates()) { error in
            if let error { presentation.notice = error }
        }
        .onChange(of: presentation.notice) { _, notice in
            if let notice {
                VPNDiagnostics.applicationError("application notice: " + notice)
                UIAccessibility.post(notification: .announcement, argument: notice)
            }
        }
        .onChange(of: presentation.externalURL) { _, value in
            guard let value else { return }
            presentation.externalURL = nil
            openURL(value) { accepted in
                if !accepted {
                    presentation.notice = String(localized: "Не удалось открыть ссылку.")
                }
            }
        }
        .onChange(of: model.subscription.updatedAt) { presentation.reconcile(document) }
        .onOpenURL { url in
            do {
                let source = try PrototypeDeepLink.subscriptionSource(from: url)
                guard !model.resetting, !model.replacingSubscription else {
                    presentation.notice = String(localized: "Дождитесь завершения текущей операции и откройте ссылку ещё раз.")
                    return
                }
                importedSubscriptionSource = source
                if ready, model.subscription.isComplete {
                    presentation.show(.subscription)
                }
            } catch {
                presentation.notice = String(localized: "Не удалось открыть ссылку добавления подписки.")
            }
        }
        .onChange(of: model.subscription.isComplete) { _, complete in
            if !complete {
                tab = .connection
                presentation.dismiss()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            VPNDiagnostics.app("scene phase=\(phase)")
            model.recordVPNState(force: phase == .active)
            if phase != .active {
                inactive = true
            } else if ready, inactive {
                inactive = false
                Task { await model.refreshSubscription() }
            }
        }
        .task {
            await model.load()
            ready = true
            inactive = false
            if importedSubscriptionSource != nil, model.subscription.isComplete {
                presentation.show(.subscription)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .NEVPNStatusDidChange)) { _ in
            model.recordVPNState()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
            VPNDiagnostics.app("application memory warning")
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willTerminateNotification)) { _ in
            VPNDiagnostics.app("application will terminate")
        }
        .task(id: ready && scenePhase == .active) {
            guard ready, scenePhase == .active else { return }
            while !Task.isCancelled {
                await model.refreshSubscription()
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
            }
        }
        .task(id: ready) {
            guard ready else { return }
            while !Task.isCancelled {
                await model.refresh()
                model.recordVPNState()
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
    }
}

struct PrototypeSubscriptionForm: View {
    @ObservedObject var model: PrototypeModel
    let replacing: Bool
    @Binding var importedSource: String?
    var saved: () -> Void = {}
    @State private var source = ""
    @State private var showingHelp = false
    @FocusState private var focused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text(replacing ? "Изменить подписку" : "Добавьте подписку")
                    .font(.system(size: 32, weight: .medium)).fixedSize(horizontal: false, vertical: true)
                Text("Вставьте ссылку на подписку, чтобы начать пользоваться VPN.")
                    .font(.system(size: 17)).foregroundStyle(PrototypeStyle.secondary)
                    .fixedSize(horizontal: false, vertical: true).padding(.top, 12)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Ссылка на подписку").font(.system(size: 15))
                    HStack(spacing: 8) {
                        TextField("", text: $source, prompt: Text("Вставьте ссылку").foregroundStyle(PrototypeStyle.secondary))
                            .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                            .focused($focused).submitLabel(.done).onSubmit { focused = false }
                            .accessibilityIdentifier("prototype.subscription.url")
                        Button("Вставить") {
                            if let value = UIPasteboard.general.string {
                                source = value
                            }
                        }
                        .buttonStyle(PrototypeFlatStyle()).font(.system(size: 15)).foregroundStyle(PrototypeStyle.accent)
                        .accessibilityIdentifier("prototype.subscription.paste")
                    }
                    .font(.system(size: 17)).padding(.horizontal, 16).frame(height: 56)
                    .background(PrototypeStyle.field, in: RoundedRectangle(cornerRadius: 16)).padding(.top, 8)
                    Button {
                        focused = false
                        Task {
                            if await model.replaceSubscription(source) {
                                saved()
                            }
                        }
                    } label: {
                        Group {
                            if model.subscriptionLoading {
                                ProgressView().tint(.white)
                            } else {
                                Text(replacing ? "Сохранить" : "Добавить подписку")
                            }
                        }
                        .frame(maxWidth: .infinity, minHeight: 50)
                        .background(canSubmit ? PrototypeStyle.accent : PrototypeStyle.field, in: Capsule())
                        .foregroundStyle(canSubmit ? .white : PrototypeStyle.secondary)
                    }
                    .buttonStyle(PrototypeFlatStyle()).disabled(!canSubmit).padding(.top, 16)
                    .accessibilityIdentifier("prototype.subscription.fetch")
                    if !replacing {
                        Button("Где взять ссылку?") { showingHelp = true }
                            .font(.system(size: 15)).frame(maxWidth: .infinity, minHeight: 44).padding(.top, 16)
                            .accessibilityIdentifier("prototype.subscription.help")
                    }
                    if model.canStop {
                        Text("Отключите VPN перед изменением ссылки подписки.").padding(.top, 16)
                        Text(verbatim: model.status).accessibilityIdentifier("prototype.status").accessibilityValue(model.status)
                        Button("Отключить") { model.stop() }.accessibilityIdentifier("prototype.stop")
                        NavigationLink { PrototypeLogView(model: model) } label: { Text("Логи") }.accessibilityIdentifier("prototype.logs")
                    }
                    PrototypeLegalLinks().padding(.top, 24)
                }.padding(.top, 54)
            }
            .padding(.horizontal, 22).padding(.top, replacing ? 28 : 72).padding(.bottom, 24)
            .frame(maxWidth: 540)
            .frame(maxWidth: .infinity)
        }
        .background(.white)
        .toolbar(replacing ? .visible : .hidden, for: .navigationBar)
        .scrollDismissesKeyboard(.interactively)
        .onAppear {
            source = model.subscription.sourceURL ?? ""
            applyImportedSource()
        }
        .onChange(of: importedSource) { applyImportedSource() }
        .alert("Где взять ссылку?", isPresented: $showingHelp) {
            Button("Понятно", role: .cancel) {}
        } message: {
            Text("Укажите ссылку со своего или выбранного вами сервера подписки. Приложение является клиентом: разработчик не продаёт подключения и не предоставляет VPN-серверы.")
        }
    }

    private var canSubmit: Bool {
        !model.subscriptionLoading && !model.busy && !model.canStop && !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func applyImportedSource() {
        guard let importedSource else { return }
        source = importedSource
        self.importedSource = nil
        focused = false
    }
}

struct PrototypeSubscriptionCard: View {
    enum Context { case connection, profile }
    let block: PrototypeUIBlock
    let context: Context
    let updatedAt: Date?
    let loading: Bool
    let edit: () -> Void
    let refresh: () -> Void
    let action: (PrototypeUIAction) -> Void
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Подписка").font(.custom("Helvetica", size: 17, relativeTo: .body)).frame(minHeight: 22, alignment: .top)
            Text(verbatim: block.title ?? "").font(.custom("Helvetica-Bold", size: 32, relativeTo: .largeTitle))
                .frame(minHeight: 38, alignment: .top).padding(.top, 19)
            if let subtitle = block.subtitle {
                Text(verbatim: subtitle).font(.custom("Helvetica", size: 13, relativeTo: .caption))
                    .foregroundStyle(.white.opacity(0.83)).frame(minHeight: 18, alignment: .top).padding(.top, 4)
            }
            if let text = block.text {
                Text(verbatim: text).font(.custom("Helvetica", size: 17, relativeTo: .body))
                    .frame(minHeight: 23, alignment: .top).padding(.top, 10)
            }
            HStack(alignment: .center, spacing: 4) {
                Group {
                    if let updatedAt {
                        Text("Обновлено \(Calendar.current.isDateInToday(updatedAt) ? String(localized: "сегодня") : updatedAt.formatted(date: .numeric, time: .omitted)), \(updatedAt.formatted(date: .omitted, time: .shortened))")
                    } else {
                        Text("Обновлено —")
                    }
                }
                .font(.custom("Helvetica", size: 13, relativeTo: .caption)).foregroundStyle(.white.opacity(0.83))
                .frame(maxWidth: context == .profile ? 150 : .infinity, alignment: .leading)
                Spacer(minLength: context == .profile ? 4 : 120)
            }
            .frame(minHeight: context == .profile ? 36 : 18, alignment: .center)
            .padding(.top, context == .profile ? 4 : 16)
            if typeSize.isAccessibilitySize {
                Button(action: refresh) { Label("Обновить", systemImage: "arrow.clockwise") }
                    .buttonStyle(PrototypePillStyle(onArtwork: true)).frame(minHeight: 44)
                    .disabled(loading).accessibilityIdentifier("prototype.subscription.refresh")
            }
        }
        .padding(.horizontal, 18).padding(.top, 17).padding(.bottom, context == .profile ? 12 : 18)
        .frame(maxWidth: .infinity, minHeight: 203, alignment: .topLeading)
        .foregroundStyle(.white)
        .background {
            Image("SubscriptionTexture").resizable().scaledToFill()
        }
        .clipShape(RoundedRectangle(cornerRadius: 24))
        .overlay(alignment: .topTrailing) {
            if !typeSize.isAccessibilitySize {
                Button(action: refresh) {
                    HStack(spacing: 4) {
                        if loading {
                            ProgressView().tint(.white)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                        Text("Обновить")
                    }.font(.system(size: 15)).fixedSize(horizontal: true, vertical: false).frame(width: 88)
                }
                .buttonStyle(PrototypePillStyle(onArtwork: true)).disabled(loading)
                .frame(minHeight: 44).padding(.top, 9).padding(.trailing, 18)
                .accessibilityIdentifier("prototype.subscription.refresh")
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if context == .connection {
                Button(action: edit) { Label("Изменить", systemImage: "pencil").font(.system(size: 15)).fixedSize(horizontal: true, vertical: false).frame(width: 88) }
                    .buttonStyle(PrototypePillStyle(onArtwork: true)).frame(minHeight: 44)
                    .padding(.trailing, 18).padding(.bottom, 7)
                    .accessibilityIdentifier("prototype.subscription.profile")
            } else {
                VStack(alignment: .trailing) {
                    ForEach((block.buttons ?? []).filter(\.isVisible)) { button in
                        Button { action(button.action) } label: { Label(button.title, systemImage: "pencil").font(.system(size: 15)).fixedSize(horizontal: true, vertical: false).frame(width: 126) }
                            .buttonStyle(PrototypePillStyle(onArtwork: true)).frame(minHeight: 44)
                            .accessibilityIdentifier("prototype.ui." + button.id)
                    }
                }.padding(.trailing, 18).padding(.bottom, 7)
            }
        }
    }
}

struct PrototypeConnectionView: View {
    @ObservedObject var model: PrototypeModel
    @ObservedObject var presentation: PrototypePresentationCoordinator
    let edit: () -> Void
    private let cardSpacing: CGFloat = 16
    @ScaledMetric(relativeTo: .headline) private var modeRowHeight: CGFloat = 52

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottom) {
                VStack(spacing: cardSpacing) {
                    if let block = model.subscription.uiDocument?.block("block01") {
                        PrototypeSubscriptionCard(block: block, context: .connection, updatedAt: model.subscription.updatedAt,
                                                  loading: model.subscriptionLoading, edit: edit,
                                                  refresh: { Task { await model.refreshSubscription(force: true) } }, action: dispatch)
                            .padding(.horizontal, -1)
                    }
                    if !model.hasLink, !model.hasVLESS {
                        Text("Нет доступных конфигураций подключения. Обновите подписку или измените ссылку.").foregroundStyle(.orange).font(.footnote)
                    }
                }
                .padding(.horizontal, 18).padding(.top, modeRowHeight + cardSpacing)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                PrototypeVPNCard(model: model, maximumHeight: max(80, geometry.size.height - modeRowHeight - 47 - 12),
                                 showPrivacyPolicy: { presentation.show(.legal(.privacy)) })
                    .padding(.horizontal, 18).padding(.bottom, 47)
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .background(PrototypeStyle.background)
    }

    private func dispatch(_ action: PrototypeUIAction) {
        presentation.dispatch(action, document: model.subscription.uiDocument)
    }
}

struct PrototypeProfileView: View {
    @ObservedObject var model: PrototypeModel
    @ObservedObject var presentation: PrototypePresentationCoordinator
    @State private var showingReset = false
    private var menu: [PrototypeUIItem] {
        model.subscription.uiDocument?.block("block05")?.items ?? []
    }

    private var localIndex: Int {
        menu.firstIndex(where: { $0.id == "item03" }) ?? menu.count
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Профиль").font(.system(size: 34, weight: .bold)).frame(height: 40).padding(.horizontal, 5)
                if let block = model.subscription.uiDocument?.block("block01") {
                    PrototypeSubscriptionCard(block: block, context: .profile, updatedAt: model.subscription.updatedAt,
                                              loading: model.subscriptionLoading, edit: {},
                                              refresh: { Task { await model.refreshSubscription(force: true) } }, action: dispatch)
                }
                ForEach(model.subscription.warnings, id: \.self) { Text(verbatim: $0).foregroundStyle(.orange).font(.footnote) }
                if let block = model.subscription.uiDocument?.block("block02") {
                    HStack {
                        VStack(alignment: .leading, spacing: 6) {
                            if let subtitle = block.subtitle {
                                Text(verbatim: subtitle).font(.system(size: 14)).foregroundStyle(PrototypeStyle.secondary)
                            }
                            Text(verbatim: block.title ?? "").font(.system(size: 28, weight: .bold))
                            if let text = block.text {
                                Text(verbatim: text).font(.subheadline)
                            }
                        }
                        Spacer()
                        ForEach((block.buttons ?? []).filter(\.isVisible)) { button in
                            Button { dispatch(button.action) } label: { Text(verbatim: button.title).font(.system(size: 17)).frame(minWidth: 95) }
                                .buttonStyle(PrototypePillStyle(filled: true)).accessibilityIdentifier("prototype.ui." + button.id)
                        }
                    }.frame(minHeight: 66).padding(.horizontal, 5)
                }
                VStack(spacing: 0) {
                    ForEach(Array(menu.prefix(localIndex)).filter(\.isVisible)) { item in menuRow(item) }
                    NavigationLink { PrototypeLogView(model: model).toolbar(.visible, for: .navigationBar) } label: { row("Логи", last: false) }
                        .accessibilityIdentifier("prototype.logs")
                    NavigationLink { PrototypeSettingsView() } label: { row("Настройки приложения", last: false) }
                        .accessibilityIdentifier("prototype.settings")
                    Button { showingReset = true } label: {
                        row(model.resetting ? "Сброс…" : "Сбросить приложение", last: menu.dropFirst(localIndex).filter(\.isVisible).isEmpty, destructive: true)
                    }
                    .buttonStyle(.plain).disabled(model.busy || model.resetting)
                    .accessibilityIdentifier("prototype.reset")
                    ForEach(Array(menu.dropFirst(localIndex)).filter(\.isVisible)) { item in menuRow(item, last: item.id == menu.last?.id) }
                }
                .foregroundStyle(.primary).background(PrototypeStyle.field, in: RoundedRectangle(cornerRadius: 20))
                VStack(spacing: 0) {
                    ForEach(PrototypeLegalDocument.allCases) { document in
                        Button { presentation.show(.legal(document)) } label: {
                            row(document.title, last: document == .sources)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("prototype.legal." + document.rawValue)
                    }
                }
                .foregroundStyle(.primary).background(PrototypeStyle.field, in: RoundedRectangle(cornerRadius: 20))
            }
            .padding(.horizontal, 17).padding(.top, 48).padding(.bottom, 24)
            .frame(maxWidth: 574).frame(maxWidth: .infinity)
        }
        .background(.white).toolbar(.hidden, for: .navigationBar)
        .ignoresSafeArea(.container, edges: .top)
        .alert("Сбросить приложение?", isPresented: $showingReset) {
            Button("Сбросить", role: .destructive) { Task { await model.resetApplication() } }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("VPN будет отключён. Подписка, параметры подключения, сохранённые ключи, настройки, кеш и локальные журналы будут удалены с устройства. Это действие нельзя отменить.")
        }
    }

    private func row(_ title: String, last: Bool, destructive: Bool = false) -> some View {
        HStack {
            Text(verbatim: title).font(.system(size: 17)).foregroundStyle(destructive ? Color.red : Color.primary)
            Spacer()
            Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(Color(uiColor: .tertiaryLabel))
        }
        .padding(.horizontal, 16).frame(minHeight: 52)
        .overlay(alignment: .bottom) {
            if !last {
                Color(white: 0.78).frame(height: 0.5).padding(.horizontal, 16)
            }
        }
        .contentShape(Rectangle())
    }

    private func menuRow(_ item: PrototypeUIItem, last: Bool = false) -> some View {
        Button {
            if let action = item.action {
                dispatch(action)
            }
        } label: { row(item.title, last: last) }
            .buttonStyle(.plain).accessibilityIdentifier("prototype.ui." + item.id)
    }

    private func dispatch(_ action: PrototypeUIAction) {
        presentation.dispatch(action, document: model.subscription.uiDocument)
    }
}

private struct PrototypeAccountDialog: View {
    let block: PrototypeUIBlock
    let dismiss: () -> Void
    let action: (PrototypeUIAction) -> Void
    @AccessibilityFocusState private var focused: Bool
    @State private var contentHeight: CGFloat = 185

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottom) {
                Color.black.opacity(0.2).ignoresSafeArea().onTapGesture(perform: dismiss)
                VStack(spacing: 8) {
                    ScrollView {
                        VStack(spacing: 0) {
                            VStack(spacing: 6) {
                                Text(verbatim: block.title ?? "").font(.system(size: 17, weight: .medium))
                                Text(verbatim: [block.subtitle, block.text].compactMap { $0 }.joined(separator: "\n"))
                                    .font(.system(size: 13)).foregroundStyle(PrototypeStyle.secondary)
                            }.padding(16).frame(maxWidth: .infinity, minHeight: 73)
                            ForEach((block.buttons ?? []).filter(\.isVisible)) { button in
                                Button { action(button.action) } label: {
                                    Text(verbatim: button.title).font(.system(size: 17)).frame(maxWidth: .infinity, minHeight: 56)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(PrototypeFlatStyle()).foregroundStyle(PrototypeStyle.accent)
                                .accessibilityIdentifier("prototype.ui." + button.id)
                                .overlay(alignment: .bottom) {
                                    if button.id != block.buttons?.last?.id {
                                        Color(white: 0.78).frame(height: 0.5).padding(.horizontal, 16)
                                    }
                                }
                            }
                        }
                        .frame(maxWidth: .infinity).fixedSize(horizontal: false, vertical: true)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    .frame(height: min(contentHeight, max(44, geometry.size.height - 80)))
                    .background(Color(white: 0.976), in: RoundedRectangle(cornerRadius: 24))
                    .clipShape(RoundedRectangle(cornerRadius: 24))
                    .accessibilityIdentifier("prototype.account.content")
                    Button(action: dismiss) {
                        Text("Отмена").font(.system(size: 17)).foregroundStyle(PrototypeStyle.accent)
                            .frame(maxWidth: .infinity, minHeight: 56).contentShape(Rectangle())
                    }
                    .buttonStyle(PrototypeFlatStyle())
                    .background(Color(white: 0.976), in: RoundedRectangle(cornerRadius: 24))
                }
                .frame(maxWidth: 540).padding(.horizontal, 16)
                .accessibilityElement(children: .contain).accessibilityAddTraits(.isModal)
                .accessibilityFocused($focused).accessibilityAction(.escape, dismiss)
            }
        }.onAppear { focused = true }
    }
}

private struct PrototypeSettingsView: View {
    @Environment(\.openURL) private var openURL
    var body: some View {
        Form {
            Button("Открыть системные настройки") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    openURL(url)
                }
            }
        }.navigationTitle("Настройки приложения")
            .toolbar(.visible, for: .navigationBar)
    }
}
