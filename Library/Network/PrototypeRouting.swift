import Foundation

public enum PrototypeRoutingMode: String, CaseIterable {
    // Keep the stored value so the previous second mode migrates to Russia inside.
    case russiaInside = "disabled"
    case enabled

    public var title: String {
        self == .enabled ? "С роутингом" : "Russia inside"
    }
}

public enum PrototypeRouting {
    public static func route(from data: Data, mode: PrototypeRoutingMode, initialDirectory: URL) throws -> Data {
        guard var route = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              route["rules"] is [[String: Any]],
              route["rule_set"] == nil || route["rule_set"] is [[String: Any]]
        else {
            throw CocoaError(.fileReadCorruptFile)
        }
        if mode == .russiaInside {
            route["rules"] = [["action": "sniff"], ["protocol": "dns", "action": "hijack-dns"],
                              ["rule_set": "russia-inside", "outbound": "vk-wg"]]
            route["rule_set"] = [["type": "remote", "tag": "russia-inside", "format": "binary",
                                  "url": "https://github.com/itdoginfo/allow-domains/releases/latest/download/russia_inside.srs"]]
            route["final"] = "direct"
        }
        if let ruleSets = route["rule_set"] as? [[String: Any]] {
            route["rule_set"] = try ruleSets.map { descriptor in
                guard let tag = descriptor["tag"] as? String, !tag.isEmpty,
                      !tag.contains("/"), tag != ".", tag != ".."
                else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                var descriptor = descriptor
                let path = initialDirectory.appendingPathComponent(tag + ".srs").path
                if descriptor["type"] as? String == "remote" {
                    descriptor["initial_path"] = path
                    descriptor["update_interval"] = "1d"
                    var client = descriptor["http_client"] as? [String: Any] ?? [:]
                    client["detour"] = "vk-wg"
                    descriptor["http_client"] = client
                    descriptor.removeValue(forKey: "download_detour")
                } else {
                    descriptor["path"] = path
                }
                return descriptor
            }
        }
        return try JSONSerialization.data(withJSONObject: route, options: [.sortedKeys])
    }

    public static func configurationWithPersistentCache(_ data: Data, directory: URL) throws -> Data {
        guard var configuration = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        if let route = configuration["route"] as? [String: Any],
           let ruleSets = route["rule_set"] as? [[String: Any]],
           ruleSets.contains(where: { $0["tag"] as? String == "russia-inside" })
        {
            // Match DNS-resolved domains even when TCP/UDP payloads cannot be sniffed.
            var dns = configuration["dns"] as? [String: Any] ?? [:]
            dns["reverse_mapping"] = true
            configuration["dns"] = dns
        }
        var experimental = configuration["experimental"] as? [String: Any] ?? [:]
        var cache = experimental["cache_file"] as? [String: Any] ?? [:]
        cache["enabled"] = true
        cache["path"] = directory.appendingPathComponent("cache.db").path
        experimental["cache_file"] = cache
        configuration["experimental"] = experimental
        return try JSONSerialization.data(withJSONObject: configuration, options: [.sortedKeys])
    }
}
