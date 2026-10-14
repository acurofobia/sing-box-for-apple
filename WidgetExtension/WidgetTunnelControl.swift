import Foundation
import Library
import NetworkExtension

enum WidgetAppConfiguration {
    static let packageName: String = {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "BasePackageIdentifier") as? String else {
            fatalError("Missing BasePackageIdentifier in Info.plist")
        }
        return value
    }()

    static let appGroupID: String = {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "AppGroupIdentifier") as? String else {
            fatalError("Missing AppGroupIdentifier in Info.plist")
        }
        return value
    }()

    static var widgetControlKind: String {
        "\(packageName).widget.ServiceToggle"
    }
}

@MainActor
enum WidgetTunnelControl {
    static func currentIsStarted() async throws -> Bool {
        try await ExtensionProfile.load()?.status.isStarted ?? false
    }

    static func setStarted(_ started: Bool) async throws {
        guard let profile = try await ExtensionProfile.load() else {
            throw ManagedSubscriptionError.noSubscription
        }
        if started {
            try await profile.startManual()
        } else {
            try await profile.stop()
        }
    }
}
