import SwiftUI
import TotemKit

/// Primary screen: grouped by state — online, away, idle, then offline collapsed.
/// Alphabetical within group, no algorithmic ordering (spec §6).
struct BuddyListView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    #endif
    @State private var showingAwaySheet = false
    @State private var showingNewChat = false
    @State private var showingOffline = false
    @State private var showingSettings = false
    @State private var path = NavigationPath()

    private var grouped: [(PresenceState, [Buddy])] {
        let groups = Dictionary(grouping: model.acceptedBuddies) { model.presence(of: $0).state }
        return [PresenceState.online, .away, .idle].compactMap { state in
            (groups[state] ?? []).isEmpty ? nil : (state, groups[state]!)
        }
    }

    private var offlineBuddies: [Buddy] {
        model.acceptedBuddies.filter { model.presence(of: $0).state == .offline }
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                updateBanner
                if !model.isSignedOn {
                    signedOffHeader
                } else {
                    selfSection
                    requestsSection
                    groupChatsSection
                    ForEach(grouped, id: \.0) { state, buddies in
                        Section(state.rawValue.capitalized) {
                            ForEach(buddies) { BuddyRow(buddy: $0) }
                        }
                    }
                    Section {
                        DisclosureGroup("Offline (\(offlineBuddies.count))", isExpanded: $showingOffline) {
                            ForEach(offlineBuddies) { BuddyRow(buddy: $0) }
                        }
                    }
                }
            }
            .navigationTitle("Friends")
            .toolbar {
                Button("New Chat", systemImage: "plus") { showingNewChat = true }
                if model.isSignedOn {
                    Button("Away…") { showingAwaySheet = true }
                    Button("Sign Off") { model.signOff() }
                }
                Button("Settings", systemImage: "gearshape") { showingSettings = true }
            }
            .sheet(isPresented: $showingAwaySheet) {
                AwayMessageSheet()
            }
            .sheet(isPresented: $showingSettings) {
                SettingsSheet()
                    .environment(model)
            }
            .sheet(isPresented: $showingNewChat) {
                NewChatSheet { conversationID in
                    #if os(iOS)
                    path.append(conversationID)
                    #else
                    openWindow(value: conversationID)
                    #endif
                }
                .environment(model)
            }
            .refreshable {
                try? await model.refreshBuddies()
            }
            #if os(iOS)
            .navigationDestination(for: UUID.self) { conversationID in
                ConversationView(conversationID: conversationID)
            }
            #endif
        }
    }

    /// Testers aren't emailed about new builds, so this is how they find out.
    /// One tap to the update, per the fewest-taps rule. TestFlight's own
    /// scheme opens Totem's page with the Update button; the public join
    /// link is the become-a-tester flow, which tells someone who already is
    /// one that the beta "isn't accepting new testers", so it's only the
    /// fallback for a phone without TestFlight installed.
    @ViewBuilder
    private var updateBanner: some View {
        if model.updateAvailable {
            Section {
                HStack {
                    Button {
                        openURL(URL(string: "itms-beta://beta.itunes.apple.com/v1/app/6796788149")!) { opened in
                            if !opened {
                                openURL(URL(string: "https://testflight.apple.com/join/7QCwQhqT")!)
                            }
                        }
                    } label: {
                        Label("A newer build is ready in TestFlight",
                              systemImage: "arrow.down.circle.fill")
                    }
                    .buttonStyle(.plain)
                    Spacer(minLength: 8)
                    Button("Dismiss", systemImage: "xmark") {
                        model.updateBannerDismissed = true
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var groupChatsSection: some View {
        // Ended sittings stay in `groupSessions` so an open window keeps its
        // roster, but a dead group isn't a chat you can enter from here.
        let groups = model.groupSessions.values
            .filter { !model.endedGroups.contains($0.session.id) }
            .sorted { $0.session.startedAt > $1.session.startedAt }
        if !groups.isEmpty {
            Section("Group Chats") {
                ForEach(groups, id: \.session.id) { info in
                    let unread = model.unreadPeers.contains(info.session.id)
                    let label = HStack {
                        Image(systemName: "person.2.fill")
                            .foregroundStyle(.secondary)
                        Text(model.conversationTitle(info.session.id))
                            .fontWeight(unread ? .bold : .regular)
                            .lineLimit(1)
                    }
                    #if os(iOS)
                    NavigationLink(value: info.session.id) { label }
                    #else
                    Button {
                        openWindow(value: info.session.id)
                    } label: {
                        label.contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    #endif
                }
            }
        }
    }

    private var signedOffHeader: some View {
        VStack(spacing: 12) {
            Text("You're signed off.")
                .foregroundStyle(.secondary)
            Button("Sign On") { model.signOn() }
                .buttonStyle(.borderedProminent)
            Button("Log out of \(model.currentUser?.handle ?? "")") { model.logOut() }
                .font(.footnote)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding()
    }

    @ViewBuilder
    private var requestsSection: some View {
        if !model.incomingRequests.isEmpty || !model.outgoingRequests.isEmpty {
            Section("Pending") {
                ForEach(model.incomingRequests) { request in
                    HStack {
                        Text(request.user.handle)
                        Spacer()
                        Button("Accept") {
                            Task { try? await model.acceptRequest(request) }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                    .swipeActions(edge: .trailing) {
                        Button("Accept") {
                            Task { try? await model.acceptRequest(request) }
                        }
                        .tint(.green)
                    }
                }
                ForEach(model.outgoingRequests) { request in
                    HStack {
                        Text(request.user.handle)
                        Spacer()
                        Text("Sent")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var selfSection: some View {
        Section {
            HStack {
                PresenceAvatar(avatar: model.avatar, state: model.selfState)
                VStack(alignment: .leading) {
                    Text(model.currentUser?.handle ?? "")
                        .bold()
                    if let away = model.awayMessage {
                        Text(away)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
                if model.awayMessage != nil {
                    Button("I'm Back") { model.clearAwayMessage() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }
            }
        }
    }
}

struct BuddyRow: View {
    @Environment(AppModel.self) private var model
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    #endif
    let buddy: Buddy

    /// The pair conversation this row opens — computed from the two user IDs,
    /// which is why tapping a name needs no round trip.
    private var conversationID: UUID? {
        model.conversationID(with: buddy.user.id)
    }

    private var unread: Bool {
        conversationID.map { model.unreadPeers.contains($0) } ?? false
    }

    var body: some View {
        if model.presence(of: buddy).state == .offline || conversationID == nil {
            // Offline friends are listed but not openable: the server refuses
            // delivery to them, so there's no conversation to have.
            label
        } else if let conversationID {
            #if os(iOS)
            // Custom chevron so it can darken with unread state — the system
            // NavigationLink accessory color isn't styleable.
            ZStack {
                NavigationLink(value: conversationID) { EmptyView() }
                    .opacity(0)
                HStack {
                    label
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(unread ? Color.primary : Color(.tertiaryLabel))
                }
            }
            #else
            Button {
                openWindow(value: conversationID)
            } label: {
                label.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            #endif
        }
    }

    private var label: some View {
        let presence = model.presence(of: buddy)
        return HStack {
            PresenceAvatar(avatar: buddy.user.avatar, state: presence.state)
            VStack(alignment: .leading) {
                Text(buddy.user.handle)
                    .fontWeight(unread ? .bold : .regular)
                if let away = presence.awayMessage {
                    Text(away)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            if presence.state == .offline, let lastSeen = buddy.user.lastSeenAt {
                Spacer()
                LastSeenLabel(date: lastSeen)
            }
        }
    }
}

/// How long ago an offline buddy was last here, at a glance: "Just now" for
/// the first hour, then "3hr", "2d", "1wk", "4mo", "1y". Re-rendered each
/// minute so a row doesn't sit on a stale value.
struct LastSeenLabel: View {
    let date: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            Text(Self.label(from: date, to: context.date))
                .font(.footnote.monospacedDigit())
                .foregroundStyle(.tertiary)
        }
    }

    static func label(from date: Date, to now: Date) -> String {
        let hours = Int(max(0, now.timeIntervalSince(date)) / 3600)
        let days = hours / 24
        switch hours {
        case ..<1: return "Just now"
        case ..<24: return "\(hours)hr"
        case ..<(24 * 7): return "\(days)d"
        case ..<(24 * 30): return "\(days / 7)wk"
        case ..<(24 * 365): return "\(days / 30)mo"
        default: return "\(days / 365)y"
        }
    }
}

/// Sets or changes the away message; coming back is the "I'm Back" button on
/// the user's own buddy-list row, not here. Recent messages are one tap.
struct AwayMessageSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var message = ""
    @FocusState private var messageFocused: Bool

    private var canSet: Bool {
        !message.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func set() {
        guard canSet else { return }
        model.setAwayMessage(message)
        dismiss()
    }

    private func recentButton(_ recent: String) -> some View {
        Button {
            model.setAwayMessage(recent)
            dismiss()
        } label: {
            Label(recent, systemImage: "clock.arrow.circlepath")
        }
    }

    var body: some View {
        #if os(iOS)
        NavigationStack {
            List {
                Section {
                    TextField("Back in 5…", text: $message)
                        .focused($messageFocused)
                        .submitLabel(.done)
                        .onSubmit(set)
                }
                if !model.recentAwayMessages.isEmpty {
                    Section("Recent") {
                        ForEach(model.recentAwayMessages, id: \.self, content: recentButton)
                    }
                }
            }
            .navigationTitle("Away Message")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Set", action: set)
                        .disabled(!canSet)
                }
            }
        }
        .presentationDetents([.medium])
        .onAppear {
            message = model.awayMessage ?? ""
            messageFocused = true
        }
        #else
        VStack(alignment: .leading, spacing: 16) {
            Text("Away Message")
                .font(.headline)
            TextField("Back in 5…", text: $message)
                .textFieldStyle(.roundedBorder)
                .onSubmit(set)
            ForEach(model.recentAwayMessages, id: \.self) { recent in
                recentButton(recent)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Set", action: set)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSet)
            }
        }
        .padding()
        .frame(minWidth: 300)
        .onAppear { message = model.awayMessage ?? "" }
        #endif
    }
}
