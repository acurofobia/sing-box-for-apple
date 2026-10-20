import Foundation
import Library

struct PrototypePriorityFailoverPolicy: Codable, Sendable {
    var selector: String
    var primary: String
    var backups: [String]
    var intervalMilliseconds: Int
    var timeoutMilliseconds: Int
    var failureThreshold: Int
    var recoveryThreshold: Int
}

struct PrototypeVLESSProvisioning: Codable, Sendable {
    struct Outbound: Codable, Sendable {
        struct TLS: Codable, Sendable {
            struct UTLS: Codable, Sendable { var enabled: Bool; var fingerprint: String }
            struct Reality: Codable, Sendable { var enabled: Bool; var public_key: String; var short_id: String }
            var enabled: Bool
            var server_name: String
            var utls: UTLS
            var reality: Reality
            var alpn: [String]?
        }

        var type: String
        var tag: String
        var server: String
        var server_port: Int
        var uuid: String
        var flow: String?
        var tls: TLS
    }

    var schemaVersion: Int
    var kind: String
    var state: String
    var reason: String?
    var outbounds: [Outbound]
    var failover: PrototypePriorityFailoverPolicy?

    var isAvailable: Bool {
        state == "available"
    }
}

/// A complete provisioning snapshot; routing and DNS remain application-owned.
struct PrototypeSubscription: Codable, Sendable {
    var uiURL: String?
    var uiToken: String?
    var uiDocument: PrototypeUIDocument?
    var updatedAt: Date?
    var isComplete: Bool {
        sourceURL != nil && uiURL != nil && uiDocument != nil && updatedAt != nil
    }

    func isAvailable(optionID: String) -> Bool {
        guard isComplete, let item = uiDocument?.block("block04")?.items?.first(where: { $0.id == optionID }),
              item.isVisible, item.state == .available else { return false }
        switch optionID {
        case "option01": return vlessOutbound != nil || vlessProvisioning?.isAvailable == true
        case "option02": return vkTurnLink != nil
        default: return false
        }
    }

    var sourceURL: String?
    var singBoxURL: String?
    var vlessOutbound: Data?
    var vlessProvisioning: PrototypeVLESSProvisioning?
    var vkTurnLink: String?
    var warnings: [String] = []

    func validateVLESS() throws {
        guard vlessOutbound == nil || vlessProvisioning == nil else { throw PrototypeSubscriptionError.invalidVLESS }
        if let vlessProvisioning {
            _ = try Self.decodeVLESSProvisioning(JSONEncoder().encode(vlessProvisioning))
        }
        if let vlessOutbound {
            guard try Self.extractVLESS(vlessOutbound) != nil else { throw PrototypeSubscriptionError.invalidVLESS }
        }
    }

