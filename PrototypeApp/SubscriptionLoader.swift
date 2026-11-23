import Foundation
import Library

/// One ephemeral session per transaction; native app tokens stay on its origin.
enum PrototypeSubscriptionLoader {
    static func download(_ source: String, deviceHeaders: [String: String]? = nil, accessStore: SubscriptionDeviceAccessStore? = nil, service: Bool = false) async throws -> PrototypeSubscription {
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
        var initial = request(url)
        initial.setValue((initial.value(forHTTPHeaderField: "X-Subscription-Capabilities") ?? "") + " service-wdtt-v1 wdtt-preparation-v1",
                         forHTTPHeaderField: "X-Subscription-Capabilities")
        initial.setValue("vipin-v2", forHTTPHeaderField: "X-Subscription-Format")
        if let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String {
            initial.setValue(build, forHTTPHeaderField: "X-App-Build")
        }
        // A bundled response can wait for both WDTT and VLESS upstreams.
        initial.timeoutInterval = 75
        let payload: Data
        let response: HTTPURLResponse
        do {
            (payload, response) = try await downloadBundle(initial, session: session)
        } catch PrototypeSubscriptionError.httpStatus(406) {
            (payload, response) = try await data(request(url), limit: 8 * 1024 * 1024, session: session)
        }
        let format = response.value(forHTTPHeaderField: "X-Subscription-Format")
        let bundled = format == "vipin-v2"
        let native = bundled || format == "vipin-v1"
        if bundled { try validateNativeDestination(url, origin: url) }
        guard let root = try JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
            throw PrototypeSubscriptionError.invalidResponse
        }
        let accessState: SubscriptionDeviceAccessState?
        if let access = root["device_access"], !(access is NSNull) {
            guard native, let raw = access as? [String: Any], let hwid = headers["x-hwid"] else {
                throw SubscriptionDeviceAccessError.invalidResponse
            }
            let incoming = try SubscriptionDeviceAccessDecision.decode(JSONSerialization.data(withJSONObject: raw), hwid: hwid)
            guard response.statusCode == 200 || incoming.state.isDenied else {
                throw PrototypeSubscriptionError.httpStatus(response.statusCode)
            }
            // Apply revocation even if unrelated manifest fields or downloads subsequently fail.
            accessState = try await accessStore?.record(incoming, source: source).state ?? incoming.state
        } else {
            accessState = nil
        }
        guard response.statusCode == 200 else { throw PrototypeSubscriptionError.httpStatus(response.statusCode) }
        var result = try PrototypeSubscription.decode(payload)
        result.wdttAccessState = accessState
        if accessState?.isDenied == true { result.vkTurnLink = nil }
        if bundled {
            if let service = root["service_wdtt"] as? [String: Any],
               let data = try? JSONSerialization.data(withJSONObject: service) {
                result.serviceWDTT = PrototypeServiceWDTT.validated(data)
            }
            if let routing = root["routing"] {
                guard let object = routing as? [String: Any] else { throw PrototypeSubscriptionError.invalidResponse }
                result.routing = try JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])
            }
            guard let config = root["vless"] else { throw PrototypeSubscriptionError.invalidResponse }
            if !(config is NSNull) {
                guard let object = config as? [String: Any] else { throw PrototypeSubscriptionError.invalidVLESS }
                result.vlessProvisioning = try PrototypeSubscription.decodeVLESSProvisioning(JSONSerialization.data(withJSONObject: object))
            }
            result.uiDocument = try PrototypeUIDocument.decode(payload, embedded: true)
        } else {
            guard let uiSource = result.uiURL else { throw PrototypeSubscriptionError.serverUpdateRequired }
            if native, result.uiToken == nil { throw PrototypeSubscriptionError.invalidResponse }
            if native || service {
                try validateNativeDestination(PrototypeSubscription.validatedURL(uiSource), origin: url)
                if let configSource = result.singBoxURL {
                    try validateNativeDestination(PrototypeSubscription.validatedURL(configSource), origin: url)
                }
            }
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
        }
        try Task.checkCancellation()
        result.sourceURL = source
        result.updatedAt = Date()
        if let accessStore {
            return try JSONDecoder().decode(PrototypeSubscription.self, from: accessStore.sanitizedSnapshot(JSONEncoder().encode(result)))
        }
        return result
    }

    private static func downloadBundle(_ request: URLRequest, session: URLSession) async throws -> (Data, HTTPURLResponse) {
        while true {
            try Task.checkCancellation()
            let (body, response) = try await data(request, limit: 8 * 1024 * 1024, session: session, acceptBundleError: true)
            guard response.statusCode == 202 else { return (body, response) }
            guard let origin = request.url, let destination = response.url else { throw PrototypeSubscriptionError.invalidURL }
            try validateNativeDestination(destination, origin: origin)
            guard let status = try? JSONDecoder().decode([String: String].self, from: body),
                  status == ["error": "wdtt_preparing"] else { throw PrototypeSubscriptionError.invalidResponse }
            let delay = Int(response.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 5
            try await Task.sleep(for: .seconds(min(30, max(1, delay))))
        }
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

    private static func data(_ request: URLRequest, limit: Int, session: URLSession, acceptBundleError: Bool = false) async throws -> (Data, HTTPURLResponse) {
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse else { throw PrototypeSubscriptionError.invalidResponse }
        let bundleError = acceptBundleError && [202, 503].contains(response.statusCode) && response.value(forHTTPHeaderField: "X-Subscription-Format") == "vipin-v2"
        guard response.statusCode == 200 || bundleError else { throw PrototypeSubscriptionError.httpStatus(response.statusCode) }
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
