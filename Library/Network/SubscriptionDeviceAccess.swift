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
    fileprivate static let maximumBytes = 16 * 1024
    public let schemaVersion: Int
    public let hwid: String
    public let state: SubscriptionDeviceAccessState
    public let revision: Int64

    public static func decode(_ data: Data, hwid: String) throws -> Self {
        let decision = try decode(data)
        guard decision.hwid == hwid else { throw SubscriptionDeviceAccessError.invalidResponse }
        return decision
    }

    fileprivate static func decode(_ data: Data) throws -> Self {
        guard data.count <= maximumBytes,
              let decision = try? JSONDecoder().decode(Self.self, from: data),
              decision.schemaVersion == 1, SubscriptionDeviceIdentity.isValid(decision.hwid), decision.revision >= 0
        else { throw SubscriptionDeviceAccessError.invalidResponse }
        return decision
    }
}

public enum SubscriptionDeviceAccessRecord: Sendable {
    case verified(SubscriptionDeviceAccessDecision)
    case unverified

    public var state: SubscriptionDeviceAccessState {
        switch self {
        case .verified(let decision): return decision.state
        case .unverified: return .notAllowed
        }
    }
}

/// Keep saved subscription and runtime credentials consistent with received access decisions.
public struct SubscriptionDeviceAccessStore: Sendable {
    public let cacheURL: URL
    public init(cacheURL: URL) { self.cacheURL = cacheURL }

