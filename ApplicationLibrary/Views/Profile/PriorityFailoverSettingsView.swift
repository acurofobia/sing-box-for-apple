import Libbox
import Library
import SwiftUI

struct PriorityFailoverSettingsView: View {
    @EnvironmentObject private var profile: Profile
    #if DEBUG && os(iOS)
        @EnvironmentObject private var environments: ExtensionEnvironments
        @State private var memoryPhase = "baseline"
        @State private var captureStarted = false
    #endif
    @State private var enabled = false
    @State private var policy = PriorityFailoverConfiguration()
    @State private var selectors: [PriorityFailoverMetadata.Selector] = []
    @State private var loading = true
    @State private var saving = false
    @State private var errorMessage: String?
    @State private var saved = false

    private var candidates: [String] {
        selectors.first(where: { $0.tag == policy.selector })?.candidates ?? []
    }

    var body: some View {
        Section {
            if loading {
                ProgressView()
            } else {
                Toggle("Automatic Priority Failover", isOn: $enabled)
                    .accessibilityIdentifier("priorityFailover.enabled")
                    .disabled(selectors.isEmpty && !enabled)
                if enabled {
                    Picker("Selector", selection: $policy.selector) {
                        ForEach(selectors) { Text($0.tag).tag($0.tag) }
                    }
                    .accessibilityIdentifier("priorityFailover.selector")
                    Picker("Preferred Server", selection: $policy.primary) {
                        ForEach(candidates, id: \.self) { Text($0).tag($0) }
                    }
                    .accessibilityIdentifier("priorityFailover.primary")
                    ForEach(Array(policy.backups.enumerated()), id: \.offset) { index, tag in
                        HStack {
                            Text("Backup \(index + 1)")
                            Spacer()
                            Text(tag)
                            Button {
                                policy.backups.swapAt(index, index - 1)
                                saved = false
                            } label: { Image(systemName: "arrow.up") }
                                .buttonStyle(.borderless)
                                .accessibilityLabel("Move Up")
                                .disabled(index == 0)
                            Button {
                                policy.backups.swapAt(index, index + 1)
                                saved = false
                            } label: { Image(systemName: "arrow.down") }
                                .buttonStyle(.borderless)
                                .accessibilityLabel("Move Down")
                                .disabled(index == policy.backups.count - 1)
                        }
                    }
                    Stepper("Check Interval: \(policy.intervalMilliseconds / 1000) s", value: $policy.intervalMilliseconds, in: 1000 ... 3600000, step: 1000)
                    Stepper("Probe Timeout: \(policy.timeoutMilliseconds / 1000) s", value: $policy.timeoutMilliseconds, in: 1000 ... 10000, step: 1000)
                    Stepper("Failures Before Failover: \(policy.failureThreshold)", value: $policy.failureThreshold, in: 1 ... 10)
                    Stepper("Successes Before Recovery: \(policy.recoveryThreshold)", value: $policy.recoveryThreshold, in: 1 ... 10)
                }
                if let errorMessage {
                    Text(errorMessage).foregroundStyle(.red)
                        .accessibilityIdentifier("priorityFailover.error")
                }
                if selectors.isEmpty {
                    Text("A selector with four concrete proxy servers is required.")
                }
                Button("Save Failover Settings") { Task { await save() } }
                    .accessibilityIdentifier("priorityFailover.save")
                    .disabled(saving || profile.id == nil)
                if saving { ProgressView() }
                if saved { Text("Failover Settings Saved") }
                #if DEBUG && os(iOS)
                    if environments.extensionProfile?.activeProvider == .singBox,
                       environments.extensionProfile?.status.isConnectedStrict == true {
                        Picker("Memory Capture Phase", selection: $memoryPhase) {
                            ForEach(["baseline", "primary", "backup", "all_down", "transitions", "background"], id: \.self) { Text($0).tag($0) }
                        }
                        Button("Capture Extension Memory (12 min)") {
                            Task {
                                do {
                                    _ = try await environments.extensionProfile?.capturePriorityFailoverMemory(phase: memoryPhase)
                                    captureStarted = true
                                } catch { errorMessage = error.localizedDescription }
                            }
                        }
                        if captureStarted { Text("Memory Capture Started") }
                        if #available(iOS 16.0, *) {
                            ShareLink("Export Memory CSV", item: FilePath.cacheDirectory.appendingPathComponent("priority-failover-memory-\(memoryPhase).csv"))
                        }
                    }
                #endif
            }
        } header: {
            Text("Priority Failover")
        } footer: {
            Text("The preferred server remains selected while healthy. Manual selection pauses automation until resumed in Groups.")
        }
        .task(id: profile.id) { await load() }
        .onChangeCompat(of: policy.selector) { configureSelector() }
        .onChangeCompat(of: policy.primary) { arrangeBackups() }
        .onChangeCompat(of: enabled) { saved = false }
    }

    private func configureSelector() {
        guard let selector = selectors.first(where: { $0.tag == policy.selector }) else { return }
        if !selector.candidates.contains(policy.primary) {
            policy.primary = selector.candidates.contains(selector.default) ? selector.default : selector.candidates.first ?? ""
        }
        arrangeBackups()
    }

    private func arrangeBackups() {
        let remaining = candidates.filter { $0 != policy.primary }
        policy.backups = policy.backups.filter { remaining.contains($0) }
        policy.backups += remaining.filter { !policy.backups.contains($0) }
        saved = false
    }

    @MainActor
    private func load() async {
        defer { loading = false }
        do {
            let content = try await profile.readAsync()
            let metadata = try await BlockingIO.run { try PriorityFailoverMetadata.read(configContent: content) }
            selectors = metadata.selectors.filter { $0.candidates.count == 4 }
            if let id = profile.id, let stored = try await SharedPreferences.priorityFailover(id).getThrowing() {
                policy = stored
                enabled = true
                do { try stored.validate(configContent: content) } catch { errorMessage = error.localizedDescription }
            } else if let first = selectors.first {
                policy.selector = first.tag
                configureSelector()
            }
        } catch { errorMessage = error.localizedDescription }
    }

    @MainActor
    private func save() async {
        guard let id = profile.id else { return }
        saving = true
        saved = false
        errorMessage = nil
        defer { saving = false }
        do {
            if enabled {
                let content = try await profile.readAsync()
                let snapshot = policy
                try await BlockingIO.run {
                    var error: NSError?
                    LibboxCheckConfig(content, &error)
                    if let error { throw error }
                    try snapshot.validate(configContent: content)
                }
                try await SharedPreferences.priorityFailover(id).setThrowing(policy)
            } else {
                try await SharedPreferences.priorityFailover(id).setThrowing(nil)
            }
            try await profile.onProfileUpdated()
            saved = true
        } catch { errorMessage = error.localizedDescription }
    }
}
