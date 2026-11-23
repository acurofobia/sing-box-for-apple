"""Run the iOS recovery coordinator against a controllable tunnel and download."""
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
STUBS = r'''
import Foundation
import Network

enum PrototypeRoutingMode: String { case enabled, disabled }
enum PrototypeConnectionMode: String { case vless, vkTurn = "vk-turn" }
enum PrototypeRouting { static func sourceID(_ source: String) -> String { source } }
enum AppConfiguration { static let extensionBundleID = "test.extension" }
struct Subscription { var sourceURL: String? = "https://example.invalid/sub"; var isComplete = true }
struct PrototypeServiceWDTT {
    let link = "fixture-only"
    static func preferred(for _: Subscription?) -> Self? { Self() }
}
enum NEVPNStatus { case connected, connecting, disconnected, disconnecting, reasserting, invalid }
class NEVPNConnection {
    var status: NEVPNStatus = .disconnected
    var service = ""
    var stops = 0
    var serviceStarts = 0
    var origin = ""
    var completesStop = true
    func stopVPNTunnel() {
        stops += 1
        if completesStop { status = .disconnected; service = "" }
    }
    func startVPNTunnel(options: [String: NSObject]) throws {
        precondition(status == .disconnected)
        service = options["serviceWDTTSession"] as! String
        origin = options["serviceWDTTSource"] as! String
        precondition(!service.isEmpty)
        serviceStarts += 1; status = .connected
    }
}
class NETunnelProviderSession: NEVPNConnection {
    var responds = true
    func sendProviderMessage(_ bytes: Data, responseHandler: @escaping (Data?) -> Void) throws {
        precondition(bytes == Data("service-wdtt-session".utf8))
        if responds { responseHandler(Data(service.utf8)) }
    }
}
class NETunnelProviderProtocol {
    var providerBundleIdentifier: String?
    var serverAddress: String?
    var providerConfiguration: [String: Any]?
}
class NETunnelProviderManager {
    static var denySave = false
    static var saves = 0
    var isEnabled = true
    var protocolConfiguration: Any? = nil
    var localizedDescription: String?
    var connection: NEVPNConnection = NETunnelProviderSession()
    func saveToPreferences() async throws {
        Self.saves += 1
        if Self.denySave { throw CocoaError(.userCancelled) }
    }
    func loadFromPreferences() async throws {}
}
class Store {
    var isLoading = false
    var cancelled = false
    func cancel() { cancelled = true }
}
@MainActor final class PrototypeModel {
    // RECOVERY_FIELDS
    var error: String?
    var subscriptionError: String?
    var subscription = Subscription()
    let preferences = UserDefaults(suiteName: "RecoveryTests." + UUID().uuidString)!
    var busy = false
    var managersLoaded = true
    var resetting = false
    var connectionMode: PrototypeConnectionMode = .vless
    var routingMode: PrototypeRoutingMode = .disabled
    var manager: NETunnelProviderManager? = NETunnelProviderManager()
    let connections = 1
    let store = Store()
    var restored = 0
    var downloads = 0
    var allowed = true
    var scenario = ""
    func isAvailable(_ mode: PrototypeConnectionMode) -> Bool { allowed }
    func synchronizeDeviceAccess() async {}
    func refreshVPNState() {}
    func loadVPN() async { managersLoaded = true }
    func ensureStopped() throws { precondition(manager?.connection.status == .disconnected) }
    func stopForModeChange() async throws { manager?.connection.stopVPNTunnel() }
    func startConnection() async {
        restored += 1
        if scenario == "restore-fails" { error = "failure"; return }
        error = nil
        manager?.connection.status = .connected
    }
    func fetchSubscription(_ source: String, replacing: Bool, service: Bool) async -> Bool {
        precondition(service && source == subscription.sourceURL)
        precondition(manager?.connection.status == .connected && manager?.connection.service != "")
        downloads += 1
        if scenario == "cancel" {
            store.isLoading = true
            while !store.cancelled { await Task.yield() }
            store.isLoading = false
            return false
        }
        if scenario == "download-fails" { subscriptionError = "Ошибка загрузки"; return false }
        if scenario == "revoked" { allowed = false }
        advanceRecovery(from: .download, to: .save)
        return true
    }
}
'''
CHECKS = r'''
extension PrototypeModel {
    func testUnresponsiveOwnerOnRelaunch() async {
        let profile = NETunnelProviderProtocol()
        profile.providerBundleIdentifier = AppConfiguration.extensionBundleID
        manager!.protocolConfiguration = profile
        let vpn = manager!.connection as! NETunnelProviderSession
        vpn.status = .connected
        vpn.responds = false
        pendingRecovery = RecoveryJournal(session: UUID(), mode: "vless", routing: "disabled",
                                          sourceID: subscription.sourceURL, serviceRequested: true)
        resumeRecovery()
        await recoveryTask!.value
        precondition(vpn.stops == 0 && pendingRecovery?.serviceRequested == true && !canDismissRecovery)
        precondition(recovery?.canRetryCleanup == true && recoveryProfileToStop === manager)

        vpn.responds = true
        vpn.service = "unrecognized reply"
        resumeRecovery()
        await recoveryTask!.value
        precondition(vpn.stops == 0 && pendingRecovery?.serviceRequested == true,
                     "an unknown owner reply is not evidence that the service tunnel stopped")
        let selectedProfile = manager!
        manager = NETunnelProviderManager()
        manager!.protocolConfiguration = profile
        manager!.connection.status = .connected
        resumeRecovery(stopping: selectedProfile)
        precondition(recoveryTask == nil && manager!.connection.stops == 0 && vpn.stops == 0)
        manager = selectedProfile

        profile.providerBundleIdentifier = "another.extension"
        precondition(recoveryProfileToStop == nil)
        resumeRecovery(stopping: manager)
        precondition(recoveryTask == nil && vpn.stops == 0 && pendingRecovery?.serviceRequested == true)
        vpn.service = pendingRecovery!.session.uuidString
        resumeRecovery()
        await recoveryTask!.value
        precondition(vpn.stops == 0 && pendingRecovery?.serviceRequested == true)

        profile.providerBundleIdentifier = AppConfiguration.extensionBundleID
        vpn.completesStop = false
        resumeRecovery(stopping: manager)
        await recoveryTask!.value
        precondition(vpn.stops == 1 && vpn.status == .connected && restored == 0)
        precondition(pendingRecovery?.serviceRequested == true && !canDismissRecovery && recoveryProfileToStop === manager)

        vpn.completesStop = true
        vpn.responds = false
        resumeRecovery(stopping: manager)
        await recoveryTask!.value
        precondition(vpn.stops == 2 && restored == 1 && pendingRecovery == nil && canDismissRecovery)
        dismissRecovery()
        precondition(recovery == nil)
    }

    func testFirstImportPermission(denied: Bool) async {
        manager = nil
        subscription.isComplete = false
        NETunnelProviderManager.saves = 0
        NETunnelProviderManager.denySave = denied
        defer { NETunnelProviderManager.denySave = false }
        recovery = Recovery()
        recoveryRequest = (subscription.sourceURL!, true)
        startRecovery()
        await recoveryTask!.value
        precondition(NETunnelProviderManager.saves == 1)
        precondition(recovery?.states[.profile] == (denied ? .failed : .done))
        precondition(downloads == (denied ? 0 : 1) && pendingRecovery == nil)
        if denied { precondition(recovery?.states[.connect] == .skipped) }
    }
    func test(_ which: String) async {
        scenario = which
        let vpn = manager!.connection
        if which != "first" { vpn.status = .connected }
        if which == "relaunch" || which == "regular" {
            let profile = NETunnelProviderProtocol()
            profile.providerBundleIdentifier = AppConfiguration.extensionBundleID
            manager!.protocolConfiguration = profile
            let id = UUID()
            pendingRecovery = RecoveryJournal(session: id, mode: "vless", routing: "disabled", sourceID: subscription.sourceURL,
                                               serviceRequested: true, updated: false)
            vpn.service = which == "relaunch" ? id.uuidString : ""
            resumeRecovery()
            await recoveryTask!.value
            precondition(vpn.stops == (which == "relaunch" ? 1 : 0))
            precondition(restored == (which == "relaunch" ? 1 : 0))
            precondition(downloads == 0 && pendingRecovery == nil)
            return
        }
        if which == "first" { subscription.isComplete = false }
        recovery = Recovery()
        recoveryRequest = (subscription.sourceURL!, which == "first")
        startRecovery()
        startRecovery()
        if which == "cancel" {
            while !store.isLoading { await Task.yield() }
            cancelRecovery()
        }
        await recoveryTask!.value
        precondition(downloads == 1 && vpn.serviceStarts == 1, "duplicate operation")
        precondition(vpn.origin == "https://example.invalid", "URL credentials leaked to provider options")
        precondition(vpn.service.isEmpty && recovery?.states[.disconnect] == .done)
        if which == "first" {
            precondition(vpn.status == .disconnected && restored == 0 && recovery?.imported == true)
            precondition(recovery?.states[.pause] == nil && recovery?.states[.restore] == nil)
        } else if which == "revoked" {
            precondition(vpn.status == .disconnected && recovery?.states[.restore] == .failed && restored == 0)
        } else if which == "restore-fails" {
            precondition(recovery?.canRetryCleanup == true && pendingRecovery?.updated == true)
            scenario = ""
            resumeRecovery(); await recoveryTask!.value
            precondition(downloads == 1 && restored == 2 && vpn.status == .connected)
        } else {
            precondition(vpn.status == .connected && restored == 1 && routingMode == .disabled)
            precondition(recovery?.states[.restore] == .done)
            let expected: StepState = which == "cancel" ? .cancelled : which == "download-fails" ? .failed : .done
            precondition(recovery?.states[.download] == expected)
        }
        precondition(pendingRecovery == nil)
    }
}
@main struct Checks {
    @MainActor static func main() async {
        await PrototypeModel().testUnresponsiveOwnerOnRelaunch()
        for denied in [true, false] { await PrototypeModel().testFirstImportPermission(denied: denied) }
        for scenario in ["first", "success", "download-fails", "cancel", "revoked", "restore-fails", "relaunch", "regular"] {
            await PrototypeModel().test(scenario)
        }
    }
}
'''


class ServiceRecoveryTests(unittest.TestCase):
    def test_restore_cancel_retry_and_relaunch(self):
        app = (ROOT / 'PrototypeApp/Application.swift').read_text()
        fields = app.split('final class PrototypeModel: ObservableObject {', 1)[1].split('@Published var status', 1)[0]
        methods = 'extension PrototypeModel {' + app.split('extension PrototypeModel {', 1)[1]
        with tempfile.TemporaryDirectory() as temp:
            folder = Path(temp)
            source = folder / 'checks.swift'
            source.write_text(STUBS.replace('// RECOVERY_FIELDS', fields.replace('@Published ', '')) + methods + CHECKS)
            result = subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-module-cache-path', str(folder / 'modules'),
                                     str(source), '-o', str(folder / 'checks')], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            result = subprocess.run([str(folder / 'checks')], timeout=15, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