    private func openLock(_ name: String) throws -> FileHandle {
        let directory = cacheURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent(name).path
        let descriptor = open(path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    public func withLock<T>(_ action: () throws -> T) async throws -> T {
        let file = try await acquireLock()
        defer { try? file.close() }
        return try action()
    }

    /// Closing the handle releases the lock. A waiting transaction can be cancelled by its caller.
    public func acquireLock() async throws -> FileHandle {
        try await acquireLock("device-access.lock")
    }

    private func acquireLock(_ name: String) async throws -> FileHandle {
        let file = try openLock(name)
        let deadline = DispatchTime.now() + .seconds(15)
        while true {
            try Task.checkCancellation()
            if flock(file.fileDescriptor, LOCK_EX | LOCK_NB) == 0 {
                return file
            }
            let code = errno
            guard code == EWOULDBLOCK || code == EINTR else { throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO) }
            guard DispatchTime.now() < deadline else { throw POSIXError(.ETIMEDOUT) }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    private func decisionURL(source: String) -> URL {
        cacheURL.deletingLastPathComponent().appendingPathComponent("device-access-" + SubscriptionDeviceIdentity.digest(source) + ".json")
    }

    private func readIfPresent(_ url: URL) throws -> Data? {
        do { return try Data(contentsOf: url) } catch CocoaError.fileReadNoSuchFile { return nil }
    }

    public func decision(forSource source: String) throws -> SubscriptionDeviceAccessRecord? {
        let file: FileHandle
        do {
            file = try FileHandle(forReadingFrom: decisionURL(source: source))
        } catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
            return nil
        }
        defer { try? file.close() }
        let data = try file.read(upToCount: SubscriptionDeviceAccessDecision.maximumBytes + 1) ?? Data()
        guard let decision = try? SubscriptionDeviceAccessDecision.decode(data) else { return .unverified }
        return .verified(decision)
    }

    private func snapshot(forSource source: String) throws -> (data: Data, root: [String: Any])? {
        // Only redact a snapshot or clear a shared runtime key when its owner can be identified.
        guard let data = try readIfPresent(cacheURL),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              root["sourceURL"] as? String == source else { return nil }
        return (data, root)
    }

    /// Must share the snapshot lock with runtime writes: a late A response cannot clear B's key.
    public func purgeRuntimeIfDenied(source: String) async throws {
        let lock = try await acquireLock()
        defer { try? lock.close() }
        guard let cached = try snapshot(forSource: source),
              let state = try decision(forSource: source)?.state, state.isDenied else { return }
        let sanitized = try redactedSnapshot(cached.root, state: state)
        // A newer authorization can arrive while the snapshot is being encoded.
        guard try decision(forSource: source)?.state.isDenied == true else { return }
        if sanitized != cached.data {
            try sanitized.write(to: cacheURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
        try VKTurnConfigurationStore.clear()
    }

    public func withAllowedWDTT<T>(source: String?, _ action: () throws -> T) async throws -> T {
        try await withLock {
            try checkWDTTAccessWhileLocked(source: source)
            let result = try action()
            // A revocation may be published while the extension reads its Keychain entry.
            if let source { try requireAllowedDecision(forSource: source) }
            return result
        }
    }

    public func checkWDTTAccessWhileLocked(source: String?) throws {
        guard let source else { return }
        if let data = try readIfPresent(cacheURL) {
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            guard root?["sourceURL"] as? String == source else { throw CancellationError() }
        }
        try requireAllowedDecision(forSource: source)
    }

    private func requireAllowedDecision(forSource source: String) throws {
        if let decision = try decision(forSource: source), decision.state.isDenied {
            throw SubscriptionDeviceAccessError.denied(decision.state)
        }
    }

    @discardableResult public func record(_ incoming: SubscriptionDeviceAccessDecision, source: String) async throws -> SubscriptionDeviceAccessRecord {
        guard SubscriptionDeviceRequest.sameOrigin(source, source) else { throw SubscriptionDeviceAccessError.invalidResponse }
        // Finish publishing a received decision even if the download is cancelled. Only decision
        // writers use this lock; none waits for runtime cleanup while holding it.
        let publication = Task.detached { () throws -> SubscriptionDeviceAccessRecord in
            let lock = try await acquireLock("device-access-record.lock")
            defer { try? lock.close() }
            switch try decision(forSource: source) {
            case .unverified:
                // The last revision is unknown. Preserve the file for a client that can read it.
                return .unverified
            case .verified(let previous) where incoming.revision <= previous.revision:
                guard incoming.revision != previous.revision || incoming == previous else { throw SubscriptionDeviceAccessError.invalidResponse }
                return .verified(previous)
            default:
                try JSONEncoder().encode(incoming).write(to: decisionURL(source: source), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                return .verified(incoming)
            }
        }
        let effective = try await publication.value
        if effective.state.isDenied { try await purgeRuntimeIfDenied(source: source) }
        return effective
    }

    public func commitSnapshot(_ data: Data) async throws -> Data {
        try await withLock {
            let sanitized = try sanitizeUnlocked(data)
            try sanitized.write(to: cacheURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            return sanitized
        }
    }

    public func sanitizedSnapshot(_ data: Data) throws -> Data {
        // Snapshots and decisions are replaced atomically; readers need no writer lock.
        // Runtime writes still recheck access while holding the lock in withAllowedWDTT.
        try sanitizeUnlocked(data)
    }

    private func sanitizeUnlocked(_ data: Data) throws -> Data {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return data }
        guard let source = root["sourceURL"] as? String,
              let decision = try decision(forSource: source), decision.state.isDenied else {
            return try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
        }
        return try redactedSnapshot(root, state: decision.state)
    }

    private func redactedSnapshot(_ fields: [String: Any], state: SubscriptionDeviceAccessState) throws -> Data {
        var root = fields
        root.removeValue(forKey: "vkTurnLink")
        root["wdttAccessState"] = state.rawValue
        if var ui = root["uiDocument"] as? [String: Any], var blocks = ui["blocks"] as? [[String: Any]] {
            for index in blocks.indices where blocks[index]["id"] as? String == "block04" {
                guard var items = blocks[index]["items"] as? [[String: Any]] else { continue }
                for item in items.indices where items[item]["id"] as? String == "option02" {
                    // The generic denial also covers tariffs without bypass. Keep the server's tariff action.
                    if state == .notAllowed, items[item]["state"] as? String == "restricted" {
                        continue
                    }
                    items[item]["state"] = "unavailable"
                    items[item]["stateText"] = state.message
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
