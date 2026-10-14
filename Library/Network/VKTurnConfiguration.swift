import Foundation
import Security

public struct VKTurnConfiguration: Codable, Equatable {
    public let privateKey: String?
    public let peerPublicKey: String?
    public let tunnelAddress: String?
    public let vkLink: String
    public let peerAddress: String
    public let presharedKey: String?
    public let dnsServers: String?
    public let numConnections: Int?
    public let useUDP: Bool?
    public let turnServerOverride: String?
    public let useWrapA: Bool?
    public let wrapAPassword: String?

    public var isWrapA: Bool { useWrapA == true }

    public static func importLink(_ text: String) throws -> VKTurnConfiguration {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasPrefix("wdtt://") {
            return try importWDTT(trimmed)
        }
        guard let url = URLComponents(string: trimmed),
              url.scheme?.lowercased() == "vkturnproxy", url.host?.lowercased() == "import",
              url.path.isEmpty,
              let encoded = url.queryItems?.first(where: { $0.name == "data" })?.value,
              encoded.count <= 90_000 else {
            throw VKTurnError.invalidLink
        }
        let base64 = encoded.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        guard let data = Data(base64Encoded: base64 + String(repeating: "=", count: (4 - base64.count % 4) % 4)),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              root["version"] as? Int == 1,
              root["type"] as? String == "connection",
              let settings = root["settings"] as? [String: Any] else {
            throw VKTurnError.invalidLink
        }
        guard (settings["useWrapA"] as? Bool == true || settings["useSrtp"] as? Bool == true),
              !["useWrap", "useWrapS", "useCsqtt", "useCookieAuth"].contains(where: { settings[$0] as? Bool == true }) else {
            throw VKTurnError.unsupportedMode
        }
        guard let configuration = try? JSONDecoder().decode(VKTurnConfiguration.self, from: JSONSerialization.data(withJSONObject: settings)) else {
            throw VKTurnError.invalidField
        }
        try configuration.validate()
        return configuration
    }

    private static func importWDTT(_ link: String) throws -> VKTurnConfiguration {
        let body = String(link.dropFirst("wdtt://".count))
        let fields = body.split(separator: ":", maxSplits: 5, omittingEmptySubsequences: false).map(String.init)
        guard fields.count == 6,
              let port = Int(fields[1]), (1...65_535).contains(port),
              !fields[4].isEmpty else { throw VKTurnError.invalidLink }
        let hashList = fields[5].split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
        let firstHash = String(hashList.split(separator: ",", omittingEmptySubsequences: false).first ?? "")
        let prefixes = ["https://vk.ru/call/join/", "https://vk.com/call/join/", "https://vk.me/join/"]
        let hash = prefixes.first(where: { firstHash.lowercased().hasPrefix($0) })
            .map { String(firstHash.dropFirst($0.count)) } ?? firstHash
        guard !hash.isEmpty, !hash.contains("/"), !hash.contains("?"), !hash.contains("#") else {
            throw VKTurnError.invalidLink
        }
        let configuration = VKTurnConfiguration(
            privateKey: nil, peerPublicKey: nil, tunnelAddress: nil,
            vkLink: "https://vk.ru/call/join/\(hash)", peerAddress: "\(fields[0]):\(port)",
            presharedKey: nil, dnsServers: nil, numConnections: nil, useUDP: nil,
            turnServerOverride: nil, useWrapA: true, wrapAPassword: fields[4]
        )
        try configuration.validate()
        return configuration
    }

    public func validate() throws {
        for value in [privateKey ?? "", peerPublicKey ?? "", tunnelAddress ?? "", vkLink, peerAddress, presharedKey ?? "", dnsServers ?? "", turnServerOverride ?? "", wrapAPassword ?? ""] {
            guard !value.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }) else {
                throw VKTurnError.invalidField
            }
        }
        guard let vkURL = URLComponents(string: vkLink), vkURL.scheme == "https",
              ((vkURL.host?.lowercased() == "vk.me" && vkURL.path.hasPrefix("/join/")) ||
               (["vk.ru", "vk.com"].contains(vkURL.host?.lowercased() ?? "") && vkURL.path.hasPrefix("/call/join/"))),
              let endpoint = URLComponents(string: "udp://\(peerAddress)"),
              endpoint.host != nil, endpoint.port.map({ (1...65_535).contains($0) }) == true,
              numConnections.map({ (1...50).contains($0) }) ?? true else {
            throw VKTurnError.invalidField
        }
        if isWrapA {
            guard let wrapAPassword, !wrapAPassword.isEmpty else { throw VKTurnError.invalidField }
        } else {
            guard let privateKey, let peerPublicKey, let tunnelAddress,
                  Self.validKey(privateKey), Self.validKey(peerPublicKey),
                  presharedKey.map(Self.validKey) ?? true,
                  Self.validTunnelAddress(tunnelAddress) else { throw VKTurnError.invalidField }
        }
        if let turnServerOverride, !turnServerOverride.isEmpty {
            guard let turn = URLComponents(string: "udp://\(turnServerOverride)"),
                  turn.host != nil, turn.port.map({ (1...65_535).contains($0) }) == true else {
                throw VKTurnError.invalidField
            }
        }
    }

    private static func validKey(_ value: String) -> Bool {
        Data(base64Encoded: value)?.count == 32
    }

    public static func validTunnelAddress(_ address: String) -> Bool {
        let parts = address.split(separator: "/")
        guard parts.count == 2, let prefix = Int(parts[1]), (1...32).contains(prefix) else { return false }
        let octets = parts[0].split(separator: ".")
        return octets.count == 4 && octets.allSatisfy { Int($0).map { (0...255).contains($0) } == true }
    }

    public var proxyConfig: String? {
        var payload: [String: Any] = [
            "vk_link": vkLink,
            "peer_addr": peerAddress,
            "use_srtp": !isWrapA,
            "use_dtls": !isWrapA,
            "use_udp": useUDP ?? false,
            "num_conns": numConnections ?? 30,
            "use_cookie_auth": false,
        ]
        if isWrapA {
            payload["use_wrap_a"] = true
            payload["wrap_a_password"] = wrapAPassword
            payload["device_id"] = VKTurnConfigurationStore.wrapADeviceID
        }
        if let turnServerOverride, let turn = URLComponents(string: "udp://\(turnServerOverride)"),
           let host = turn.host, let port = turn.port {
            payload["turn_server"] = host
            payload["turn_port"] = String(port)
        }
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public var wireGuardConfig: String? {
        guard let privateKey, let peerPublicKey,
              let privateHex = Self.keyHex(privateKey),
              let publicHex = Self.keyHex(peerPublicKey) else { return nil }
        var lines = ["private_key=\(privateHex)", "replace_peers=true", "public_key=\(publicHex)", "endpoint=\(peerAddress)", "persistent_keepalive_interval=25", "allowed_ip=0.0.0.0/0"]
        if let presharedKey, let hex = Self.keyHex(presharedKey) {
            lines.append("preshared_key=\(hex)")
        }
        return lines.joined(separator: "\n")
    }

    private static func keyHex(_ value: String) -> String? {
        Data(base64Encoded: value)?.map { String(format: "%02x", $0) }.joined()
    }
}

