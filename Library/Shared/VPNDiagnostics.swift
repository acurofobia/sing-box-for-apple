import Foundation
import os

/// The app and extension write to separate directories; no cross-process file handles.
public enum VPNDiagnostics {
    private static let logger = Logger(category: "VPNDiagnostics")
    private static let lock = NSLock()
    private static var appLog: RollingDiagnosticLog?
    private static var coreLog: RollingDiagnosticLog?
    private static var eventLog: RollingDiagnosticLog?
    private static var terminationURL: URL?
    private static var sessionDirectory: URL?
    private static let archive = VPNDiagnosticArchive(directory: directory)

    private static var directory: URL {
        FilePath.sharedDirectory.appendingPathComponent("Library/Application Support/VPNDiagnostics", isDirectory: true)
    }

    public static func app(_ message: String) {
        record {
            if appLog == nil {
                appLog = try eventWriter(directory.appendingPathComponent("application"))
            }
            try appLog?.append("[app] " + message)
        }
    }

    public static func applicationError(_ message: String, error: Error? = nil) {
        guard !(error is CancellationError) else { return }
        record {
            var details = message
            var underlying = error as NSError?
            for _ in 0..<4 {
                guard let issue = underlying else { break }
                details += " domain=\(issue.domain) code=\(issue.code) description=\(issue.localizedDescription)"
                underlying = issue.userInfo[NSUnderlyingErrorKey] as? NSError
            }
            try archive.appendError(details)
        }
    }

    public static func expectStop() {
        record {
            if let session = try archive.sessionDirectories().first { try archive.expectStop(session) }
        }
    }

    public static func observeConnection(disconnected: Bool) {
        record {
            let active = disconnected ? nil : try archive.sessionDirectories().first
            try archive.recover(excluding: active)
        }
    }

    public static func clearPreservedReports() throws {
        try lock.withLock { try archive.clearPreservedReports() }
    }

    public static func reset() throws {
        try lock.withLock {
            appLog = nil
            coreLog = nil
            eventLog = nil
            terminationURL = nil
            sessionDirectory = nil
            for url in [directory, CrashReportArchive.crashReportsDirectory, OOMReportArchive.reportsDirectory,
                        FileManager.default.temporaryDirectory.appendingPathComponent("VPNDiagnosticExports", isDirectory: true)]
                where FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        }
    }

