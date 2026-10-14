#if DEBUG
    import ApplicationLibrary
    import Foundation
    import Library
    import SwiftUI

    /// Uses the actual dashboard and loader with isolated cache and HTTP responses.
    @MainActor
    struct SubscriptionUITestFixture: View {
        @StateObject private var environments: ExtensionEnvironments
        @StateObject private var subscription: ManagedSubscriptionViewModel

        init() {
            let environments = ExtensionEnvironments()
            environments.extensionProfile = .mock
            environments.extensionProfile?.status = .disconnected
            environments.extensionProfileLoading = false
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [FixtureSubscriptionProtocol.self]
            let service = ManagedSubscriptionService(directory: directory, sessionConfiguration: configuration, isConnectionActive: { false })
            let empty = ProcessInfo.processInfo.arguments.contains("-SUBSCRIPTION_EMPTY")
            let initial = empty ? nil : try? ManagedSubscriptionSnapshot.decode(FixtureSubscriptionProtocol.payload(plan: "Saved plan"), sourceURL: "http://fixture.local/subscription/test")
            if let initial { try? initial.save(in: directory) }
            _environments = StateObject(wrappedValue: environments)
            _subscription = StateObject(wrappedValue: ManagedSubscriptionViewModel(service: service, initialSnapshot: initial, loadCache: false))
        }

        var body: some View {
            NavigationStackCompat {
                SubscriptionDashboardView(subscription: subscription) {
                    Text("Диагностика")
                }
                .navigationTitle("Dashboard")
            }
            .environmentObject(environments)
            .onAppear { InternetAvailability.shared.start() }
            .onDisappear { InternetAvailability.shared.stop() }
        }
    }

    private final class FixtureSubscriptionProtocol: URLProtocol {
        static func payload(plan: String) -> Data {
            Data("""
            {"schema_version":1,"plan_name":"\(plan)","remaining_days":0,
             "sing_box":{"outbounds":[{"type":"direct","tag":"direct"}]},"vk_turn_link":null}
            """.utf8)
        }

        override static func canInit(with _: URLRequest) -> Bool { true }
        override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            if ProcessInfo.processInfo.arguments.contains("-SUBSCRIPTION_OFFLINE") {
                client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
                return
            }
            guard let url = request.url, let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil) else { return }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Self.payload(plan: "Updated plan"))
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }
#endif
