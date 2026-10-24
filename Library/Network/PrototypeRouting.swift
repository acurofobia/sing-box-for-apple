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

    public static func configurationWithDNSPolicy(_ data: Data) throws -> Data {
        guard var configuration = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let route = configuration["route"] as? [String: Any],
              let rules = route["rules"] as? [[String: Any]],
              let final = route["final"] as? String, ["direct", "vk-wg"].contains(final)
        else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let finalServer = final == "direct" ? "dns-direct" : "dns"
        let matchFields: Set = ["domain", "domain_suffix", "domain_keyword", "domain_regex", "rule_set", "ip_cidr", "ip_is_private", "invert"]
        let allowedFields = matchFields.union(["action", "outbound"])
        var dnsRules: [[String: Any]] = []
        var evaluatedResponse = false
        for rule in rules {
            // Traffic-specific rules (including YouTube QUIC rejection) must not become DNS-wide rules.
            guard rule.keys.allSatisfy({ allowedFields.contains($0) }) else { continue }
            var dnsRule = rule.filter { matchFields.contains($0.key) }
            guard !dnsRule.isEmpty else { continue }
            if rule["action"] as? String == "reject" {
                dnsRule["action"] = "reject"
            } else if let outbound = rule["outbound"] as? String, ["direct", "vk-wg"].contains(outbound) {
                dnsRule["action"] = "route"
                dnsRule["server"] = outbound == "direct" ? "dns-direct" : "dns"
            } else {
                continue
            }
            let ruleSets = (rule["rule_set"] as? [String]) ?? (rule["rule_set"] as? String).map { [$0] } ?? []
            if rule["ip_cidr"] != nil || rule["ip_is_private"] != nil || ruleSets.contains(where: { $0.hasPrefix("geoip-") }) {
                // IP routing can only be decided after a lookup. Reuse the default answer if no IP rule matches.
                if !evaluatedResponse {
                    dnsRules.append(["action": "evaluate", "server": finalServer])
                    evaluatedResponse = true
                }
                dnsRule["match_response"] = true
            }
            dnsRules.append(dnsRule)
        }
        if evaluatedResponse {
            dnsRules.append(["action": "respond"])
        }
        var dns = configuration["dns"] as? [String: Any] ?? [:]
        var servers: [[String: Any]] = [
            // HTTPS DNS uses a direct dialer when detour is omitted.
            ["type": "https", "tag": "dns-direct", "server": "77.88.8.8", "path": "/dns-query"],
            ["type": "https", "tag": "dns", "server": "8.8.8.8", "path": "/dns-query", "detour": "vk-wg"],
        ]
        if (dns["servers"] as? [[String: Any]])?.contains(where: { $0["tag"] as? String == "bootstrap" }) == true {
            // Keep VLESS server resolution independent of the tunnel it is about to establish.
            servers.append(["type": "https", "tag": "bootstrap", "server": "77.88.8.8", "path": "/dns-query"])
        }
        dns["servers"] = servers
        dns["rules"] = dnsRules
        dns["final"] = finalServer
        configuration["dns"] = dns
        return try JSONSerialization.data(withJSONObject: configuration, options: [.sortedKeys])
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
