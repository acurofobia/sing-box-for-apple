import SwiftUI

struct PrototypeModeDrawer: View {
    @ObservedObject var model: PrototypeModel
    @ObservedObject var presentation: PrototypePresentationCoordinator
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AccessibilityFocusState private var focused: Bool
    @ScaledMetric(relativeTo: .headline) private var headerHeight: CGFloat = 52
    @State private var progress: CGFloat = 0
    @State private var drag: CGFloat = 0
    @State private var contentHeight: CGFloat = 404
    @State private var closing = false
    @State private var openingWithGesture = false

    private var choices: [PrototypeUIItem] {
        model.subscription.uiDocument?.block("block04")?.items?.filter(\.isVisible) ?? []
    }

    var body: some View {
        GeometryReader { geometry in
            let height = min(max(100, contentHeight + headerHeight), max(100, geometry.size.height - 12))
            let travel = max(1, height - headerHeight)
            let fraction = min(1, max(0, progress + drag / travel))
            ZStack(alignment: .top) {
                PrototypeStyle.accent
                    .frame(height: geometry.safeAreaInsets.top)
                    .offset(y: -geometry.safeAreaInsets.top)
                    .allowsHitTesting(false)
                if presentation.destination == .modes {
                    Color.black.opacity(0.2 * (reduceMotion ? progress : fraction))
                        .ignoresSafeArea().contentShape(Rectangle())
                        .onTapGesture { presentation.dismiss() }
                        .accessibilityLabel("Закрыть выбор режима")
                        .accessibilityIdentifier("prototype.mode.scrim")
                        .accessibilityAction { presentation.dismiss() }
                }
                VStack(spacing: 0) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            if let block = model.subscription.uiDocument?.block("block04") {
                                if let title = block.title {
                                    Text(verbatim: title).font(.headline).foregroundStyle(.white).padding(.horizontal, 4)
                                }
                                if let subtitle = block.subtitle {
                                    Text(verbatim: subtitle).foregroundStyle(.white).padding(.horizontal, 4)
                                }
                                if let text = block.text {
                                    Text(verbatim: text).foregroundStyle(.white).padding(.horizontal, 4)
                                }
                            }
                            ForEach(choices) { item in choice(item) }
                            if choices.isEmpty {
                                Text("Нет доступных режимов").foregroundStyle(.white).padding(16)
                            }
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    .frame(height: travel)
                    .frame(height: reduceMotion ? (progress > 0 ? travel : 0) : travel * fraction, alignment: .bottom)
                    .clipped()
                    .contentShape(Rectangle())
                    .allowsHitTesting(presentation.destination == .modes)
                    .transaction {
                        if reduceMotion {
                            $0.animation = nil
                        }
                    }
                    .opacity(reduceMotion ? progress : 1)
                    .accessibilityHidden(presentation.destination != .modes)
                    VStack(spacing: 0) {
                        Button(action: toggleDrawer) {
                            HStack(spacing: 8) {
                                Text("Режим подключения").font(.system(size: 17))
                                Spacer(minLength: 0)
                                Text(verbatim: model.modeTitle).font(.system(size: 15))
                                Image(systemName: "chevron.down")
                                    .rotationEffect(.degrees(-180 * (reduceMotion ? (presentation.drawerExpanded ? 1 : 0) : fraction)))
                                    .font(.system(size: 15, weight: .medium)).frame(width: 20)
                            }
                            .foregroundStyle(.white).padding(.leading, 16).padding(.trailing, 12)
                            .frame(maxWidth: .infinity, minHeight: headerHeight - 8)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(PrototypeFlatStyle())
                        .accessibilityIdentifier(presentation.destination == .modes ? "prototype.mode.close" : "prototype.mode")
                        .accessibilityValue(model.modeTitle)
                        .accessibilityFocused($focused)
                        Button(action: toggleDrawer) {
                            Capsule().fill(.white.opacity(0.65)).frame(width: 60, height: 4)
                                .frame(maxWidth: .infinity).frame(height: 8, alignment: .top)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(PrototypeFlatStyle())
                        .accessibilityLabel("Режим подключения")
                        .accessibilityIdentifier("prototype.mode.handle")
                    }
                    .contentShape(Rectangle())
                    .highPriorityGesture(drawerGesture(travel: travel))
                }
                .background(PrototypeStyle.accent, in: UnevenRoundedRectangle(bottomLeadingRadius: 10, bottomTrailingRadius: 10))
                .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: 10, bottomTrailingRadius: 10))
                .frame(maxWidth: 540)
                .zIndex(1)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .accessibilityElement(children: .contain)
            .accessibilityAddTraits(presentation.destination == .modes ? .isModal : [])
            .accessibilityAction(.escape) { presentation.dismiss() }
            .accessibilityIdentifier("prototype.mode.drawer")
        }
        .onAppear {
            if presentation.drawerExpanded {
                focused = true; animate(to: 1)
            }
        }
        .onChange(of: presentation.drawerExpanded) { _, expanded in
            if expanded {
                focused = true
                if !openingWithGesture {
                    animate(to: 1)
                }
            } else {
                closing = true; animate(to: 0)
            }
        }
    }

