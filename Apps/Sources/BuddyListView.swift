import SwiftUI
import TotemKit

/// Primary screen: grouped by state — online, away, idle, then offline collapsed.
/// Alphabetical within group, no algorithmic ordering (spec §6).
struct BuddyListView: View {
    @Environment(AppModel.self) private var model
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

    @ViewBuilder
    private var groupChatsSection: some View {
        let groups = model.groupSessions.values
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

    private var unread: Bool {
        model.unreadPeers.contains(buddy.user.id)
    }

    var body: some View {
        if model.presence(of: buddy).state == .offline {
            // Offline friends are listed but not openable: the server refuses
            // delivery to them, so there's no conversation to have.
            label
        } else {
            #if os(iOS)
            // Custom chevron so it can darken with unread state — the system
            // NavigationLink accessory color isn't styleable.
            ZStack {
                NavigationLink(value: buddy.user.id) { EmptyView() }
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
                openWindow(value: buddy.user.id)
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
