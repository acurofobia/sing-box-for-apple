import Foundation

public struct PriorityFailoverStatus: Codable, Sendable {
    public let mode: String
    public let selected: String?
    public let primaryHealth: String?
    public let allDown: Bool
    public let checking: String?
    public let selectedHealth: String?
    public let selectedIndex: Int?
    public let checkingIndex: Int?
    public let total: Int?
    public let servers: [Server]?

    public struct Server: Codable, Sendable {
        public let tag: String
        public let health: String
    }

    public enum ServerState: Sendable {
        case connected, reserve, unavailable, checking

        public var title: String {
            switch self {
            case .connected: return String(localized: "Подключён")
            case .reserve: return String(localized: "Резерв")
            case .unavailable: return String(localized: "Недоступен")
            case .checking: return String(localized: "Проверка…")
            }
        }
    }

    public func state(for tag: String, connected: Bool) -> ServerState {
        if connected, selected == tag, selectedHealth == "up" { return .connected }
        if checking == tag { return .checking }
        if servers?.first(where: { $0.tag == tag })?.health == "down" || (selected == tag && selectedHealth == "down") {
            return .unavailable
        }
        if selected == tag { return .checking }
        return .reserve
    }

    public func serverDescription(connected: Bool) -> String {
        let active = serverLabel(selected, index: selectedIndex)
        if connected, selectedHealth == "up", let active {
            return String(localized: "Подключён: \(active)")
        }
        if let attempt = serverLabel(checking, index: checkingIndex) {
            return String(localized: "Подключение: \(attempt)")
        }
        if allDown {
            return String(localized: "Все серверы недоступны")
        }
        if let active {
            if selectedHealth == "down" {
                return String(localized: "Недоступен: \(active)")
            }
            return connected ? String(localized: "Проверка: \(active)") : String(localized: "Подключение: \(active)")
        }
        return String(localized: "Проверка соединения…")
    }

    private func serverLabel(_ tag: String?, index: Int?) -> String? {
        guard let tag, !tag.isEmpty, let index, let total, total > 0, (1 ... total).contains(index) else { return nil }
        return String(localized: "\(tag) (\(index) из \(total))")
    }
}
