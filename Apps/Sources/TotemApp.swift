import SwiftUI
import TotemKit

#if os(macOS)
/// Quitting signs off (spec §7): termination waits for the sign-off frame so
/// buddies see the door close immediately instead of after the 90s timeout.
@MainActor
final class MacAppDelegate: NSObject, NSApplicationDelegate {
    static weak var model: AppModel?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let socket = Self.model?.detachSocketForTermination() else { return .terminateNow }
        Task.detached {
            await socket.close()
            await MainActor.run { sender.reply(toApplicationShouldTerminate: true) }
        }
        return .terminateLater
    }
}
#else
/// Best-effort immediate sign-off when the app is killed while running.
/// (No code runs when an already-suspended app is swiped away — the server's
/// liveness sweep covers that case.)
final class PhoneAppDelegate: NSObject, UIApplicationDelegate {
    static weak var model: AppModel?

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        MainActor.assumeIsolated {
            Self.model?.registerPushToken(token)
        }
    }

    func applicationWillTerminate(_ application: UIApplication) {
        let socket = MainActor.assumeIsolated { Self.model?.detachSocketForTermination() }
        guard let socket else { return }
        // The socket actor runs off the main thread, so a short main-thread
        // wait lets the sign-off frame flush before the process dies.
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            await socket.close()
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 1.5)
    }
}
#endif

@main
struct TotemApp: App {
    #if os(macOS)
    @NSApplicationDelegateAdaptor(MacAppDelegate.self) private var appDelegate
    #else
    @UIApplicationDelegateAdaptor(PhoneAppDelegate.self) private var appDelegate
    #endif
    @State private var model: AppModel

    init() {
        let model = AppModel()
        ScreenshotFixture.apply(to: model)
        _model = State(initialValue: model)
        #if os(macOS)
        MacAppDelegate.model = model
        #else
        PhoneAppDelegate.model = model
        #endif
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
                .preferredColorScheme(model.colorScheme)
        }
        #if os(macOS)
        // One window per conversation — the AIM interaction model (spec §7).
        WindowGroup("Conversation", for: UUID.self) { $conversationID in
            if let conversationID {
                ConversationView(conversationID: conversationID)
                    .environment(model)
                    .preferredColorScheme(model.colorScheme)
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
        Group {
            if model.currentUser == nil {
                SignInView()
            } else {
                BuddyListView()
            }
        }
        .explainerCover(isPresented: model.needsNetworkExplainer) {
            model.acknowledgeNetworkExplainer()
        }
    }
}

private extension View {
    /// Nothing else is reachable until it's acknowledged; the sign-on it
    /// gates is the reason the app is open.
    func explainerCover(isPresented: Bool, onContinue: @escaping () -> Void) -> some View {
        let binding = Binding(get: { isPresented }, set: { _ in })
        #if os(iOS)
        return fullScreenCover(isPresented: binding) { LocalNetworkExplainerView(onContinue: onContinue) }
        #else
        return sheet(isPresented: binding) { LocalNetworkExplainerView(onContinue: onContinue) }
        #endif
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
