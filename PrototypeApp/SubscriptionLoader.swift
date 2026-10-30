import Foundation
import Library

/// One ephemeral session per transaction; native app tokens stay on its origin.
enum PrototypeSubscriptionLoader {
    static func download(_ source: String, deviceHeaders: [String: String]? = nil, accessStore: SubscriptionDeviceAccessStore? = nil) async throws -> PrototypeSubscription {
        let headers = try deviceHeaders ?? SubscriptionDeviceIdentity.headers()
        func request(_ url: URL) -> URLRequest {
            SubscriptionDeviceRequest.request(url, deviceHeaders: SubscriptionDeviceRequest.sameOrigin(source, url.absoluteString) ? headers : [:])
        }
        let url = try PrototypeSubscription.validatedURL(source)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 35
        configuration.timeoutIntervalForResource = 90
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCredentialStorage = nil
        configuration.httpCookieStorage = nil
        let session = URLSession(configuration: configuration, delegate: PrototypeSubscriptionRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (payload, response) = try await data(request(url), limit: 8 * 1024 * 1024, session: session)
        let native = response.value(forHTTPHeaderField: "X-Subscription-Format") == "vipin-v1"
        let decision: SubscriptionDeviceAccessDecision?
        if let root = try JSONSerialization.jsonObject(with: payload) as? [String: Any],
           let access = root["device_access"], !(access is NSNull) {
            guard native, let raw = access as? [String: Any], let hwid = headers["x-hwid"] else {
                throw SubscriptionDeviceAccessError.invalidResponse
            }
            let incoming = try SubscriptionDeviceAccessDecision.decode(JSONSerialization.data(withJSONObject: raw), hwid: hwid)
            decision = try accessStore?.record(incoming, source: source) ?? incoming
            // Apply revocation even if unrelated manifest fields or downloads subsequently fail.
            if decision?.state.isDenied == true { try accessStore?.purgeRuntimeIfDenied(source: source) }
        } else {
            decision = nil
        }
        var result = try PrototypeSubscription.decode(payload)
        guard let uiSource = result.uiURL else { throw PrototypeSubscriptionError.serverUpdateRequired }
        if native {
            guard result.uiToken != nil else { throw PrototypeSubscriptionError.invalidResponse }
            try validateNativeDestination(PrototypeSubscription.validatedURL(uiSource), origin: url)
            if let configSource = result.singBoxURL {
                try validateNativeDestination(PrototypeSubscription.validatedURL(configSource), origin: url)
            }
        }
        result.wdttAccessState = decision?.state
        if decision?.state.isDenied == true { result.vkTurnLink = nil }
        if let configSource = result.singBoxURL {
            var configRequest = try request(PrototypeSubscription.validatedURL(configSource))
            if native, let token = result.uiToken {
                configRequest.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
            }
            let (config, _) = try await data(configRequest, limit: 8 * 1024 * 1024, session: session)
            let root = try JSONSerialization.jsonObject(with: config) as? [String: Any]
            if root?["kind"] != nil || root?["schemaVersion"] != nil {
                result.vlessProvisioning = try PrototypeSubscription.decodeVLESSProvisioning(config)
            } else {
                do {
                    result.vlessOutbound = try PrototypeSubscription.extractVLESS(config)
                } catch {
                    result.warnings.append(String(localized: "Конфигурация VLESS некорректна. Режим недоступен."))
                }
            }
        }
        var uiRequest = try request(PrototypeSubscription.validatedURL(uiSource))
        if let token = result.uiToken {
            uiRequest.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        }
        let (document, _) = try await data(uiRequest, limit: 1024 * 1024, session: session)
        result.uiDocument = try PrototypeUIDocument.decode(document)
        try Task.checkCancellation()
        result.sourceURL = source
        result.updatedAt = Date()
        if let accessStore {
            return try JSONDecoder().decode(PrototypeSubscription.self, from: accessStore.sanitizedSnapshot(JSONEncoder().encode(result)))
        }
        return result
    }

    private static func validateNativeDestination(_ destination: URL, origin: URL) throws {
        let scheme = origin.scheme?.lowercased()
        let host = origin.host?.lowercased()
        // Local HTTP fixtures remain usable; public native provisioning requires TLS.
        let loopback = ["localhost", "127.0.0.1", "[::1]", "::1"].contains(host ?? "")
        guard scheme == "https" || (scheme == "http" && loopback),
              destination.scheme?.lowercased() == scheme,
              destination.host?.lowercased() == host,
              (destination.port ?? (scheme == "https" ? 443 : 80)) == (origin.port ?? (scheme == "https" ? 443 : 80))
        else { throw PrototypeSubscriptionError.invalidURL }
    }

    private static func data(_ request: URLRequest, limit: Int, session: URLSession) async throws -> (Data, HTTPURLResponse) {
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse else { throw PrototypeSubscriptionError.invalidResponse }
        guard response.statusCode == 200 else { throw PrototypeSubscriptionError.httpStatus(response.statusCode) }
        guard response.expectedContentLength <= Int64(limit) else { throw PrototypeSubscriptionError.responseTooLarge }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < limit else { throw PrototypeSubscriptionError.responseTooLarge }
            data.append(byte)
        }
        return (data, response)
    }
}

private final class PrototypeSubscriptionRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_: URLSession, task _: URLSessionTask, willPerformHTTPRedirection _: HTTPURLResponse,
                    newRequest _: URLRequest, completionHandler: @escaping (URLRequest?) -> Void)
    {
        completionHandler(nil)
    }
}
