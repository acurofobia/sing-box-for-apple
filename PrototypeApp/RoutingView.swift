import Library
import SwiftUI

struct PrototypeRoutingView: View {
    @ObservedObject var model: PrototypeModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Роутинги").font(.system(size: 34, weight: .bold)).frame(minHeight: 40)
                    .padding(.bottom, 20)
                VStack(alignment: .leading, spacing: 12) {
                    Text("Режим").font(.system(size: 13)).foregroundStyle(PrototypeStyle.secondary).padding(.horizontal, 16)
                    VStack(spacing: 0) {
                        ForEach(PrototypeRoutingMode.allCases.reversed(), id: \.self) { mode in
                            Button { Task { await model.setRoutingMode(mode) } } label: {
                                HStack(spacing: 12) {
                                    Text(verbatim: mode.title).foregroundStyle(model.routingMode == mode ? PrototypeStyle.accent : Color.primary)
                                    Spacer()
                                    Image(model.routingMode == mode ? "ModeSelected" : "ModeUnselected")
                                        .resizable().frame(width: 28, height: 28).accessibilityHidden(true)
                                }
                                .font(.system(size: 17)).padding(.horizontal, 16).frame(minHeight: 52).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain).disabled(model.busy)
                            .accessibilityAddTraits(model.routingMode == mode ? .isSelected : [])
                            .accessibilityIdentifier(mode == .enabled ? "prototype.routing.enabled" : "prototype.routing.russiaInside")
                            if mode == .enabled { divider }
                        }
                    }
                    .background(.white, in: RoundedRectangle(cornerRadius: 24))
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("prototype.routing.mode")
                }
                .padding(.bottom, 32)
                VStack(alignment: .leading, spacing: 12) {
                    Text("Обновление списков").font(.system(size: 13)).foregroundStyle(PrototypeStyle.secondary).padding(.horizontal, 16)
                    VStack(spacing: 0) {
                        information("Загрузка", value: "Через VPN")
                        divider
                        information("Интервал", value: "Раз в сутки")
                    }
                    .background(.white, in: RoundedRectangle(cornerRadius: 24))
                }
            }
            .padding(.horizontal, 16).padding(.top, 64).padding(.bottom, 24)
            .frame(maxWidth: 574).frame(maxWidth: .infinity)
        }
        .background(PrototypeStyle.field).toolbar(.hidden, for: .navigationBar)
        .ignoresSafeArea(.container, edges: .top)
    }

    private var divider: some View {
        PrototypeStyle.separator.frame(height: 0.5).padding(.horizontal, 16)
    }

    private func information(_ title: String, value: String) -> some View {
        HStack {
            Text(verbatim: title)
            Spacer(minLength: 12)
            Text(verbatim: value).foregroundStyle(PrototypeStyle.secondary).multilineTextAlignment(.trailing)
        }
        .font(.system(size: 17)).padding(.horizontal, 16).frame(minHeight: 52)
    }
}