    private func toggleDrawer() {
        if presentation.destination == .modes {
            presentation.dismiss()
        } else {
            presentation.show(.modes)
        }
    }

    private func drawerGesture(travel: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .global)
            .onChanged { value in
                guard !closing, abs(value.translation.height) > abs(value.translation.width) else { return }
                if presentation.destination == nil, value.translation.height > 0 {
                    openingWithGesture = true
                    progress = 0
                    presentation.show(.modes)
                }
                if presentation.destination == .modes {
                    drag = value.translation.height
                }
            }
            .onEnded { value in
                guard presentation.destination == .modes, !closing else { return }
                let wasOpening = openingWithGesture
                let threshold = min(80, travel / 2)
                let target = wasOpening
                    ? value.predictedEndTranslation.height > threshold
                    : value.predictedEndTranslation.height > -threshold
                progress = min(1, max(0, progress + drag / travel))
                drag = 0
                openingWithGesture = false
                if target {
                    animate(to: 1)
                } else {
                    presentation.dismiss()
                }
            }
    }

    private func animate(to value: CGFloat) {
        withAnimation(reduceMotion ? .easeOut(duration: 0.12) : .spring(duration: 0.3), completionCriteria: .removed) {
            progress = value
        } completion: {
            if value == 0, !presentation.drawerExpanded {
                closing = false
                presentation.completeDismissal()
            }
        }
    }

    private func choice(_ item: PrototypeUIItem) -> some View {
        let mode = PrototypeConnectionMode.from(optionID: item.id)
        let available = mode.map { model.isAvailable($0) } ?? false
        let selected = mode == model.connectionMode && model.hasSelectedMode
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                Button {
                    guard let mode, available else { return }
                    Task { await model.switchConnection(to: mode) }
                    presentation.dismiss()
                } label: {
                    Text(verbatim: item.title).font(.system(size: 17)).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
                }
                .buttonStyle(PrototypeFlatStyle())
                .disabled(!available || model.busy || model.replacingSubscription || (model.canStop && model.status != "Подключено"))
                .accessibilityIdentifier("prototype.ui." + item.id)
                .accessibilityValue(selected ? String(localized: "Выбрано") : availability(item, mode: mode, available: available))
                .padding(.vertical, -8)
                if available, let id = item.detailsPageId {
                    Button { presentation.show(.page(id)) } label: { Text("Подробнее").font(.system(size: 15)).frame(minHeight: 44).contentShape(Rectangle()) }
                        .buttonStyle(PrototypeFlatStyle()).foregroundStyle(PrototypeStyle.accent)
                        .padding(.vertical, -8)
                        .accessibilityIdentifier("prototype.ui." + item.id + ".details")
                } else if !available {
                    Text(verbatim: availability(item, mode: mode, available: available)).font(.system(size: 15))
                        .foregroundStyle(PrototypeStyle.secondary)
                }
            }
            HStack(spacing: 12) {
                if let text = item.text {
                    Text(verbatim: text).font(.system(size: 15)).lineSpacing(2.7).foregroundStyle(PrototypeStyle.secondary)
                        .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
                }
                if mode != nil, item.state != .restricted {
                    Button {
                        guard let mode, available else { return }
                        Task { await model.switchConnection(to: mode) }
                        presentation.dismiss()
                    } label: {
                        Image(selected ? "ModeSelected" : "ModeUnselected").resizable().frame(width: 28, height: 28)
                            .frame(width: 44, height: 44).contentShape(Rectangle())
                    }
                    .buttonStyle(PrototypeFlatStyle()).disabled(!available || model.busy || model.replacingSubscription || (model.canStop && model.status != "Подключено"))
                    .padding(-8)
                    .accessibilityLabel(Text(verbatim: item.title))
                }
            }.padding(.top, 4)
            if item.state == .restricted, mode != nil {
                ForEach((item.buttons ?? []).filter(\.isVisible)) { button in
                    Button { presentation.dispatch(button.action, document: model.subscription.uiDocument) } label: {
                        Text(verbatim: button.title).font(.system(size: 17)).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(PrototypePillStyle(filled: true)).padding(.top, 13)
                    .accessibilityIdentifier("prototype.ui." + button.id)
                }
            }
        }
        .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 12)
        .frame(maxWidth: .infinity, minHeight: item.id == "option01" ? 136 : (item.state == .restricted ? 158 : 116), alignment: .topLeading)
        .foregroundStyle(available ? .primary : PrototypeStyle.secondary)
        .background(.white, in: RoundedRectangle(cornerRadius: 20))
    }

    private func availability(_ item: PrototypeUIItem, mode: PrototypeConnectionMode?, available: Bool) -> String {
        if item.id == "option03" {
            return String(localized: "В разработке")
        }
        if mode == nil {
            return String(localized: "Этот режим пока не поддерживается приложением.")
        }
        if let text = item.stateText {
            return text
        }
        return available ? String(localized: "Доступно") : String(localized: "Режим недоступен")
    }
}
