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
    @State private var showingAddSheet = false
    @State private var showingNewChat = false
    @State private var showingOffline = false
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
                Menu {
                    Button("New chat with…") { showingNewChat = true }
                    Button("Add Buddy…") { showingAddSheet = true }
                } label: {
                    Label("New", systemImage: "plus")
                }
                if model.isSignedOn {
                    Button("Away…") { showingAwaySheet = true }
                    Button("Sign Off") { model.signOff() }
                }
            }
            .sheet(isPresented: $showingAwaySheet) {
                AwayMessageSheet()
            }
            .sheet(isPresented: $showingAddSheet) {
                AddBuddySheet()
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
                StateDot(state: model.selfState)
                Text(model.currentUser?.handle ?? "")
                    .bold()
                Spacer()
                if let away = model.awayMessage {
                    Text(away)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
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

    private var label: some View {
        let presence = model.presence(of: buddy)
        return HStack {
            StateDot(state: presence.state)
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

struct StateDot: View {
    let state: PresenceState

    var color: Color {
        switch state {
        case .online: .green
        case .away: .orange
        case .idle: .yellow
        case .offline: .gray
        }
    }

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 10, height: 10)
    }
}

struct AddBuddySheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var handle = ""
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 16) {
            Text("Add Buddy")
                .font(.headline)
            Text("Buddies are found by exact handle. They'll need to accept before you see each other.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            TextField("Handle", text: $handle)
                .textFieldStyle(.roundedBorder)
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                #endif
            if let errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Send Request") {
                    Task {
                        do {
                            try await model.addBuddy(handle: handle)
                            dismiss()
                        } catch URLError.resourceUnavailable {
                            errorMessage = "No user with that handle."
                        } catch {
                            errorMessage = "Couldn't reach the server."
                        }
                    }
                }
                .disabled(handle.count < 3)
            }
        }
        .padding()
        .frame(minWidth: 300)
    }
}

struct AwayMessageSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var message = ""

    var body: some View {
        VStack(spacing: 16) {
            Text("Away Message")
                .font(.headline)
            TextField("Back in 5…", text: $message)
                .textFieldStyle(.roundedBorder)
            HStack {
                if model.awayMessage != nil {
                    Button("I'm Back") {
                        model.clearAwayMessage()
                        dismiss()
                    }
                }
                Spacer()
                Button("Set") {
                    model.setAwayMessage(message)
                    dismiss()
                }
                .disabled(message.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding()
        .frame(minWidth: 300)
        .onAppear { message = model.awayMessage ?? "" }
    }
}