public enum VKTurnError: LocalizedError {
    case invalidLink, unsupportedMode, invalidField, missingConfiguration, keychain(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .invalidLink: return "Ожидается ссылка vkturnproxy://import?data=… или wdtt://… ."
        case .unsupportedMode: return "Поддерживаются только анонимные режимы VK TURN SRTP и SRTP-WRAP-A."
        case .invalidField: return "В ссылке VK TURN отсутствуют обязательные поля или одно из них некорректно."
        case .missingConfiguration: return "Добавьте ссылку VK TURN в настройках приложения."
        case .keychain(let status): return "Не удалось открыть общую Keychain (код \(status))."
        }
    }
}

public enum VKTurnConfigurationStore {
    public static var logURL: URL? {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "AppGroupIdentifier") as? String else { return nil }
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)?
            .appendingPathComponent("vk-turn.log")
    }

    private static var defaults: UserDefaults? {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "AppGroupIdentifier") as? String else { return nil }
        return UserDefaults(suiteName: group)
    }

    public static func serverAddress(for configuration: VKTurnConfiguration) -> String {
        defaults?.string(forKey: "vk_turn_relay_address") ?? configuration.peerAddress
    }

    public static var wrapADeviceID: String {
        if let existing = defaults?.string(forKey: "vk_turn_wrap_a_device_id"), !existing.isEmpty {
            return existing
        }
        let identifier = UUID().uuidString
        defaults?.set(identifier, forKey: "vk_turn_wrap_a_device_id")
        return identifier
    }

    public static func rememberRelayAddress(_ address: String) {
        let octets = address.split(separator: ".")
        guard octets.count == 4,
              octets.allSatisfy({ Int($0).map({ (0...255).contains($0) }) == true }) else { return }
        defaults?.set(address, forKey: "vk_turn_relay_address")
    }

    public static var lastError: String? {
        defaults?.string(forKey: "vk_turn_last_error")
    }

    public static func setLastError(_ message: String?) {
        defaults?.set(message, forKey: "vk_turn_last_error")
    }

    private static var accessGroup: String? {
        Bundle.main.object(forInfoDictionaryKey: "KeychainAccessGroup") as? String
    }

    private static func query() throws -> [String: Any] {
        guard let accessGroup else { throw VKTurnError.keychain(errSecMissingEntitlement) }
        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "vkturn.srtp.configuration",
            kSecAttrAccount as String: "active",
            kSecAttrAccessGroup as String: accessGroup,
        ]
    }

    public static func save(_ configuration: VKTurnConfiguration) throws {
        let data = try JSONEncoder().encode(configuration)
        let key = try query()
        var attributes = key
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let update = SecItemUpdate(key as CFDictionary, [kSecValueData as String: data] as CFDictionary)
            guard update == errSecSuccess else { throw VKTurnError.keychain(update) }
        } else if status != errSecSuccess {
            throw VKTurnError.keychain(status)
        }
        defaults?.removeObject(forKey: "vk_turn_relay_address")
    }

    public static func clear() throws {
        let status = SecItemDelete(try query() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw VKTurnError.keychain(status) }
        defaults?.removeObject(forKey: "vk_turn_relay_address")
    }

    public static func load() throws -> VKTurnConfiguration {
        var request = try query()
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { throw VKTurnError.missingConfiguration }
        guard status == errSecSuccess, let data = result as? Data else { throw VKTurnError.keychain(status) }
        let configuration = try JSONDecoder().decode(VKTurnConfiguration.self, from: data)
        try configuration.validate()
        return configuration
    }
}
