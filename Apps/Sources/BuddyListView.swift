import SwiftUI
import TotemKit

/// Primary screen: grouped by state — online, away, idle, then offline collapsed.
/// Alphabetical within group, no algorithmic ordering (spec §6).
struct BuddyListView: View {
    @Environment(AppModel.self) private var model
    @State private var showingAwaySheet = false
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
            .navigationTitle("Buddy List")
            .toolbar {
                if model.isSignedOn {
                    Button("Away…") { showingAwaySheet = true }
                    Button("Sign Off") { model.signOff() }
                }
            }
            .sheet(isPresented: $showingAwaySheet) {
                AwayMessageSheet()
            }
            .refreshable {
                try? await model.refreshBuddies()
            }
        }
    }

    private var signedOffHeader: some View {
        VStack(spacing: 12) {
            Text("You're signed off.")
                .foregroundStyle(.secondary)
            Button("Sign On") { model.signOn() }
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity)
        .padding()
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
    let buddy: Buddy

    var body: some View {
        let presence = model.presence(of: buddy)
        HStack {
            StateDot(state: presence.state)
            VStack(alignment: .leading) {
                Text(buddy.user.handle)
                if let away = presence.awayMessage {
                    Text(away)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        // TODO: tap → conversation (build-sequence step 4); offline buddies
        // get "leave a message" instead of a live window (spec §6).
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
