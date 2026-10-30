import CryptoKit
import Darwin
import Foundation
import Security

/// A device-local application identity. Never derived from a subscription or OS version.
public enum SubscriptionDeviceIdentity {
    public static func headers() throws -> [String: String] {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "KeychainAccessGroup") as? String else {
            throw VKTurnError.keychain(errSecMissingEntitlement)
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "vipin.subscription.hwid.v1",
            kSecAttrAccount as String: "device",
            kSecAttrAccessGroup as String: group,
            kSecAttrSynchronizable as String: false,
        ]
        func read() throws -> String? {
            var search = query
            search[kSecReturnData as String] = true
            search[kSecMatchLimit as String] = kSecMatchLimitOne
            var result: CFTypeRef?
            let status = SecItemCopyMatching(search as CFDictionary, &result)
            if status == errSecItemNotFound { return nil }
            guard status == errSecSuccess else { throw VKTurnError.keychain(status) }
            guard let data = result as? Data, let value = String(data: data, encoding: .utf8), isValid(value) else {
                throw VKTurnError.invalidField
            }
            return value
        }
        let hwid: String
        if let existing = try read() {
            hwid = existing
        } else {
            let generated = digest("vipin.hwid.v1:" + UUID().uuidString)
            var attributes = query
            attributes[kSecValueData as String] = Data(generated.utf8)
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let status = SecItemAdd(attributes as CFDictionary, nil)
            if status == errSecDuplicateItem, let existing = try read() {
                hwid = existing
            } else if status == errSecSuccess {
                hwid = generated
            } else {
                throw VKTurnError.keychain(status)
            }
        }
        var system = utsname()
        uname(&system)
        let model = withUnsafeBytes(of: &system.machine) { bytes in
            String(bytes: bytes.prefix(while: { $0 != 0 }), encoding: .utf8)
        } ?? platformModelFallback
        #if os(iOS)
            let platform = "iOS"
        #elseif os(tvOS)
            let platform = "tvOS"
        #else
            let platform = "macOS"
        #endif
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return ["x-hwid": hwid, "x-device-os": platform,
                "x-ver-os": "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)",
                "x-device-model": model]
    }

    public static func isValid(_ value: String) -> Bool {
        value.range(of: #"^[a-zA-Z0-9=-]{10,64}$"#, options: .regularExpression) == value.startIndex ..< value.endIndex
    }

    private static let platformModelFallback = "Unknown"

    public static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
