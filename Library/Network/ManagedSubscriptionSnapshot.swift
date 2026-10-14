import Foundation

/// The latest validated subscription. Tunnel providers read it only when starting.
public struct ManagedSubscriptionSnapshot: Codable, Equatable, Sendable {
    public static let fileName = "managed-subscription.json"
    public static let startFileName = "managed-subscription-start.json"
    public private(set) var generation = UUID()
    public let sourceURL: String
    public let planName: String
    public let remainingDays: Int
    public let singBoxConfiguration: String
    public var vkTurnLink: String?
    public var warning: String?
    public let fetchedAt: Date

    public static func decode(_ data: Data, sourceURL: String) throws -> Self {
        let response = try JSONDecoder().decode(Response.self, from: data)
        guard response.schemaVersion == 1, response.remainingDays >= 0,
              !response.planName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ManagedSubscriptionError.invalidResponse
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let configuration = try encoder.encode(response.singBox)
        guard let configText = String(data: configuration, encoding: .utf8) else { throw ManagedSubscriptionError.invalidResponse }
        let link = response.vkTurnLink?.trimmingCharacters(in: .whitespacesAndNewlines)
        return Self(sourceURL: sourceURL, planName: response.planName, remainingDays: response.remainingDays,
                    singBoxConfiguration: configText,
                    vkTurnLink: link?.isEmpty == false ? link : nil,
                    warning: response.invalidVK ? "Ссылка VK TURN некорректна. Будет использован только sing-box." : nil,
                    fetchedAt: Date())
    }

    public static func directory() throws -> URL {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "AppGroupIdentifier") as? String,
              let directory = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else {
            throw ManagedSubscriptionError.noSubscription
        }
        return directory
    }

    public static func load(in directory: URL? = nil, fileName: String = Self.fileName) throws -> Self {
        let url = try (directory ?? Self.directory()).appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: url.path) else { throw ManagedSubscriptionError.noSubscription }
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    }

    public func save(in directory: URL? = nil, fileName: String = Self.fileName) throws {
        let url = try (directory ?? Self.directory()).appendingPathComponent(fileName)
        #if os(iOS)
            try JSONEncoder().encode(self).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
            try JSONEncoder().encode(self).write(to: url, options: .atomic)
        #endif
    }

    public static func forStart(options: [String: NSObject]?, in directory: URL? = nil) throws -> Self {
        guard let generation = options?["subscriptionGeneration"] as? String else { return try load(in: directory) }
        let snapshot = try load(in: directory, fileName: startFileName)
        guard snapshot.generation.uuidString == generation else { throw ManagedSubscriptionError.noSubscription }
        return snapshot
    }

    public static func preservingActiveConfiguration(_ incoming: [String: NSObject], active: [String: NSObject]?) throws -> [String: NSObject] {
        guard let config = active?["configContent"] as? String else { throw ManagedSubscriptionError.noSubscription }
        var options = incoming
        options["configContent"] = NSString(string: config)
        options.removeValue(forKey: "priorityFailoverJSON")
        return options
    }

    private struct Response: Decodable {
        let schemaVersion: Int
        let planName: String
        let remainingDays: Int
        let singBox: [String: JSONValue]
        let vkTurnLink: String?
        let invalidVK: Bool

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
            planName = try container.decode(String.self, forKey: .planName)
            remainingDays = try container.decode(Int.self, forKey: .remainingDays)
            singBox = try container.decode([String: JSONValue].self, forKey: .singBox)
            vkTurnLink = try? container.decode(String.self, forKey: .vkTurnLink)
            invalidVK = container.contains(.vkTurnLink) && (try? container.decodeNil(forKey: .vkTurnLink)) == false && vkTurnLink == nil
        }

        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version", planName = "plan_name", remainingDays = "remaining_days"
            case singBox = "sing_box", vkTurnLink = "vk_turn_link"
        }
    }

    private indirect enum JSONValue: Codable {
        case string(String), number(Decimal), bool(Bool), object([String: JSONValue]), array([JSONValue]), null

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if container.decodeNil() { self = .null } else if let value = try? container.decode(Bool.self) { self = .bool(value) } else if let value = try? container.decode(String.self) { self = .string(value) } else if let value = try? container.decode(Decimal.self) { self = .number(value) } else if let value = try? container.decode([String: JSONValue].self) { self = .object(value) } else { self = try .array(container.decode([JSONValue].self)) }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case let .string(value): try container.encode(value)
            case let .number(value): try container.encode(value)
            case let .bool(value): try container.encode(value)
            case let .object(value): try container.encode(value)
            case let .array(value): try container.encode(value)
            case .null: try container.encodeNil()
            }
        }
    }
}

public enum ManagedSubscriptionError: LocalizedError, Equatable {
    case noSubscription, invalidURL, invalidResponse, httpStatus(Int), stopBeforeReplacing, importDisabled, refreshInProgress

    public var errorDescription: String? {
        switch self {
        case .noSubscription: return "Добавьте ссылку подписки и обновите данные."
        case .invalidURL: return "Введите HTTP(S)-ссылку подписки без логина и пароля."
        case .invalidResponse: return "Сервер вернул некорректные данные подписки."
        case let .httpStatus(status): return "Не удалось обновить подписку (HTTP \(status))."
        case .stopBeforeReplacing: return "Остановите VPN перед заменой ссылки подписки."
        case .refreshInProgress: return "Дождитесь завершения обновления подписки."
        case .importDisabled: return "Приложение работает только по единой ссылке подписки."
        }
    }
}
