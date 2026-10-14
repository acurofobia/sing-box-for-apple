#if os(iOS)
    import Foundation
    import Libbox
    import NetworkExtension

    public actor ManagedSubscriptionService {
        public static let shared = ManagedSubscriptionService()
        public static let profilePath = "configs/managed-subscription-config.json"
        private var refreshTask: Task<ManagedSubscriptionSnapshot, Error>?
        private var refreshURL: String?
        private let directory: URL?
        private let sessionConfiguration: URLSessionConfiguration?
        private let isConnectionActive: @Sendable () async throws -> Bool

        public init(directory: URL? = nil, sessionConfiguration: URLSessionConfiguration? = nil,
                    isConnectionActive: @escaping @Sendable () async throws -> Bool = {
                        guard let profile = try await ExtensionProfile.load() else { return false }
                        return await MainActor.run {
                            profile.status != .disconnected && profile.status != .invalid
                        }
                    }) {
            self.directory = directory
            self.sessionConfiguration = sessionConfiguration
            self.isConnectionActive = isConnectionActive
        }

        public func refresh(sourceURL: String? = nil) async throws -> ManagedSubscriptionSnapshot {
            let source = try sourceURL ?? ManagedSubscriptionSnapshot.load(in: directory).sourceURL
            if let refreshTask {
                guard refreshURL == source else { throw ManagedSubscriptionError.refreshInProgress }
                return try await refreshTask.value
            }
            let replacing = (try? ManagedSubscriptionSnapshot.load(in: directory).sourceURL) != source
            let task = Task {
                if replacing { try await self.ensureStopped() }
                var snapshot = try await Self.download(source, configuration: sessionConfiguration)
                let configuration = snapshot.singBoxConfiguration
                try await BlockingIO.run {
                    var error: NSError?
                    LibboxCheckConfig(configuration, &error)
                    if error != nil { throw ManagedSubscriptionError.invalidResponse }
                }
                if let link = snapshot.vkTurnLink {
                    do { _ = try VKTurnConfiguration.importLink(link) } catch {
                        snapshot.vkTurnLink = nil
                        snapshot.warning = "Ссылка VK TURN некорректна. Будет использован только sing-box."
                    }
                }
                if replacing { try await self.ensureStopped() }
                try snapshot.save(in: directory)
                return snapshot
            }
            refreshTask = task
            refreshURL = source
            defer {
                refreshTask = nil
                refreshURL = nil
            }
            return try await task.value
        }

        public func prepareForStart() async throws -> ManagedSubscriptionSnapshot {
            let snapshot = try ManagedSubscriptionSnapshot.load(in: directory)
            try snapshot.save(in: directory, fileName: ManagedSubscriptionSnapshot.startFileName)
            let directory = FilePath.sharedDirectory.appendingPathComponent("configs", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let profile: Profile
            if let existing = try await ProfileManager.list().first(where: { $0.path == Self.profilePath }) {
                profile = existing
            } else {
                profile = Profile(name: "Подписка", type: .local, path: Self.profilePath)
                try await ProfileManager.create(profile)
            }
            try await profile.writeAsync(snapshot.singBoxConfiguration)
            try await SharedPreferences.selectedProfileID.setThrowing(profile.mustID)
            if Bundle.main.object(forInfoDictionaryKey: "KeychainAccessGroup") != nil {
                if let link = snapshot.vkTurnLink {
                    try VKTurnConfigurationStore.save(VKTurnConfiguration.importLink(link))
                } else {
                    try VKTurnConfigurationStore.clear()
                }
            }
            return snapshot
        }

        private func ensureStopped() async throws {
            if try await isConnectionActive() { throw ManagedSubscriptionError.stopBeforeReplacing }
        }

        private static func download(_ source: String, configuration: URLSessionConfiguration?) async throws -> ManagedSubscriptionSnapshot {
            guard let url = URL(string: source), let host = url.host, !host.isEmpty,
                  ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                  url.user == nil, url.password == nil, url.fragment == nil else {
                throw ManagedSubscriptionError.invalidURL
            }
            let configuration = configuration?.copy() as? URLSessionConfiguration ?? URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 10
            configuration.timeoutIntervalForResource = 10
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            let session = URLSession(configuration: configuration, delegate: NoSubscriptionRedirects(), delegateQueue: nil)
            defer { session.invalidateAndCancel() }
            let (data, response) = try await session.data(from: url)
            guard let response = response as? HTTPURLResponse else { throw ManagedSubscriptionError.invalidResponse }
            guard response.statusCode == 200 else { throw ManagedSubscriptionError.httpStatus(response.statusCode) }
            guard data.count <= 8 * 1024 * 1024 else { throw ManagedSubscriptionError.invalidResponse }
            do { return try ManagedSubscriptionSnapshot.decode(data, sourceURL: source) } catch { throw ManagedSubscriptionError.invalidResponse }
        }
    }

    private final class NoSubscriptionRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_: URLSession, task _: URLSessionTask, willPerformHTTPRedirection _: HTTPURLResponse,
                        newRequest _: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
#endif