    static func decodeVLESSProvisioning(_ data: Data) throws -> PrototypeVLESSProvisioning {
        guard data.count <= 8 * 1024 * 1024,
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(root.keys).isSubset(of: ["schemaVersion", "kind", "state", "reason", "outbounds", "failover"])
        else { throw PrototypeSubscriptionError.invalidVLESS }
        let doc = try JSONDecoder().decode(PrototypeVLESSProvisioning.self, from: data)
        guard doc.schemaVersion == 1, doc.kind == "vless-failover" else { throw PrototypeSubscriptionError.invalidVLESS }
        if doc.state != "available" {
            guard ["restricted", "unavailable"].contains(doc.state), doc.outbounds.isEmpty, doc.failover == nil,
                  ["not_allowed", "traffic_limited"].contains(doc.reason ?? "") else { throw PrototypeSubscriptionError.invalidVLESS }
            return doc
        }
        guard doc.reason == nil, doc.outbounds.count == 4, let policy = doc.failover,
              let rawPolicy = root["failover"] as? [String: Any],
              Set(rawPolicy.keys) == ["selector", "primary", "backups", "intervalMilliseconds", "timeoutMilliseconds", "failureThreshold", "recoveryThreshold"],
              policy.selector == "vk-wg", policy.backups.count == 3,
              policy.intervalMilliseconds == 10000, policy.timeoutMilliseconds == 5000,
              policy.failureThreshold == 2, policy.recoveryThreshold == 3,
              Set([policy.primary] + policy.backups).count == 4,
              Set(doc.outbounds.map(\.tag)) == Set([policy.primary] + policy.backups),
              let rawNodes = root["outbounds"] as? [[String: Any]]
        else { throw PrototypeSubscriptionError.invalidVLESS }
        for (node, raw) in zip(doc.outbounds, rawNodes) {
            guard Set(raw.keys).isSubset(of: ["type", "tag", "server", "server_port", "uuid", "flow", "tls"]),
                  node.type == "vless", !["direct", "vk-wg"].contains(node.tag),
                  node.tag.range(of: #"^[A-Za-z0-9_.-]{1,64}$"#, options: .regularExpression) == node.tag.startIndex ..< node.tag.endIndex,
                  !node.server.isEmpty, !node.server.contains(where: { $0.isWhitespace || $0.isNewline }),
                  (1 ... 65535).contains(node.server_port), UUID(uuidString: node.uuid) != nil,
                  ["", "xtls-rprx-vision"].contains(node.flow ?? ""),
                  let tls = raw["tls"] as? [String: Any],
                  Set(tls.keys).isSubset(of: ["enabled", "server_name", "utls", "reality", "alpn"]),
                  let utls = tls["utls"] as? [String: Any], Set(utls.keys) == ["enabled", "fingerprint"],
                  let reality = tls["reality"] as? [String: Any], Set(reality.keys) == ["enabled", "public_key", "short_id"],
                  node.tls.enabled, node.tls.utls.enabled, node.tls.reality.enabled,
                  !node.tls.server_name.isEmpty,
                  ["chrome", "firefox", "edge", "safari", "ios", "android", "random", "randomized", "360", "qq"].contains(node.tls.utls.fingerprint),
                  node.tls.reality.public_key.range(of: #"^[A-Za-z0-9_-]{43}$"#, options: .regularExpression) == node.tls.reality.public_key.startIndex ..< node.tls.reality.public_key.endIndex,
                  node.tls.reality.short_id.range(of: #"^(?:[0-9a-fA-F]{2}){0,8}$"#, options: .regularExpression) == node.tls.reality.short_id.startIndex ..< node.tls.reality.short_id.endIndex,
                  node.tls.alpn?.allSatisfy({ !$0.isEmpty }) ?? true
            else { throw PrototypeSubscriptionError.invalidVLESS }
        }
        return doc
    }

    static func decode(_ data: Data) throws -> Self {
        guard data.count <= 8 * 1024 * 1024,
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw PrototypeSubscriptionError.invalidResponse
        }
        var subscription = Self()
        if let value = root["ui_url"], !(value is NSNull) {
            guard let source = value as? String else { throw PrototypeSubscriptionError.invalidResponse }
            _ = try validatedURL(source)
            subscription.uiURL = source
        }
        if let value = root["ui_token"], !(value is NSNull) {
            guard let token = value as? String,
                  token.range(of: #"^[A-Za-z0-9_-]{16,256}$"#, options: .regularExpression) == token.startIndex ..< token.endIndex
            else {
                throw PrototypeSubscriptionError.invalidResponse
            }
            subscription.uiToken = token
        }
        if let value = root["sing_box_url"], !(value is NSNull) {
            do {
                guard let link = value as? String else { throw PrototypeSubscriptionError.invalidURL }
                let source = link.trimmingCharacters(in: .whitespacesAndNewlines)
                if !source.isEmpty {
                    _ = try validatedURL(source)
                    subscription.singBoxURL = source
                }
            } catch {
                subscription.warnings.append("Ссылка sing-box некорректна. Режим VLESS недоступен.")
            }
        }
        if let value = root["vk_turn_link"], !(value is NSNull) {
            if let link = value as? String, link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return subscription
            }
            do {
                guard let link = value as? String else { throw VKTurnError.invalidLink }
                _ = try VKTurnConfiguration.importLink(link)
                subscription.vkTurnLink = link.trimmingCharacters(in: .whitespacesAndNewlines)
            } catch {
                subscription.warnings.append("Ссылка VK TURN некорректна. Режим недоступен.")
            }
        }
        return subscription
    }

    static func extractVLESS(_ data: Data) throws -> Data? {
        guard data.count <= 8 * 1024 * 1024,
              let config = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw PrototypeSubscriptionError.invalidVLESS
        }
        let nodes: [[String: Any]]
        if config["type"] as? String == "vless" {
            nodes = [config]
        } else if let outbounds = config["outbounds"] as? [[String: Any]] {
            nodes = outbounds.filter { $0["type"] as? String == "vless" }
        } else {
            throw PrototypeSubscriptionError.invalidVLESS
        }
        if nodes.isEmpty {
            return nil
        }
        let preferred = nodes.filter { $0["tag"] as? String == "R3-N1" }
        let candidates = preferred.isEmpty ? nodes : preferred
        guard candidates.count == 1, let node = candidates.first,
              let server = node["server"] as? String, !server.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let port = node["server_port"] as? NSNumber, CFGetTypeID(port) != CFBooleanGetTypeID(),
              port.doubleValue == Double(port.intValue), (1 ... 65535).contains(port.intValue),
              let uuid = node["uuid"] as? String, UUID(uuidString: uuid) != nil,
              node["detour"] == nil
        else {
            throw PrototypeSubscriptionError.invalidVLESS
        }
        return try JSONSerialization.data(withJSONObject: node, options: [.sortedKeys])
    }

    static func validatedURL(_ source: String) throws -> URL {
        guard let url = URL(string: source), let host = url.host, !host.isEmpty,
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.user == nil, url.password == nil, url.fragment == nil
        else {
            throw PrototypeSubscriptionError.invalidURL
        }
        return url
    }

    static func download(_ source: String) async throws -> Self {
        try await PrototypeSubscriptionLoader.download(source)
    }
}

enum PrototypeSubscriptionError: LocalizedError {
    case invalidResponse, invalidVLESS, invalidURL, missingConfiguration, stopBeforeImport, notReady, serverUpdateRequired, responseTooLarge, httpStatus(Int)

    var errorDescription: String? {
        switch self {
        case .serverUpdateRequired: return String(localized: "Обновите сервер подписки: отсутствует ссылка на оформление.")
        case .responseTooLarge: return String(localized: "Ответ сервера превышает допустимый размер.")
        case .notReady: return "Дождитесь загрузки состояния VPN. Если произошла ошибка, перезапустите приложение."
        case .invalidResponse: return "Сервер вернул некорректные данные подписки."
        case .invalidVLESS: return "Нужен JSON с одним VLESS-сервером или сервером R3-N1 без detour."
        case .invalidURL: return "Введите HTTP(S)-ссылку подписки без логина и пароля."
        case .missingConfiguration: return "Импортируйте конфигурацию для выбранного режима."
        case .stopBeforeImport: return "Остановите VPN перед изменением конфигураций."
        case let .httpStatus(status): return "Не удалось получить подписку (HTTP \(status))."
        }
    }
}
