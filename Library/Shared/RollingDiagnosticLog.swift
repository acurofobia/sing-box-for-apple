import Foundation

/// One writer per directory. Files stay readable after a crash or process restart.
public final class RollingDiagnosticLog {
    private let directory: URL
    private let maximumSegmentBytes: Int
    private let segmentSeconds: TimeInterval
    private let retainedSegments: Int
    private let lock = NSLock()
    private let formatter = ISO8601DateFormatter()
    private var currentSegment: Int64?
    private var currentBytes = 0

    public init(directory: URL, maximumSegmentBytes: Int = 512 * 1024, segmentSeconds: TimeInterval = 60, retainedSegments: Int = 11) throws {
        self.directory = directory
        self.maximumSegmentBytes = maximumSegmentBytes
        self.segmentSeconds = segmentSeconds
        self.retainedSegments = retainedSegments
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var url = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }

    public func append(_ message: String, at date: Date = Date()) throws {
        try lock.withLock {
            let segment = Int64(floor(date.timeIntervalSince1970 / segmentSeconds))
            let url = directory.appendingPathComponent(String(format: "%014lld.log", segment))
            if currentSegment != segment {
                // Age relative to the last write, not export time: an idle phone must keep the incident.
                for file in try files() {
                    if let value = Int64(file.deletingPathExtension().lastPathComponent), value < segment - Int64(retainedSegments - 1) {
                        try FileManager.default.removeItem(at: file)
                    }
                }
                currentSegment = segment
                currentBytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            }
            guard currentBytes < maximumSegmentBytes else { return }
            let clean = DiagnosticRedaction.clean(String(message.prefix(8192)))
            var data = Data("\(formatter.string(from: date)) \(clean)\n".utf8)
            let marker = Data("\n[diagnostics] segment truncated: byte limit reached\n".utf8)
            let remaining = maximumSegmentBytes - currentBytes
            if data.count + marker.count > remaining {
                data = Data(data.prefix(max(0, remaining - marker.count))) + marker
            }
            if !FileManager.default.fileExists(atPath: url.path) {
                try Data().write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            }
            let file = try FileHandle(forWritingTo: url)
            defer { try? file.close() }
            try file.seekToEnd()
            try file.write(contentsOf: data)
            currentBytes += data.count
        }
    }

    public func read() throws -> String {
        try lock.withLock {
            try files().map { String(decoding: try Data(contentsOf: $0), as: UTF8.self) }.joined()
        }
    }

    private func files() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "log" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}

public enum DiagnosticRedaction {
    private static let rules: [(String, String)] = [
        (#"\x1B\[[0-?]*[ -/]*[@-~]"#, ""),
        (#"(?i)\b(?:https?|vless|vmess|ss|trojan|wireguard)://[^\s\"<>]+"#, "[redacted-url]"),
        (#"(?i)\bBearer\s+\S+"#, "Bearer [redacted]"),
        (#"(?i)\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b"#, "[redacted-id]"),
        (#"(?i)([\"']?(?:private[_-]?key|preshared[_-]?key|password|token|secret|authorization)[\"']?\s*[:=]\s*)[^\s,;}]+"#, "$1[redacted]"),
    ]

    public static func clean(_ text: String) -> String {
        rules.reduce(text) { value, rule in
            value.replacingOccurrences(of: rule.0, with: rule.1, options: .regularExpression)
        }
    }
}
