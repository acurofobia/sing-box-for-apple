#if DEBUG
    import ApplicationLibrary
    import Libbox
    import Library
    import SwiftUI

    /// Uses the actual profile editor and preference store in the test app's container.
    struct PriorityFailoverUITestFixture: View {
        @State private var profile: Profile?
        @State private var errorMessage: String?

        var body: some View {
            NavigationStackCompat {
                if let profile {
                    EditProfileView().environmentObject(profile)
                } else if let errorMessage {
                    Text(errorMessage)
                } else {
                    ProgressView()
                }
            }
            .task {
                do {
                    if let stored = try await ProfileManager.get(by: "Priority Failover UI Fixture") {
                        profile = stored
                    } else {
                        let content = LibboxProfileContent()
                        content.name = "Priority Failover UI Fixture"
                        content.type = LibboxProfileTypeLocal
                        content.config = """
                        {"outbounds":[
                          {"type":"socks","tag":"p","server":"127.0.0.1","server_port":9},
                          {"type":"socks","tag":"b1","server":"127.0.0.1","server_port":9},
                          {"type":"socks","tag":"b2","server":"127.0.0.1","server_port":9},
                          {"type":"socks","tag":"b3","server":"127.0.0.1","server_port":9},
                          {"type":"selector","tag":"proxy","outbounds":["p","b1","b2","b3"],"default":"p"}
                        ],"route":{"final":"proxy"}}
                        """
                        profile = try await content.importProfile()
                    }
                } catch { errorMessage = error.localizedDescription }
            }
        }
    }
#endif
