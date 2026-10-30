import Foundation
import Library

/// Serializes provisioning transactions. This store never touches tunnel runtime files.
@MainActor
final class PrototypeSubscriptionStore {
    private let cacheURL: URL
    private let download: @Sendable (String) async throws -> PrototypeSubscription
    private var task: Task<PrototypeSubscription, Error>?
    private var generation: UInt64 = 0
    private var activeGeneration: UInt64?
    private var lastAttemptAt: Date?
    private var refreshURL: URL { cacheURL.appendingPathExtension("refresh") }
    private(set) var snapshot = PrototypeSubscription()
    var isLoading: Bool {
        activeGeneration != nil
    }

    init(cacheURL: URL, download: (@Sendable (String) async throws -> PrototypeSubscription)? = nil) {
        self.cacheURL = cacheURL
        self.download = download ?? { try await PrototypeSubscriptionLoader.download($0, accessStore: SubscriptionDeviceAccessStore(cacheURL: cacheURL)) }
    }

    func load() throws {
        if let data = try? Data(contentsOf: refreshURL) {
            lastAttemptAt = try? JSONDecoder().decode(Date.self, from: data)
        }
        guard FileManager.default.fileExists(atPath: cacheURL.path) else { return }
        let data = try SubscriptionDeviceAccessStore(cacheURL: cacheURL).sanitizedSnapshot(Data(contentsOf: cacheURL))
        // Validate raw keys before Codable can discard unknown outbound options.
        if let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
           let provisioning = root["vlessProvisioning"], !(provisioning is NSNull)
        {
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
        lastAttemptAt = nil
    }

    func update(_ source: String, replacing: Bool, automatic: Bool = false, now: Date = Date(), authorizeCommit: () throws -> Void = {}) async throws -> PrototypeSubscription? {
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
        try FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(now).write(to: refreshURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        let operation = Task { try await download(source) }
        task = operation
        do {
            let updated = try await withTaskCancellationHandler {
                try await operation.value
            } onCancel: { operation.cancel() }
            guard generation == current, !operation.isCancelled, !Task.isCancelled else { return nil }
            guard updated.isComplete else { throw PrototypeSubscriptionError.invalidResponse }
            try updated.validateVLESS()
            try authorizeCommit()
            let encoded = try JSONEncoder().encode(updated)
            try FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let committed = try SubscriptionDeviceAccessStore(cacheURL: cacheURL).commitSnapshot(encoded)
            snapshot = try JSONDecoder().decode(PrototypeSubscription.self, from: committed)
            return snapshot
        } catch {
            guard generation == current, !operation.isCancelled, !Task.isCancelled else { return nil }
            throw error
        }
    }
}
