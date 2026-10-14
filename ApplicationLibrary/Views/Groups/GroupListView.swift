import Library
import SwiftUI

public struct GroupListView: View {
    @EnvironmentObject private var environments: ExtensionEnvironments
    @StateObject private var viewModel = GroupListViewModel()
    @State private var failoverStatus: PriorityFailoverStatus?
    @State private var failoverError: String?
    @State private var resuming = false

    public init() {}
    public var body: some View {
        VStack {
            if !CommandTarget.isRemote, let state = failoverStatus, state.mode != "disabled" {
                VStack(alignment: .leading) {
                    Text(state.mode == "manual" ? "Manual Server Selection" : "Automatic Priority Failover")
                    if state.allDown { Text("No Working Proxy Server").foregroundStyle(.red) }
                    if let tag = state.selected { Text(tag).font(.caption) }
                    if state.mode == "manual" {
                        Button("Resume Automatic Selection") { Task { await resume() } }
                            .accessibilityIdentifier("priorityFailover.resume")
                            .disabled(resuming)
                    }
                    if let failoverError { Text(failoverError).foregroundStyle(.red) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
            }
            if viewModel.isLoading {
                Text("Loading...")
            } else {
                ScrollView {
                    LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                        ForEach(viewModel.groups, id: \.tag) { group in
                            if group.isExpand {
                                Section {
                                    GroupContentView(group: group)
                                        .padding(.bottom, 14)
                                } header: {
                                    GroupHeaderView(group: group)
                                }
                            } else {
                                GroupHeaderView(group: group)
                                GroupContentView(group: group)
                                    .padding(.bottom, 14)
                            }
                        }
                    }.padding(16)
                }
            }
        }
        #if os(iOS)
        .background(Color(uiColor: .systemGroupedBackground))
        #endif
        .environmentObject(viewModel)
        .alert($viewModel.alert)
        .task(id: environments.remoteServer?.id) {
            while !Task.isCancelled {
                guard let profile = environments.extensionProfile,
                      profile.canControlPriorityFailoverGroups else {
                    failoverStatus = nil
                    return
                }
                do {
                    let state = try await profile.priorityFailoverStatus()
                    guard !Task.isCancelled, profile.canControlPriorityFailoverGroups else { return }
                    failoverStatus = state
                    failoverError = nil
                } catch {
                    failoverError = error.localizedDescription
                }
                do { try await Task.sleep(nanoseconds: 2 * NSEC_PER_SEC) } catch { return }
            }
        }
        .onAppear {
            viewModel.connect()
        }
        .onReceive(environments.commandClient.$groups) { groups in
            Task { @MainActor in
                viewModel.setGroups(groups)
            }
        }
    }

    @MainActor
    private func resume() async {
        guard let profile = environments.extensionProfile, profile.canControlPriorityFailoverGroups else { return }
        resuming = true
        defer { resuming = false }
        do {
            failoverStatus = try await profile.resumePriorityFailover()
            failoverError = nil
        } catch { failoverError = error.localizedDescription }
    }
}
