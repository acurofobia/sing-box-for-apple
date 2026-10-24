import SwiftUI

@MainActor
final class PrototypePresentationCoordinator: ObservableObject {
    enum Destination: Equatable, Identifiable {
        case modes, subscription, page(String), dialog(String), external(URL), legal(PrototypeLegalDocument)
        var id: String {
            switch self {
            case .modes: return "modes"
            case .subscription: return "subscription"
            case let .page(id): return "page:" + id
            case let .dialog(id): return "dialog:" + id
            case let .external(url): return "external:" + url.absoluteString
            case let .legal(document): return "legal:" + document.rawValue
            }
        }
    }

    @Published private(set) var destination: Destination?
    @Published private(set) var drawerExpanded = false
    @Published var externalURL: URL?
    @Published var notice: String? {
        didSet {
            noticeDismissal?.cancel()
            guard notice != nil else { return }
            noticeDismissal = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .seconds(10)) } catch { return }
                self?.notice = nil
            }
        }
    }
    private var pending: Destination?
    private var dismissing = false
    private var dialogDismissal: Task<Void, Never>?
    private var noticeDismissal: Task<Void, Never>?

    func show(_ next: Destination) {
        guard destination != next else { return }
        if destination != nil || dismissing {
            guard pending == nil else { return }
            pending = next
            if destination != nil {
                dismiss()
            }
        } else {
            present(next)
        }
    }

    private func present(_ next: Destination) {
        if case let .external(url) = next {
            externalURL = url; return
        }
        destination = next
        if next == .modes {
            drawerExpanded = true
        }
    }

    func dismiss() {
        guard destination != nil else { return }
        dismissing = true
        switch destination {
        case .modes:
            drawerExpanded = false
        case .dialog:
            destination = nil
            // confirmationDialog has no onDismiss callback. Keep a single queue
            // while its native dismissal transition completes.
            dialogDismissal?.cancel()
            dialogDismissal = Task { @MainActor in
                do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
                completeDismissal()
            }
        default:
            destination = nil
        }
    }

    func completeDismissal() {
        if destination == .modes {
            destination = nil
        }
        guard destination == nil else { return }
        dismissing = false
        let next = pending
        pending = nil
        if let next {
            present(next)
        }
    }

    func dispatch(_ action: PrototypeUIAction, document: PrototypeUIDocument?) {
        switch action.type {
        case .openExternalUrl:
            if let url = action.externalURL {
                show(.external(url))
            }
        case .openScreen:
            if action.targetId == "screen01" {
                show(.subscription)
            } else {
                notice = String(localized: "Это действие пока не поддерживается приложением.")
            }
        case .openBlock:
            if let id = action.targetId, document?.block(id)?.type == .actionSheet {
                show(.dialog(id))
            } else {
                notice = String(localized: "Этот элемент сейчас недоступен.")
            }
        }
    }

    func reconcile(_ document: PrototypeUIDocument?) {
        func exists(_ target: Destination) -> Bool {
            switch target {
            case .modes: return document?.block("block04") != nil
            case let .page(id): return document?.pages.contains(where: { $0.id == id }) == true
            case let .dialog(id): return document?.block(id)?.type == .actionSheet
            default: return true
            }
        }
        if let pending, !exists(pending) {
            self.pending = nil
        }
        if let destination, !exists(destination) {
            dismiss()
        }
    }
}

struct PrototypeNoticeModifier: ViewModifier {
    @ObservedObject var presentation: PrototypePresentationCoordinator
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.overlay(alignment: .top) {
            if let notice = presentation.notice {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundStyle(.red).padding(.top, 12).accessibilityHidden(true)
                    Text(verbatim: notice)
                        .font(.subheadline).foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 12)
                        .accessibilityIdentifier("prototype.notice.message")
                    Button { presentation.notice = nil } label: {
                        Image(systemName: "xmark.circle.fill")
                            .symbolRenderingMode(.hierarchical).foregroundStyle(.secondary)
                            .frame(width: 44, height: 44).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).accessibilityLabel("Закрыть")
                    .accessibilityIdentifier("prototype.notice.close")
                }
                .padding(.leading, 16).padding(.trailing, 4)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
                .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
                .frame(maxWidth: 560).padding(.horizontal, 12).padding(.top, 8)
                .gesture(DragGesture(minimumDistance: 20).onEnded { value in
                    if value.translation.height < -20 || value.predictedEndTranslation.height < -40 {
                        presentation.notice = nil
                    }
                })
                .accessibilityAction(.escape) { presentation.notice = nil }
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: presentation.notice != nil)
    }
}
