import Foundation
import Library

/// Stores connection data only; routing and DNS always come from the application.
struct PrototypeSubscription: Codable {
    var sourceURL: String?
    var singBoxURL: String?
    var vlessOutbound: Data?
    var vkTurnLink: String?
    var warnings: [String] = []

    static func decode(_ data: Data) throws -> Self {
        guard data.count <= 8 * 1024 * 1024,
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw PrototypeSubscriptionError.invalidResponse
        }
        var subscription = Self()
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
              let config = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
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
        if nodes.isEmpty { return nil }
        let preferred = nodes.filter { $0["tag"] as? String == "R3-N1" }
        let candidates = preferred.isEmpty ? nodes : preferred
        guard candidates.count == 1, let node = candidates.first,
              let server = node["server"] as? String, !server.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let port = node["server_port"] as? NSNumber, CFGetTypeID(port) != CFBooleanGetTypeID(),
              port.doubleValue == Double(port.intValue), (1...65535).contains(port.intValue),
              let uuid = node["uuid"] as? String, UUID(uuidString: uuid) != nil,
              node["detour"] == nil else {
            throw PrototypeSubscriptionError.invalidVLESS
        }
        return try JSONSerialization.data(withJSONObject: node, options: [.sortedKeys])
    }

    private static func validatedURL(_ source: String) throws -> URL {
        guard let url = URL(string: source), let host = url.host, !host.isEmpty,
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.user == nil, url.password == nil, url.fragment == nil
        else {
            throw PrototypeSubscriptionError.invalidURL
        }
        return url
    }

    private static func downloadData(_ url: URL, session: URLSession) async throws -> Data {
        let (data, response) = try await session.data(from: url)
        guard let response = response as? HTTPURLResponse else { throw PrototypeSubscriptionError.invalidResponse }
        guard response.statusCode == 200 else { throw PrototypeSubscriptionError.httpStatus(response.statusCode) }
        return data
    }

    static func download(_ source: String) async throws -> Self {
        let url = try validatedURL(source)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 10
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: configuration, delegate: PrototypeSubscriptionRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let data = try await downloadData(url, session: session)
        var result: Self
        do { result = try decode(data) } catch { throw PrototypeSubscriptionError.invalidResponse }
        if let configSource = result.singBoxURL {
            let config = try await downloadData(validatedURL(configSource), session: session)
            do {
                result.vlessOutbound = try extractVLESS(config)
            } catch {
                result.warnings.append("Конфигурация VLESS некорректна. Режим недоступен.")
            }
        }
        result.sourceURL = source
        return result
    }
}

private final class PrototypeSubscriptionRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_: URLSession, task _: URLSessionTask, willPerformHTTPRedirection _: HTTPURLResponse,
                    newRequest _: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

enum PrototypeSubscriptionError: LocalizedError {
    case invalidResponse, invalidVLESS, invalidURL, missingConfiguration, stopBeforeImport, notReady, httpStatus(Int)

    var errorDescription: String? {
        switch self {
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
