import SwiftUI
import TotemKit

/// Primary screen: grouped by state — online, away, idle, then offline collapsed.
/// Alphabetical within group, no algorithmic ordering (spec §6).
struct BuddyListView: View {
    @Environment(AppModel.self) private var model
    @State private var showingAwaySheet = false
    @State private var showingAddSheet = false
    @State private var showingOffline = false

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
        NavigationStack {
            List {
                if !model.isSignedOn {
                    signedOffHeader
                } else {
                    selfSection
                    requestsSection
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
                Button("Add Buddy", systemImage: "plus") { showingAddSheet = true }
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
            .refreshable {
                try? await model.refreshBuddies()
            }
            #if os(iOS)
            .navigationDestination(for: UUID.self) { peerID in
                ConversationView(peerID: peerID)
            }
            #endif
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

    var body: some View {
        #if os(iOS)
        NavigationLink(value: buddy.user.id) { label }
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
                    .fontWeight(model.unreadPeers.contains(buddy.user.id) ? .bold : .regular)
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
