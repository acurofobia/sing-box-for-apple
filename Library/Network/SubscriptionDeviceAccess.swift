import Darwin
import Foundation

public enum SubscriptionDeviceAccessState: String, Codable, Sendable {
    case allowed
    case revoked = "device_revoked"
    case limitReached = "device_limit_reached"
    case notAllowed = "not_allowed"

    public var isDenied: Bool { self != .allowed }
    public var message: String {
        switch self {
        case .allowed: return ""
        case .revoked: return String(localized: "Доступ для этого устройства отозван")
        case .limitReached: return String(localized: "Лимит устройств исчерпан")
        case .notAllowed: return String(localized: "Обход белых списков недоступен для этого устройства")
        }
    }
}

public enum SubscriptionDeviceAccessError: LocalizedError {
    case invalidResponse
    case denied(SubscriptionDeviceAccessState)

    public var errorDescription: String? {
        switch self {
        case .invalidResponse: return String(localized: "Не удалось проверить доступ устройства.")
        case .denied(let state): return state.message
        }
    }
}

public struct SubscriptionDeviceAccessDecision: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let hwid: String
    public let state: SubscriptionDeviceAccessState
    public let revision: Int64

    public static func decode(_ data: Data, hwid: String) throws -> Self {
        guard data.count <= 16 * 1024,
              let decision = try? JSONDecoder().decode(Self.self, from: data),
              decision.schemaVersion == 1, decision.hwid == hwid, decision.revision >= 0
        else { throw SubscriptionDeviceAccessError.invalidResponse }
        return decision
    }
}

/// Keep saved subscription and runtime credentials consistent with received access decisions.
public struct SubscriptionDeviceAccessStore: Sendable {
    public let cacheURL: URL
    public init(cacheURL: URL) { self.cacheURL = cacheURL }

    public func withLock<T>(_ action: () throws -> T) throws -> T {
        let directory = cacheURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("device-access.lock").path
        let descriptor = open(path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { flock(descriptor, LOCK_UN) }
        return try action()
    }

    private func decisionURL(source: String) -> URL {
        cacheURL.deletingLastPathComponent().appendingPathComponent("device-access-" + SubscriptionDeviceIdentity.digest(source) + ".json")
    }

    public func decision(forSource source: String) throws -> SubscriptionDeviceAccessDecision? {
        let url = decisionURL(source: source)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        let decoded = try JSONDecoder().decode(SubscriptionDeviceAccessDecision.self, from: data)
        guard SubscriptionDeviceIdentity.isValid(decoded.hwid) else { throw SubscriptionDeviceAccessError.invalidResponse }
        return try SubscriptionDeviceAccessDecision.decode(data, hwid: decoded.hwid)
    }

    /// Must share the snapshot lock with runtime writes: a late A response cannot clear B's key.
    public func purgeRuntimeIfDenied(source: String) throws {
        try withLock {
            guard FileManager.default.fileExists(atPath: cacheURL.path),
                  let root = try JSONSerialization.jsonObject(with: Data(contentsOf: cacheURL)) as? [String: Any],
                  root["sourceURL"] as? String == source,
                  let decision = try decision(forSource: source), decision.state.isDenied else { return }
            try VKTurnConfigurationStore.clear()
        }
    }

    public func withAllowedWDTT(source: String?, _ action: () throws -> Void) throws {
        try withLock {
            if let source, FileManager.default.fileExists(atPath: cacheURL.path) {
                let root = try JSONSerialization.jsonObject(with: Data(contentsOf: cacheURL)) as? [String: Any]
                guard root?["sourceURL"] as? String == source else { throw CancellationError() }
            }
            if let source, let decision = try decision(forSource: source), decision.state.isDenied {
                throw SubscriptionDeviceAccessError.denied(decision.state)
            }
            try action()
        }
    }

    @discardableResult public func record(_ incoming: SubscriptionDeviceAccessDecision, source: String) throws -> SubscriptionDeviceAccessDecision {
        guard SubscriptionDeviceRequest.sameOrigin(source, source) else { throw SubscriptionDeviceAccessError.invalidResponse }
        return try withLock {
            let previous = try decision(forSource: source)
            let effective: SubscriptionDeviceAccessDecision
            if let previous, incoming.revision <= previous.revision {
                guard incoming.revision != previous.revision || incoming == previous else { throw SubscriptionDeviceAccessError.invalidResponse }
                effective = previous
            } else {
                effective = incoming
                try JSONEncoder().encode(effective).write(to: decisionURL(source: source), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            }
            if effective.state.isDenied, FileManager.default.fileExists(atPath: cacheURL.path) {
                let cached = try Data(contentsOf: cacheURL)
                if let root = try JSONSerialization.jsonObject(with: cached) as? [String: Any],
                   root["sourceURL"] as? String == source {
                    let data = try sanitizeUnlocked(JSONSerialization.data(withJSONObject: root))
                    try data.write(to: cacheURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                }
            }
            return effective
        }
    }

    public func commitSnapshot(_ data: Data) throws -> Data {
        try withLock {
            let sanitized = try sanitizeUnlocked(data)
            try sanitized.write(to: cacheURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            return sanitized
        }
    }

    public func sanitizedSnapshot(_ data: Data) throws -> Data {
        try withLock { try sanitizeUnlocked(data) }
    }

    private func sanitizeUnlocked(_ data: Data) throws -> Data {
        guard var root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return data }
        guard let source = root["sourceURL"] as? String,
              let decision = try decision(forSource: source), decision.state.isDenied else {
            return try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
        }
        root.removeValue(forKey: "vkTurnLink")
        root["wdttAccessState"] = decision.state.rawValue
        if var ui = root["uiDocument"] as? [String: Any], var blocks = ui["blocks"] as? [[String: Any]] {
            for index in blocks.indices where blocks[index]["id"] as? String == "block04" {
                guard var items = blocks[index]["items"] as? [[String: Any]] else { continue }
                for item in items.indices where items[item]["id"] as? String == "option02" {
                    items[item]["state"] = "unavailable"
                    items[item]["stateText"] = decision.state.message
                    items[item]["buttons"] = []
                }
                blocks[index]["items"] = items
            }
            ui["blocks"] = blocks
            root["uiDocument"] = ui
        }
        return try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
    }
}

public enum SubscriptionDeviceRequest {
    public static func sameOrigin(_ source: String, _ destination: String) -> Bool {
        guard let origin = URLComponents(string: source), let target = URLComponents(string: destination),
              let host = origin.host?.lowercased(), let scheme = origin.scheme?.lowercased(),
              origin.user == nil, origin.password == nil, target.user == nil, target.password == nil,
              origin.fragment == nil, target.fragment == nil,
              scheme == "https" || (scheme == "http" && ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host))
        else { return false }
        return target.scheme?.lowercased() == scheme && target.host?.lowercased() == host
            && (target.port ?? (scheme == "https" ? 443 : 80)) == (origin.port ?? (scheme == "https" ? 443 : 80))
    }

    public static func request(_ url: URL, deviceHeaders: [String: String]) -> URLRequest {
        var request = URLRequest(url: url)
        for (key, value) in deviceHeaders { request.setValue(value, forHTTPHeaderField: key) }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        request.setValue("VipinApp/" + version + " (" + (deviceHeaders["x-device-os"] ?? "iOS") + ")", forHTTPHeaderField: "User-Agent")
        request.setValue("vipin-v1", forHTTPHeaderField: "X-Subscription-Format")
        request.setValue("vless-failover-v1 device-access-v1", forHTTPHeaderField: "X-Subscription-Capabilities")
        return request
    }
}