    public static func beginTunnel(mode: String) {
        record {
            let sessions = directory.appendingPathComponent("sessions", isDirectory: true)
            let timestamp = String(format: "%020.6f", Date().timeIntervalSince1970)
            let session = sessions.appendingPathComponent("\(timestamp)-\(UUID().uuidString)", isDirectory: true)
            coreLog = nil
            eventLog = nil
            sessionDirectory = session
            terminationURL = session.appendingPathComponent("termination.txt")
            coreLog = try RollingDiagnosticLog(directory: session.appendingPathComponent("core"))
            eventLog = try eventWriter(session.appendingPathComponent("events"))
            let header = "session started=\(Date().ISO8601Format()) mode=\(mode) \(environment)"
            try Data(header.utf8).write(to: session.appendingPathComponent("session.txt"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            try archive.track(session)
            try eventLog?.append("[tunnel] start requested mode=\(mode)")
            // Only tunnel startup prunes sessions. The app never deletes a live writer's files.
            let previous = try subdirectories(sessions).filter { $0.lastPathComponent != session.lastPathComponent }
                .sorted { $0.lastPathComponent > $1.lastPathComponent }
            for (index, old) in previous.enumerated() {
                do {
                    try archive.preserveIfUnexpected(old, detail: "previous process ended; discovered at next tunnel start")
                    if index >= 2 { try FileManager.default.removeItem(at: old) }
                } catch {
                    // Preserve the source session if its durable snapshot could not be committed.
                    logger.error("Incident archive failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    public static func event(_ message: String) {
        record {
            try eventLog?.append("[tunnel] " + message)
            if let sessionDirectory { try archive.appendIncidentEvent(sessionDirectory, message: "[tunnel] " + message) }
        }
    }

    public static func core(_ message: String) {
        record {
            try coreLog?.append("[core] " + message)
            if let sessionDirectory { try archive.appendIncidentEvent(sessionDirectory, message: "[core] " + message) }
        }
    }

    public static func termination(_ message: String) {
        record {
            // Keep the reason even if a noisy session has filled its event segment.
            if let terminationURL {
                // A cancelled startup may finish after stopTunnel: preserve both causes.
                let previous = (try? String(contentsOf: terminationURL, encoding: .utf8)) ?? ""
                let recent = previous.split(separator: "\n").suffix(3).joined(separator: "\n")
                let clean = DiagnosticRedaction.clean(String(message.prefix(512))).replacingOccurrences(of: "\n", with: "\\n")
                let text = (recent.isEmpty ? "" : recent + "\n") + "\(Date().ISO8601Format()) \(clean)\n"
                try Data(text.utf8).write(to: terminationURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            }
            try eventLog?.append("[tunnel] " + message)
            if let sessionDirectory { try archive.appendIncidentEvent(sessionDirectory, message: "[tunnel] " + message) }
        }
    }

    public static func stopRequested(_ reason: Int) {
        termination("stop requested reason=\(stopReason(reason))")
        record {
            if let sessionDirectory { try archive.recordStop(sessionDirectory, reason: reason) }
        }
    }

    public static func startupFailed(_ message: String) {
        termination("startup failed: " + message)
        record {
            if let sessionDirectory { try archive.preserveIfUnexpected(sessionDirectory, detail: "startup failed: " + message) }
        }
    }

    public static func stopReason(_ value: Int) -> String {
        let names = ["none", "userInitiated", "providerFailed", "noNetworkAvailable", "unrecoverableNetworkChange", "providerDisabled", "authenticationCanceled", "configurationFailed", "idleTimeout", "configurationDisabled", "configurationRemoved", "superseded", "userLogout", "userSwitch", "connectionFailed", "sleep", "appUpdate", "internalError"]
        return "\(value) (\(names.indices.contains(value) ? names[value] : "unknown"))"
    }

    public static var environment: String {
        let info = Bundle.main.infoDictionary ?? [:]
        return "app=\(info["CFBundleShortVersionString"] as? String ?? "?") build=\(info["CFBundleVersion"] as? String ?? "?") os=\(ProcessInfo.processInfo.operatingSystemVersionString) uptime=\(Int(ProcessInfo.processInfo.systemUptime))s"
    }

    private static func eventWriter(_ url: URL) throws -> RollingDiagnosticLog {
        try RollingDiagnosticLog(directory: url, maximumSegmentBytes: 32 * 1024, segmentSeconds: 3600, retainedSegments: 48)
    }

    private static func record(_ action: () throws -> Void) {
        lock.withLock {
            do { try action() } catch {
                logger.error("Diagnostic write failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private static func subdirectories(_ url: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
    }

    /// Make an immutable export while the extension may still be writing its current segment.
    public static func export() throws -> URL {
        let fm = FileManager.default
        let exports = fm.temporaryDirectory.appendingPathComponent("VPNDiagnosticExports", isDirectory: true)
        try fm.createDirectory(at: exports, withIntermediateDirectories: true)
        let destination = exports.appendingPathComponent("vpn-diagnostics-\(UUID().uuidString).txt")
        var text = "VPN diagnostics — \(Date().ISO8601Format())\n\(environment)\n"
        text += "Core: last 10–11 minutes of recorded activity per session, capped at 512 KiB/minute; latest 3 sessions.\n"
        text += "Events: last 48 hours of recorded activity. Times are UTC. Missing stop event alone does not prove a crash or memory termination.\n"
        text += "Preserved unexpected disconnects and application errors remain until explicitly deleted, independently of session rotation.\n"
        text += "URLs and common credential formats are redacted. Network addresses and domains may remain.\n"
        if fm.fileExists(atPath: directory.path) {
            guard let enumerator = fm.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey], options: .skipsHiddenFiles) else {
                throw CocoaError(.fileReadUnknown)
            }
            var files: [(url: URL, relative: String)] = []
            for case let file as URL in enumerator where ["log", "txt"].contains(file.pathExtension) {
                files.append((file, file.pathComponents.suffix(enumerator.level).joined(separator: "/")))
            }
            for file in files.sorted(by: { $0.relative < $1.relative }) {
                try appendFile(file.url, title: file.relative, to: &text)
            }
        }
        // Include only diagnostic text, never configuration snapshots, subscriptions or profiles.
        for name in ["prototype-status.json", "Library/Caches/Working/CrashReport-NetworkExtension.log"] {
            let file = FilePath.sharedDirectory.appendingPathComponent(name)
            if fm.fileExists(atPath: file.path) { try appendFile(file, title: name, to: &text) }
        }
        for reports in [CrashReportArchive.crashReportsDirectory, OOMReportArchive.reportsDirectory] {
            guard fm.fileExists(atPath: reports.path) else { continue }
            let recent = try subdirectories(reports).sorted { $0.lastPathComponent > $1.lastPathComponent }.prefix(3)
            for report in recent {
                for name in [ReportArchive.metadataFileName, ReportArchive.goLogFileName, ReportArchive.nativeLogFileName] {
                    let file = report.appendingPathComponent(name)
                    if fm.fileExists(atPath: file.path) {
                        try appendFile(file, title: "\(reports.lastPathComponent)/\(report.lastPathComponent)/\(name)", to: &text)
                    }
                }
            }
        }
        try Data(text.utf8).write(to: destination, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        return destination
    }

    private static func appendFile(_ url: URL, title: String, to text: inout String) throws {
        let file: FileHandle
        do {
            file = try FileHandle(forReadingFrom: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            // The extension may rotate a segment after the app enumerates it.
            return
        }
        defer { try? file.close() }
        let size = try file.seekToEnd()
        let limit: UInt64 = 512 * 1024
        try file.seek(toOffset: size > limit ? size - limit : 0)
        let data = try file.read(upToCount: Int(limit)) ?? Data()
        text += "\n--- \(title)\(size > limit ? " (last 512 KiB)" : "") ---\n"
        text += DiagnosticRedaction.clean(String(decoding: data, as: UTF8.self)) + "\n"
    }
}
