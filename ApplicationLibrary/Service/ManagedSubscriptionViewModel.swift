#if os(iOS)
    import Foundation
    import Library
    import SwiftUI

    @MainActor
    public final class ManagedSubscriptionViewModel: ObservableObject {
        public static let shared = ManagedSubscriptionViewModel()
        @Published public private(set) var snapshot: ManagedSubscriptionSnapshot?
        @Published public private(set) var isRefreshing = false
        @Published public private(set) var errorMessage: String?

        private let service: ManagedSubscriptionService

        public init(service: ManagedSubscriptionService = .shared, initialSnapshot: ManagedSubscriptionSnapshot? = nil, loadCache: Bool = true) {
            self.service = service
            snapshot = initialSnapshot ?? (loadCache ? try? ManagedSubscriptionSnapshot.load() : nil)
        }

        @discardableResult
        public func refresh(sourceURL: String? = nil) async -> Bool {
            guard !isRefreshing else { return false }
            guard sourceURL != nil || snapshot != nil else { return false }
            isRefreshing = true
            defer { isRefreshing = false }
            do {
                snapshot = try await service.refresh(sourceURL: sourceURL)
                errorMessage = nil
                return true
            } catch let error as ManagedSubscriptionError {
                errorMessage = error.localizedDescription
            } catch is URLError {
                errorMessage = "Не удалось связаться с сервером подписки. Проверьте домашний Wi-Fi, работу сервера и доступ к локальной сети в настройках iOS."
            } catch {
                // Network errors may include the credential-bearing URL or server response.
                errorMessage = "Не удалось обновить подписку. Сохранённые данные доступны для подключения."
            }
            return false
        }
    }
#endif
