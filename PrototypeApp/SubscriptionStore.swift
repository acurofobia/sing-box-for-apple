import Darwin
import Foundation
import Library

/// Serializes provisioning transactions. This store never touches tunnel runtime files.
@MainActor
final class PrototypeSubscriptionStore {
    private let cacheURL: URL
    private let download: @Sendable (String, Bool) async throws -> PrototypeSubscription
    private var task: Task<Void, Error>?
    private var generation: UInt64 = 0
    private var activeGeneration: UInt64?
    private var committedGeneration: UInt64?
    private var lastAttemptAt: Date?
    private var refreshURL: URL { cacheURL.appendingPathExtension("refresh") }
    private(set) var snapshot = PrototypeSubscription()
    var isLoading: Bool {
        activeGeneration != nil
    }

    init(cacheURL: URL, download: (@Sendable (String) async throws -> PrototypeSubscription)? = nil) {
        self.cacheURL = cacheURL
        self.download = { source, service in
            if let download { return try await download(source) }
            return try await PrototypeSubscriptionLoader.download(source, accessStore: SubscriptionDeviceAccessStore(cacheURL: cacheURL), service: service)
        }
    }

    func load() throws {
        if let data = try? Data(contentsOf: refreshURL) {
            lastAttemptAt = try? JSONDecoder().decode(Date.self, from: data)
        }
        guard FileManager.default.fileExists(atPath: cacheURL.path) else { return }
        let data = try SubscriptionDeviceAccessStore(cacheURL: cacheURL).sanitizedSnapshot(Data(contentsOf: cacheURL))
        // Validate raw keys before Codable can discard unknown outbound options.
        if let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
           let raw = root["vlessProvisioning"], !(raw is NSNull)
        {
            guard let provisioning = raw as? [String: Any] else { throw PrototypeSubscriptionError.invalidVLESS }
            _ = try PrototypeSubscription.decodeVLESSProvisioning(JSONSerialization.data(withJSONObject: provisioning))
        }
        let cached = try JSONDecoder().decode(PrototypeSubscription.self, from: data)
        try cached.validateVLESS()
        if let document = cached.uiDocument {
            _ = try PrototypeUIDocument.decode(JSONEncoder().encode(document))
        }
        snapshot = cached
        if let updatedAt = cached.updatedAt, lastAttemptAt.map({ $0 < updatedAt }) ?? true {
            lastAttemptAt = updatedAt
        }
    }

    func cancel() {
        generation &+= 1
        activeGeneration = nil
        task?.cancel()
        // Retain the task until the next operation has waited for cancellation.
    }

    func reset() async throws {
        cancel()
        if let task { _ = await task.result }
        task = nil
        for url in [cacheURL, refreshURL] where FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        snapshot = PrototypeSubscription()
        committedGeneration = nil
        lastAttemptAt = nil
    }

    func update(_ source: String, replacing: Bool, automatic: Bool = false, now: Date = Date(), service: Bool = false, didDownload: @escaping @MainActor @Sendable () -> Void = {}, authorizeCommit: @escaping @MainActor () throws -> Void = {}) async throws -> PrototypeSubscription? {
        if !replacing, isLoading {
            return nil
        }
        if automatic, let lastAttemptAt, now.timeIntervalSince(lastAttemptAt) < 3600 {
            return nil
        }
        generation &+= 1
        let current = generation
        activeGeneration = current
        let previous = task
        previous?.cancel()
        if let previous {
            _ = await previous.result
        }
        guard generation == current, !Task.isCancelled else {
            if activeGeneration == current {
                activeGeneration = nil
            }
            return nil
        }
        defer {
            if activeGeneration == current {
                task = nil
                activeGeneration = nil
            }
        }
        lastAttemptAt = now
        let operation = Task { [cacheURL, refreshURL] in
            try await BlockingIO.run {
                try FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONEncoder().encode(now).write(to: refreshURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            }
            try Task.checkCancellation()
            let updated = try await download(source, service)
            try Task.checkCancellation()
            didDownload()
            try await Self.save(updated, previous: snapshot, source: source, cacheURL: cacheURL) { pending, saved in
                try Task.checkCancellation()
                guard self.generation == current else { throw CancellationError() }
                try authorizeCommit()
                // Publish the staged file and in-memory snapshot together, with no suspension after authorization.
                guard rename(pending.path, cacheURL.path) == 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                self.snapshot = saved
                self.committedGeneration = current
            }
        }
        task = operation
        do {
            try await withTaskCancellationHandler {
                try await operation.value
            } onCancel: { operation.cancel() }
            // A cancellation during routing cleanup cannot undo an already published snapshot.
            return committedGeneration == current ? snapshot : nil
        } catch {
            guard generation == current, !operation.isCancelled, !Task.isCancelled else { return nil }
            throw error
        }
    }

    private nonisolated static func save(
        _ downloaded: PrototypeSubscription, previous: PrototypeSubscription, source: String, cacheURL: URL,
        publish: @MainActor (URL, PrototypeSubscription) throws -> Void
    ) async throws {
        var updated = downloaded
        guard updated.isComplete else { throw PrototypeSubscriptionError.invalidResponse }
        try updated.validateVLESS()
        let sameSource = previous.sourceURL == source
        if sameSource, let reserved = previous.serviceWDTT, reserved.revision >= (updated.serviceWDTT?.revision ?? 0) {
            updated.serviceWDTT = reserved
        }
        updated.allowsLegacyTransport = sameSource && previous.allowsLegacyTransport != false

        let access = SubscriptionDeviceAccessStore(cacheURL: cacheURL)
        let lock = try await access.acquireLock()
        defer { try? lock.close() }
        let pending = cacheURL.appendingPathExtension("pending")
        defer {
            try? FileManager.default.removeItem(at: pending)
            try? PrototypeRouting.prune(snapshotURL: cacheURL)
        }
        if let routing = updated.routing {
            updated.routing = try PrototypeRouting.install(routing, snapshotURL: cacheURL, source: source)
        } else if sameSource {
            updated.routing = previous.routing
        }
        try Task.checkCancellation()
        let encoded = try access.sanitizedSnapshot(JSONEncoder().encode(updated))
        let saved = try JSONDecoder().decode(PrototypeSubscription.self, from: encoded)
        try encoded.write(to: pending, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        try await publish(pending, saved)
    }
}
