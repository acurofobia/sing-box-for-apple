import Foundation

enum PrototypeDeepLink {
    static func subscriptionSource(from url: URL) throws -> String {
        guard let link = URLComponents(url: url, resolvingAgainstBaseURL: false),
              link.scheme?.lowercased() == "vipin", link.host?.lowercased() == "add-subscription",
              link.path.isEmpty || link.path == "/",
              link.user == nil, link.password == nil, link.port == nil, link.fragment == nil,
              let parameters = link.queryItems, parameters.count == 1,
              parameters[0].name == "url", let source = parameters[0].value, !source.isEmpty,
              !source.contains("\\"),
              source.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil
        else { throw PrototypeSubscriptionError.invalidURL }
        _ = try PrototypeSubscription.validatedURL(source)
        return source
    }
}
