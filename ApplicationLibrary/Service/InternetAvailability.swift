#if os(iOS)
    import Combine
    import Foundation
    import Network

    @MainActor
    public final class InternetAvailability: ObservableObject {
        public static let shared = InternetAvailability()
        public enum Status {
            case checking, available, unavailable

            public var title: String {
                switch self {
                case .checking: return "Проверка…"
                case .available: return "Интернет доступен"
                case .unavailable: return "Нет доступа к интернету"
                }
            }
        }

        @Published public private(set) var status: Status = .checking
        private var monitor: NWPathMonitor?
        private var periodicTask: Task<Void, Never>?
        private var checkTask: Task<Void, Never>?

        public init() {}

        public func start() {
            guard monitor == nil else { check(); return }
            let monitor = NWPathMonitor()
            self.monitor = monitor
            monitor.pathUpdateHandler = { [weak self] path in
                Task { @MainActor [weak self] in
                    guard let self, self.monitor != nil else { return }
                    if path.status == .satisfied {
                        self.check()
                    } else {
                        self.checkTask?.cancel()
                        self.status = .unavailable
                    }
                }
            }
            monitor.start(queue: DispatchQueue(label: "SubscriptionInternetAvailability"))
            check()
            periodicTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 30_000_000_000)
                    guard !Task.isCancelled else { return }
                    self?.check()
                }
            }
        }

        public func stop() {
            monitor?.cancel()
            monitor = nil
            periodicTask?.cancel()
            periodicTask = nil
            checkTask?.cancel()
            checkTask = nil
        }

        public func check() {
            guard monitor != nil else { return }
            checkTask?.cancel()
            status = .checking
            checkTask = Task { [weak self] in
                let available = await Self.probe()
                guard !Task.isCancelled else { return }
                self?.status = available ? .available : .unavailable
            }
        }

        public nonisolated static func isExpectedResponse(url: URL, response: HTTPURLResponse, data: Data) -> Bool {
            guard response.url == url else { return false }
            if url.host == "www.gstatic.com", url.path == "/generate_204" {
                return response.statusCode == 204 && data.isEmpty
            }
            guard url.host == "www.cloudflare.com", url.path == "/cdn-cgi/trace", response.statusCode == 200,
                  let text = String(data: data, encoding: .utf8),
                  let line = text.split(separator: "\n").first(where: { $0.hasPrefix("ip=") }) else { return false }
            let address = String(line.dropFirst(3))
            return IPv4Address(address) != nil || IPv6Address(address) != nil
        }

        private nonisolated static func probe() async -> Bool {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 10
            configuration.timeoutIntervalForResource = 10
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            let session = URLSession(configuration: configuration)
            defer { session.invalidateAndCancel() }
            return await withTaskGroup(of: Bool.self) { group in
                for address in ["https://www.gstatic.com/generate_204", "https://www.cloudflare.com/cdn-cgi/trace"] {
                    guard let url = URL(string: address) else { continue }
                    group.addTask {
                        do {
                            let (data, response) = try await session.data(from: url)
                            guard let response = response as? HTTPURLResponse else { return false }
                            return isExpectedResponse(url: url, response: response, data: data)
                        } catch { return false }
                    }
                }
                for await result in group where result {
                    group.cancelAll()
                    return true
                }
                return false
            }
        }
    }
#endif
