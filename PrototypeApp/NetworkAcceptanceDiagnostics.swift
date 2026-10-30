#if DEBUG
    import Foundation
    import Library

    /// Opt-in telemetry for the physical network test; never exports credentials.
    enum PrototypeNetworkAcceptanceDiagnostics {
        static func export() {
            guard ProcessInfo.processInfo.environment["PROTOTYPE_OPENWRT_CHECK"] == "1" else { return }
            do {
                let root = FilePath.sharedDirectory
                let data = try Data(contentsOf: root.appendingPathComponent("prototype-vless.json"))
                guard let config = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let policy = config["failover"] as? [String: Any], let primary = policy["primary"] as? String,
                      let backups = policy["backups"] as? [String], let nodes = config["outbounds"] as? [[String: Any]],
                      var snapshot = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("prototype-status.json"))) as? [String: Any]
                else { return }
                snapshot = snapshot.filter { ["phase", "updatedAt", "failover"].contains($0.key) }
                let candidates: [[String: Any]] = ([primary] + backups).compactMap { tag in
                    guard let node = nodes.first(where: { $0["tag"] as? String == tag }),
                          let server = node["server"] as? String, let port = node["server_port"] as? Int else { return nil }
                    return ["tag": tag, "server": server, "port": port]
                }
                guard candidates.count == 4 else { return }
                snapshot["candidates"] = candidates
                snapshot["captureName"] = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("Library/Caches/Prototype").path)
                    .filter { $0.hasSuffix("-vless-0.csv") }.sorted().last
                let destination = root.appendingPathComponent("Library/Caches/FailoverAcceptance", isDirectory: true)
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
                try JSONSerialization.data(withJSONObject: snapshot).write(to: destination.appendingPathComponent("telemetry.json"), options: .atomic)
            } catch {
                // The acceptance supervisor times out if telemetry cannot be read.
            }
        }
    }
#endif
