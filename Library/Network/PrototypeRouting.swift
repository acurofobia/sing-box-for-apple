import CryptoKit
import Foundation
#if canImport(Libbox)
    import Libbox
#endif

public enum PrototypeRoutingMode: String, CaseIterable {
    // Keep the stored value so the previous second mode migrates to Russia inside.
    case russiaInside = "disabled"
    case enabled

    public var title: String {
        self == .enabled ? "RoskomVPN" : "Russia inside"
    }
}

public enum PrototypeRouting {
    public struct Profile {
        public let route: Data
        public let reverseMapping: Bool
    }

    private static let invalid = CocoaError(.fileReadCorruptFile)

    private static func strings(_ value: Any?) throws -> [String] {
        let list = (value as? String).map { [$0] } ?? value as? [String]
        guard let list, !list.isEmpty, list.allSatisfy({ !$0.isEmpty }) else { throw invalid }
        return list
    }

    private static func boolean(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    private static func validDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48 ... 57).contains($0) || (97 ... 102).contains($0) }
    }

    /// Each file is immutable. The atomic subscription snapshot publishes both profiles together.
    public static func stage(_ data: Data, directory: URL, resources: Bundle? = nil, installed: Bool = false) throws -> [PrototypeRoutingMode: Profile] {
        guard data.count <= 8 * 1024 * 1024,
              let package = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(package.keys) == ["schemaVersion", "revision", "assets", "profiles"],
              let version = package["schemaVersion"] as? NSNumber, boolean(version) == nil, version == 1,
              let revision = package["revision"] as? String, validDigest(revision),
              let assets = package["assets"] as? [String: [String: String]], assets.count <= 256,
              let profiles = package["profiles"] as? [String: [String: Any]],
              Set(profiles.keys) == ["roskomvpn", "russia_inside"]
        else { throw invalid }
        var paths: [String: URL] = [:]
        var contents: [URL: Data] = [:]
        for (tag, descriptor) in assets {
            guard tag.range(of: #"^[a-zA-Z0-9_-][a-zA-Z0-9_.-]{0,63}$"#, options: .regularExpression) == tag.startIndex ..< tag.endIndex,
                  let digest = descriptor["sha256"], validDigest(digest) else { throw invalid }
            let path = directory.appendingPathComponent(digest + ".srs")
            let bytes: Data
            if installed {
                guard Set(descriptor.keys) == ["sha256"] else { throw invalid }
                bytes = try Data(contentsOf: path)
            } else if let resources {
                guard Set(descriptor.keys) == ["sha256", "file"], descriptor["file"] == tag + ".srs",
                      let url = resources.url(forResource: tag, withExtension: "srs", subdirectory: "RuleSets")
                        ?? resources.url(forResource: tag, withExtension: "srs") else { throw invalid }
                bytes = try Data(contentsOf: url)
            } else {
                guard Set(descriptor.keys) == ["sha256", "data"], let encoded = descriptor["data"],
                      let decoded = Data(base64Encoded: encoded) else { throw invalid }
                bytes = decoded
            }
            guard bytes.count > 4, bytes.starts(with: [0x53, 0x52, 0x53]), (1 ... 5).contains(bytes[3]),
                  SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined() == digest else { throw invalid }
            paths[tag] = path
            if !installed { contents[path] = bytes }
        }
        var results: [PrototypeRoutingMode: Profile] = [:]
        var allTags: Set<String> = []
        for mode in PrototypeRoutingMode.allCases {
            guard let profile = profiles[mode == .enabled ? "roskomvpn" : "russia_inside"],
                  Set(profile.keys) == ["rules", "final", "reverse_mapping"],
                  let reverse = boolean(profile["reverse_mapping"]),
                  let final = profile["final"] as? String, ["direct", "vk-wg"].contains(final),
                  let rules = profile["rules"] as? [[String: Any]], (2 ... 2048).contains(rules.count),
                  rules[0] as? [String: String] == ["action": "sniff"],
                  rules[1] as? [String: String] == ["protocol": "dns", "action": "hijack-dns"]
            else { throw invalid }
            var tags: Set<String> = []
            for rule in rules.dropFirst(2) {
                let matches: Set = ["rule_set", "domain", "domain_suffix", "domain_keyword", "domain_regex", "ip_cidr", "ip_is_private", "network", "port"]
                guard !matches.isDisjoint(with: rule.keys), Set(rule.keys).isSubset(of: matches.union(["outbound", "action"])) else { throw invalid }
                if rule["action"] as? String == "reject" {
                    guard rule["outbound"] == nil else { throw invalid }
                } else {
                    guard rule["action"] == nil || rule["action"] as? String == "route",
                          let outbound = rule["outbound"] as? String, ["vk-wg", "direct"].contains(outbound) else { throw invalid }
                }
                for key in ["rule_set", "domain", "domain_suffix", "domain_keyword", "domain_regex", "ip_cidr", "network"] where rule[key] != nil {
                    let values = try strings(rule[key])
                    if key == "rule_set" { tags.formUnion(values) }
                    if key == "network", !values.allSatisfy({ ["tcp", "udp"].contains($0) }) { throw invalid }
                }
                if rule["ip_is_private"] != nil, boolean(rule["ip_is_private"]) == nil { throw invalid }
                if let raw = rule["port"] {
                    guard let port = raw as? NSNumber, boolean(port) == nil, (1 ... 65535).contains(port.intValue),
                          port.doubleValue == Double(port.intValue) else { throw invalid }
                }
            }
            let descriptors = try tags.sorted().map { tag -> [String: String] in
                guard let path = paths[tag] else { throw invalid }
                return ["type": "local", "tag": tag, "format": "binary", "path": path.path]
            }
            allTags.formUnion(tags)
            let route: [String: Any] = ["rules": rules, "rule_set": descriptors, "final": final, "auto_detect_interface": true]
            results[mode] = try Profile(route: JSONSerialization.data(withJSONObject: route, options: [.sortedKeys]), reverseMapping: reverse)
        }
        guard allTags == Set(paths.keys) else { throw invalid }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (path, bytes) in contents {
            if (try? Data(contentsOf: path)) != bytes {
                try bytes.write(to: path, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            }
        }
        #if canImport(Libbox)
            for profile in results.values where !installed {
                let route = try JSONSerialization.jsonObject(with: profile.route)
                let config: [String: Any] = ["route": route, "outbounds": [["type": "direct", "tag": "direct"], ["type": "direct", "tag": "vk-wg"]]]
                let json = try JSONSerialization.data(withJSONObject: config)
                var error: NSError?
                let withDNS = try configurationWithDNSPolicy(json)
                LibboxCheckConfig(String(decoding: withDNS, as: UTF8.self), &error)
                if error != nil { throw invalid }
            }
        #endif
        return results
    }

    public static func sourceID(_ source: String) -> String {
        SHA256.hash(data: Data(source.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func assetDirectory(snapshotURL: URL, source: String) -> URL {
        snapshotURL.deletingLastPathComponent().appendingPathComponent("Library/Application Support/PrototypeRuleSets/Assets/" + sourceID(source), isDirectory: true)
    }

    public static func install(_ wire: Data, snapshotURL: URL, source: String) throws -> Data {
        let base = assetDirectory(snapshotURL: snapshotURL, source: source)
        guard var package = try JSONSerialization.jsonObject(with: wire) as? [String: Any],
              let revision = package["revision"] as? String, validDigest(revision),
              let assets = package["assets"] as? [String: [String: String]] else { throw invalid }
        let target = base.appendingPathComponent(revision, isDirectory: true)
        let temporary = base.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        _ = try stage(wire, directory: temporary)
        package["assets"] = assets.mapValues { $0.filter { $0.key == "sha256" } }
        let manifest = try JSONSerialization.data(withJSONObject: package, options: [.sortedKeys, .withoutEscapingSlashes])
        let name = "manifest.json"
        let checksum = "manifest.sha256"
        let identity = Data(SHA256.hash(data: manifest))
        if let current = try? JSONDecoder().decode(CachedRouting.self, from: Data(contentsOf: snapshotURL)),
           current.sourceURL == source, let routing = current.routing,
           let previous = try JSONSerialization.jsonObject(with: routing) as? [String: Any],
           previous["revision"] as? String == revision, routing != manifest { throw invalid }
        if FileManager.default.fileExists(atPath: target.path) {
            let existing = try? Data(contentsOf: target.appendingPathComponent(name))
            if let existing, existing != manifest,
               (try? Data(contentsOf: target.appendingPathComponent(checksum))) == Data(SHA256.hash(data: existing)) { throw invalid }
            // Reinstall verified bytes individually; a running core may still hold these paths.
            for verified in try FileManager.default.contentsOfDirectory(at: temporary, includingPropertiesForKeys: nil) {
                let file = target.appendingPathComponent(verified.lastPathComponent)
                let bytes = try Data(contentsOf: verified)
                if (try? Data(contentsOf: file)) != bytes {
                    try bytes.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                }
            }
            if (try? Data(contentsOf: target.appendingPathComponent(checksum))) != identity {
                try identity.write(to: target.appendingPathComponent(checksum), options: .atomic)
            }
            if existing != manifest {
                try manifest.write(to: target.appendingPathComponent(name), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            }
        } else {
            try identity.write(to: temporary.appendingPathComponent(checksum), options: .atomic)
            try manifest.write(to: temporary.appendingPathComponent(name), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            try FileManager.default.moveItem(at: temporary, to: target)
        }
        return manifest
    }

    private static func profile(mode: PrototypeRoutingMode, routing: Data?, source: String, snapshotURL: URL, bundle: Bundle) throws -> Profile {
        let directory = assetDirectory(snapshotURL: snapshotURL, source: source)
        let profiles: [PrototypeRoutingMode: Profile]
        if let routing {
            guard let package = try JSONSerialization.jsonObject(with: routing) as? [String: Any],
                  let revision = package["revision"] as? String, validDigest(revision) else { throw invalid }
            profiles = try stage(routing, directory: directory.appendingPathComponent(revision), installed: true)
        } else {
            guard let url = bundle.url(forResource: "routing", withExtension: "json") else { throw invalid }
            profiles = try stage(Data(contentsOf: url), directory: directory.appendingPathComponent("builtin"), resources: bundle)
        }
        guard let selected = profiles[mode] else { throw invalid }
        return selected
    }

    public static func selection(mode: PrototypeRoutingMode, routing: Data?, source: String, snapshotURL: URL, bundle: Bundle) throws -> Data {
        _ = try profile(mode: mode, routing: routing, source: source, snapshotURL: snapshotURL, bundle: bundle)
        return try JSONSerialization.data(withJSONObject: ["mode": mode.rawValue, "sourceID": sourceID(source)])
    }

    private struct CachedRouting: Decodable {
        let sourceURL: String
        let routing: Data?
        let allowsLegacyTransport: Bool?
    }

    private struct VLESSUnavailable: LocalizedError {
        var errorDescription: String? { String(localized: "Выбранный режим недоступен. Для следующего подключения выберите другой режим.") }
    }

    private static func vlessConfiguration(in data: Data) throws -> Data {
        guard let snapshot = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              snapshot["updatedAt"] is NSNumber, boolean(snapshot["updatedAt"]) == nil,
              let document = snapshot["uiDocument"] as? [String: Any],
              document["schemaVersion"] as? Int == 1, boolean(document["schemaVersion"]) == nil,
              let blocks = document["blocks"] as? [[String: Any]],
              let block = blocks.first(where: { $0["id"] as? String == "block04" }),
              block["type"] as? String == "selectionList", block["visible"] == nil || boolean(block["visible"]) == true,
              let items = block["items"] as? [[String: Any]],
              let item = items.first(where: { $0["id"] as? String == "option01" }),
              item["state"] as? String == "available", item["visible"] == nil || boolean(item["visible"]) == true
        else { throw VLESSUnavailable() }

        let legacy = snapshot["vlessOutbound"]
        if let provisioning = snapshot["vlessProvisioning"], !(provisioning is NSNull) {
            guard legacy == nil || legacy is NSNull,
                  let document = provisioning as? [String: Any], document["state"] as? String == "available"
            else { throw VLESSUnavailable() }
            return try JSONSerialization.data(withJSONObject: document)
        }
        guard let legacy = legacy as? String, let configuration = Data(base64Encoded: legacy) else { throw VLESSUnavailable() }
        return configuration
    }

    /// Settings starts read the latest atomically committed snapshot exactly once.
    public static func runtime(selection: Data, snapshotURL: URL, bundle: Bundle, expectedSource: String? = nil,
                               requiresVLESS: Bool = false) throws -> (profile: Profile, source: String, vlessConfiguration: Data?) {
        guard let saved = try JSONSerialization.jsonObject(with: selection) as? [String: Any] else { throw invalid }
        let data = try Data(contentsOf: snapshotURL)
        let snapshot = try JSONDecoder().decode(CachedRouting.self, from: data)
        if let expectedSource {
            guard expectedSource == sourceID(snapshot.sourceURL) else { throw invalid }
        } else if snapshot.allowsLegacyTransport == false {
            throw invalid
        }
        let mode: PrototypeRoutingMode
        if let raw = saved["mode"] as? String {
            guard let selected = PrototypeRoutingMode(rawValue: raw), saved["sourceID"] as? String == sourceID(snapshot.sourceURL) else { throw invalid }
            mode = selected
        } else {
            // Upgrade the route document written by earlier app versions.
            guard let tags = saved["rule_set"] as? [[String: Any]], saved["rules"] is [[String: Any]] else { throw invalid }
            mode = tags.contains(where: { $0["tag"] as? String == "russia-inside" }) ? .russiaInside : .enabled
        }
        let vless = requiresVLESS ? try vlessConfiguration(in: data) : nil
        let selected = try profile(mode: mode, routing: snapshot.routing, source: snapshot.sourceURL, snapshotURL: snapshotURL, bundle: bundle)
        let pin = try pinValue(source: snapshot.sourceURL, routing: snapshot.routing)
        try Data(pin.utf8).write(to: snapshotURL.appendingPathExtension("active-routing"), options: .atomic)
        return (selected, snapshot.sourceURL, vless)
    }

    private static func pinValue(source: String, routing: Data?) throws -> String {
        guard let routing else { return sourceID(source) + "/builtin" }
        guard let manifest = try JSONSerialization.jsonObject(with: routing) as? [String: Any],
              let revision = manifest["revision"] as? String, validDigest(revision) else { throw invalid }
        return sourceID(source) + "/" + revision
    }

    /// Called by the subscription writer under the same lock as a Settings start.
    public static func prune(snapshotURL: URL) throws {
        var keep = Set<String>()
        if FileManager.default.fileExists(atPath: snapshotURL.path) {
            let saved = try JSONDecoder().decode(CachedRouting.self, from: Data(contentsOf: snapshotURL))
            keep.insert(try pinValue(source: saved.sourceURL, routing: saved.routing))
        }
        if let active = try? String(contentsOf: snapshotURL.appendingPathExtension("active-routing"), encoding: .utf8) { keep.insert(active) }
        let root = assetDirectory(snapshotURL: snapshotURL, source: "").deletingLastPathComponent()
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.path) else { return }
        for source in try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
            for folder in try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)
                where !keep.contains(source.lastPathComponent + "/" + folder.lastPathComponent) {
                try fm.removeItem(at: folder)
            }
            if try fm.contentsOfDirectory(atPath: source.path).isEmpty { try fm.removeItem(at: source) }
        }
    }

    /// A balanced first-match expression selects one resolver before any response-dependent rule.
    private static func alternateResolver(_ rules: ArraySlice<[String: Any]>, defaultServer: String) -> (matches: [String: Any], alternate: [String: Any]?) {
        if rules.count == 1, let rule = rules.first {
            let match = rule.filter { $0.key != "server" && $0.key != "action" }
            // For a denied name with a higher-priority IP exception, resolve through the VPN.
            return (match, (rule["server"] as? String ?? "dns") == defaultServer ? nil : match)
        }
        let mid = rules.index(rules.startIndex, offsetBy: rules.count / 2)
        let left = alternateResolver(rules[..<mid], defaultServer: defaultServer)
        let right = alternateResolver(rules[mid...], defaultServer: defaultServer)
        func logical(_ mode: String, _ children: [[String: Any]]) -> [String: Any] {
            ["type": "logical", "mode": mode, "rules": children]
        }
        let matches = logical("or", [left.matches, right.matches])
        guard let rightChoice = right.alternate else { return (matches, left.alternate) }
        var missesLeft = left.matches
        missesLeft["invert"] = !(missesLeft["invert"] as? Bool ?? false)
        let later = logical("and", [missesLeft, rightChoice])
        return (matches, left.alternate.map { logical("or", [$0, later]) } ?? later)
    }

    #if canImport(Libbox)
        public static func configurationWithDNSPolicy(_ data: Data) throws -> Data {
            try configurationWithDNSPolicy(data) { path in
                var containsIP = ObjCBool(false)
                var error: NSError?
                LibboxBinaryRuleSetContainsIPCIDR(path, &containsIP, &error)
                if let error { throw error }
                return containsIP.boolValue
            }
        }
    #endif

    static func configurationWithDNSPolicy(_ data: Data, containsDestinationIP: (String) throws -> Bool) throws -> Data {
        guard var configuration = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let route = configuration["route"] as? [String: Any],
              let rules = route["rules"] as? [[String: Any]],
              let final = route["final"] as? String, ["direct", "vk-wg"].contains(final)
        else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let finalServer = final == "direct" ? "dns-direct" : "dns"
        var addressRuleSets = Set<String>()
        for descriptor in route["rule_set"] as? [[String: Any]] ?? [] {
            guard let tag = descriptor["tag"] as? String, let path = descriptor["path"] as? String,
                  descriptor["type"] as? String == "local", descriptor["format"] as? String == "binary" else { throw invalid }
            if try containsDestinationIP(path) { addressRuleSets.insert(tag) }
        }
        let matchFields: Set = ["domain", "domain_suffix", "domain_keyword", "domain_regex", "rule_set", "ip_cidr", "ip_is_private", "invert"]
        let allowedFields = matchFields.union(["action", "outbound"])
        var dnsRules: [[String: Any]] = []
        var firstResponse: Int?
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
            if rule["ip_cidr"] != nil || rule["ip_is_private"] != nil || !addressRuleSets.isDisjoint(with: ruleSets) {
                if firstResponse == nil { firstResponse = dnsRules.count }
                dnsRule["match_response"] = true
            }
            dnsRules.append(dnsRule)
        }
        if let firstResponse {
            let domainRules = dnsRules[firstResponse...].filter { $0["match_response"] == nil }
            let otherServer = finalServer == "dns" ? "dns-direct" : "dns"
            var evaluate: [[String: Any]] = []
            if !domainRules.isEmpty, var alternate = alternateResolver(domainRules[...], defaultServer: finalServer).alternate {
                var fallback = alternate
                fallback["invert"] = !(fallback["invert"] as? Bool ?? false)
                fallback["action"] = "evaluate"
                fallback["server"] = finalServer
                alternate["action"] = "evaluate"
                alternate["server"] = otherServer
                evaluate = [alternate, fallback]
            } else {
                evaluate = [["action": "evaluate", "server": finalServer]]
            }
            // The first matching name rule already chose the resolver. Keep IP overrides in their original positions.
            for index in firstResponse ..< dnsRules.count where dnsRules[index]["match_response"] == nil && dnsRules[index]["action"] as? String == "route" {
                dnsRules[index].removeValue(forKey: "server")
                dnsRules[index]["action"] = "respond"
            }
            dnsRules.insert(contentsOf: evaluate, at: firstResponse)
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

    public static func configurationWithPersistentCache(_ data: Data, directory: URL, reverseMapping: Bool?) throws -> Data {
        guard var configuration = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        if let reverseMapping {
            var dns = configuration["dns"] as? [String: Any] ?? [:]
            dns["reverse_mapping"] = reverseMapping
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
