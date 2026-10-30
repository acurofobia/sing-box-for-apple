import Darwin
import Foundation

/// Callers serialize writes. Completed snapshots are published atomically across processes.
final class VPNDiagnosticArchive {
    private let directory: URL
    private let fm = FileManager.default
    private var lockDescriptor: Int32?
    private var incidents: URL { directory.appendingPathComponent("incidents", isDirectory: true) }
    private var sessions: URL { directory.appendingPathComponent("sessions", isDirectory: true) }
    private var errors: URL { directory.appendingPathComponent("application-errors", isDirectory: true) }

    init(directory: URL) { self.directory = directory }

    deinit { if let lockDescriptor { close(lockDescriptor) } }

    func track(_ session: URL) throws {
        try write("\(Date().ISO8601Format()) session tracked\n", to: session.appendingPathComponent("tracked.txt"))
    }

    func expectStop(_ session: URL) throws {
        try write("\(Date().ISO8601Format()) application requested stop\n", to: session.appendingPathComponent("expected-stop.txt"))
    }

    func recordStop(_ session: URL, reason: Int) throws {
        try write(String(reason), to: session.appendingPathComponent("stop-reason.txt"))
        try preserveIfUnexpected(session, detail: "provider stop reason=\(reason)")
    }

    func preserveIfUnexpected(_ session: URL, detail: String) throws {
        try withArchiveLock { try preserveUnlocked(session, detail: detail) }
    }

    private func preserveUnlocked(_ session: URL, detail: String) throws {
        guard fm.fileExists(atPath: session.appendingPathComponent("tracked.txt").path),
              !fm.fileExists(atPath: session.appendingPathComponent("acknowledged.txt").path)
        else { return }
        if let text = try? String(contentsOf: session.appendingPathComponent("stop-reason.txt"), encoding: .utf8),
           let reason = Int(text), [1, 9, 10, 11, 16].contains(reason)
        { return }
        let destination = incidents.appendingPathComponent(session.lastPathComponent, isDirectory: true)
        guard !fm.fileExists(atPath: destination.path) else { return }
        try fm.createDirectory(at: incidents, withIntermediateDirectories: true)
        let staging = incidents.appendingPathComponent(".pending-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        try copyLogs(from: session, to: staging)
        try copyLogs(from: directory.appendingPathComponent("application"), to: staging.appendingPathComponent("application"))
        try write("Unexpected disconnect preserved at \(Date().ISO8601Format())\n\(DiagnosticRedaction.clean(detail))\nRetained until explicitly deleted. Absence of a stop callback does not establish a crash cause.\n",
                  to: staging.appendingPathComponent("incident.txt"))
        var excluded = staging
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try excluded.setResourceValues(values)
        do {
            try fm.moveItem(at: staging, to: destination)
        } catch let error as CocoaError where error.code == .fileWriteFileExists {
            // The other process has already committed this same incident.
        }
    }

    func recover(excluding activeSession: URL?) throws {
        for session in try sessionDirectories() where session.lastPathComponent != activeSession?.lastPathComponent {
            try preserveIfUnexpected(session, detail: "session ended without an expected stop; discovered after process exit")
        }
    }

    func sessionDirectories() throws -> [URL] {
        guard fm.fileExists(atPath: sessions.path) else { return [] }
        return try fm.contentsOfDirectory(at: sessions, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles)
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    func appendError(_ message: String) throws {
        try appendRecord("[app error] " + message, to: errors)
    }

    func appendIncidentEvent(_ session: URL, message: String) throws {
        let report = incidents.appendingPathComponent(session.lastPathComponent, isDirectory: true)
        try withArchiveLock {
            guard fm.fileExists(atPath: report.path) else { return }
            try appendRecord(message, to: report.appendingPathComponent("subsequent-events", isDirectory: true))
        }
    }

    private func appendRecord(_ message: String, to folder: URL) throws {
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let files = try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey])
            .filter { $0.pathExtension == "log" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        let clean = DiagnosticRedaction.clean(String(message.prefix(16_384)))
        let data = Data("\(Date().ISO8601Format()) \(clean)\n".utf8)
        var sequence = files.last.flatMap { Int($0.deletingPathExtension().lastPathComponent) } ?? 0
        if let last = files.last,
           (try last.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) + data.count > 256 * 1024
        { sequence += 1 }
        let url = folder.appendingPathComponent(String(format: "%014d.log", sequence))
        if !fm.fileExists(atPath: url.path) { try write("", to: url) }
        let file = try FileHandle(forWritingTo: url)
        defer { try? file.close() }
        try file.seekToEnd()
        try file.write(contentsOf: data)
    }

    func clearPreservedReports() throws {
        try withArchiveLock { try clearUnlocked() }
    }

    private func clearUnlocked() throws {
        // Delete only reports present at the user's action, preserving concurrent new incidents.
        if fm.fileExists(atPath: incidents.path) {
            let reports = try fm.contentsOfDirectory(at: incidents, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
            for report in reports {
                let session = sessions.appendingPathComponent(report.lastPathComponent, isDirectory: true)
                if fm.fileExists(atPath: session.path) {
                    try write("\(Date().ISO8601Format()) user cleared report\n", to: session.appendingPathComponent("acknowledged.txt"))
                }
                try fm.removeItem(at: report)
            }
        }
        if fm.fileExists(atPath: errors.path) {
            for file in try fm.contentsOfDirectory(at: errors, includingPropertiesForKeys: nil) {
                try fm.removeItem(at: file)
            }
        }
    }

    private func copyLogs(from source: URL, to destination: URL) throws {
        let root = source.resolvingSymlinksInPath()
        guard fm.fileExists(atPath: root.path),
              let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey], options: .skipsHiddenFiles)
        else { return }
        for case let file as URL in enumerator where ["log", "txt"].contains(file.pathExtension) {
            let relative = file.pathComponents.suffix(enumerator.level).joined(separator: "/")
            let copy = destination.appendingPathComponent(relative)
            try fm.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
            do {
                try fm.copyItem(at: file, to: copy)
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
                // A rolling application segment may disappear while being copied.
            }
        }
    }

    private func write(_ text: String, to url: URL) throws {
        try Data(text.utf8).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    private func withArchiveLock<T>(_ operation: () throws -> T) throws -> T {
        let descriptor: Int32
        if let lockDescriptor {
            descriptor = lockDescriptor
        } else {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            let lockURL = directory.appendingPathComponent("archive.lock")
            descriptor = open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
            guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            do {
                #if os(iOS) || os(tvOS)
                    try fm.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: lockURL.path)
                #endif
            } catch {
                close(descriptor)
                throw error
            }
            lockDescriptor = descriptor
        }
        guard flock(descriptor, LOCK_EX) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { flock(descriptor, LOCK_UN) }
        return try operation()
    }
}
