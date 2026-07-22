import SwiftUI
import TotemKit

@main
struct TotemApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
                .onChange(of: scenePhase) { _, phase in
                    model.scenePhaseChanged(to: phase)
                }
        }
        #if os(macOS)
        // One window per conversation — the AIM interaction model (spec §7).
        WindowGroup("Conversation", for: UUID.self) { $peerID in
            if let peerID {
                ConversationView(peerID: peerID)
                    .environment(model)
            }
        }
        .defaultSize(width: 360, height: 460)

        // Menu bar presence without focusing the app (spec §7).
        MenuBarExtra("Totem \(model.isSignedOn ? "(\(model.onlineBuddyCount))" : "")",
                     systemImage: model.isSignedOn ? "person.2.fill" : "person.2") {
            MenuBarView()
                .environment(model)
        }
        #endif
    }
}

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.currentUser == nil {
            SignInView()
        } else {
            BuddyListView()
        }
    }
}

#if os(macOS)
struct MenuBarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.isSignedOn {
            Text("\(model.onlineBuddyCount) buddies on")
            Divider()
            Button("Sign Off") { model.signOff() }
        } else {
            Button("Sign On") { model.signOn() }
        }
    }
}
#endif
