import Foundation

/// Serializes provisioning transactions. This store never touches tunnel runtime files.
@MainActor
final class PrototypeSubscriptionStore {
    private let cacheURL: URL
    private let download: @Sendable (String) async throws -> PrototypeSubscription
    private var task: Task<PrototypeSubscription, Error>?
    private var generation: UInt64 = 0
    private var activeGeneration: UInt64?
    private(set) var snapshot = PrototypeSubscription()
    var isLoading: Bool {
        activeGeneration != nil
    }

    init(cacheURL: URL, download: @escaping @Sendable (String) async throws -> PrototypeSubscription = { try await PrototypeSubscription.download($0) }) {
        self.cacheURL = cacheURL
        self.download = download
    }

    func load() throws {
        guard FileManager.default.fileExists(atPath: cacheURL.path) else { return }
        let data = try Data(contentsOf: cacheURL)
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
    }

    func cancel() {
        generation &+= 1
        activeGeneration = nil
        task?.cancel()
        // Retain the task until the next operation has waited for cancellation.
    }

    func update(_ source: String, replacing: Bool, authorizeCommit: () throws -> Void = {}) async throws -> PrototypeSubscription? {
        if !replacing, isLoading {
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
        let operation = Task { try await download(source) }
        task = operation
        defer {
            if activeGeneration == current {
                task = nil
                activeGeneration = nil
            }
        }
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
            try encoded.write(to: cacheURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            snapshot = updated
            return updated
        } catch {
            guard generation == current, !operation.isCancelled, !Task.isCancelled else { return nil }
            throw error
        }
    }
}
