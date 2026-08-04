import SwiftUI
import TotemKit

/// "New chat with…" composer: search over friends (fuzzy), one-tap chat open,
/// checkbox multi-select for groups, and an inline "Add friend" row when the
/// typed text isn't an existing friend's handle.
struct NewChatSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let onOpen: (UUID) -> Void

    @State private var query = ""
    @State private var selected: Set<UUID> = []
    @State private var busy = false
    @State private var errorMessage: String?
    @State private var statusMessage: String?

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespaces).lowercased()
    }

    /// Show "Add friend" whenever the typed text isn't an existing friend's
    /// exact handle (or a Recents row already offering the same add).
    private var showsAddFriendRow: Bool {
        trimmedQuery.count >= 3 && !model.acceptedBuddies.contains {
            $0.user.handle.lowercased() == trimmedQuery
        } && !model.recentNonFriends.contains {
            $0.handle.lowercased() == trimmedQuery
        }
    }

    private var results: [Buddy] {
        let friends = model.acceptedBuddies
        guard !trimmedQuery.isEmpty else { return friends }
        return friends
            .compactMap { buddy in
                fuzzyScore(needle: trimmedQuery, in: buddy.user.handle.lowercased())
                    .map { (buddy, $0) }
            }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }

    /// Group-chat co-participants who aren't friends yet — one tap sends the
    /// request. Filtered by the same fuzzy match as friends.
    private var recentResults: [User] {
        let recents = model.recentNonFriends
        guard !trimmedQuery.isEmpty else { return recents }
        return recents
            .compactMap { user in
                fuzzyScore(needle: trimmedQuery, in: user.handle.lowercased())
                    .map { (user, $0) }
            }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }

    private var selectedHandles: [String] {
        model.acceptedBuddies
            .filter { selected.contains($0.user.id) }
            .map(\.user.handle)
    }

    private var startLabel: String {
        selected.count > 1 ? "Chat (\(selected.count))" : "Chat"
    }

    var body: some View {
        #if os(iOS)
        NavigationStack {
            friendList
                .searchable(
                    text: $query,
                    placement: .navigationBarDrawer(displayMode: .always),
                    prompt: "Search or type a handle"
                )
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .navigationTitle("New Chat")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(startLabel) { start() }
                            .fontWeight(.semibold)
                            .disabled(selected.isEmpty || busy)
                    }
                }
        }
        #else
        VStack(alignment: .leading, spacing: 12) {
            Text("New chat with…")
                .font(.headline)
            TextField("Search or type a handle", text: $query)
                .textFieldStyle(.roundedBorder)
            friendList
                .listStyle(.plain)
                .frame(minHeight: 220)
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button(startLabel) { start() }
                    .buttonStyle(.borderedProminent)
                    .disabled(selected.isEmpty || busy)
            }
        }
        .padding()
        .frame(minWidth: 340, minHeight: 420)
        #endif
    }

    private var friendList: some View {
        List {
            if showsAddFriendRow {
                Section {
                    Button(action: addFriend) {
                        Label("Add friend: \(trimmedQuery)", systemImage: "person.badge.plus")
                    }
                }
            }
            Section {
                ForEach(results) { buddy in
                    friendRow(buddy)
                }
            } header: {
                if !selected.isEmpty {
                    Text("To: \(selectedHandles.joined(separator: ", "))")
                }
            } footer: {
                if let errorMessage {
                    Text(errorMessage).foregroundStyle(.red)
                } else if let statusMessage {
                    Text(statusMessage)
                }
            }
            if !recentResults.isEmpty {
                Section("Recents") {
                    ForEach(recentResults) { user in
                        recentRow(user)
                    }
                }
            }
        }
        .onChange(of: query) {
            errorMessage = nil
            statusMessage = nil
        }
    }

    private func friendRow(_ buddy: Buddy) -> some View {
        let isSelected = selected.contains(buddy.user.id)
        let offline = model.presence(of: buddy).state == .offline
        // Row tap only selects; the chat opens from the Chat button.
        // Offline friends stay visible (the greyscale avatar says why) but
        // can't be chatted — the server refuses delivery to them.
        return Button {
            toggle(buddy.user.id)
        } label: {
            HStack {
                PresenceAvatar(avatar: buddy.user.avatar, state: model.presence(of: buddy).state)
                Text(buddy.user.handle)
                    .foregroundStyle(offline ? .secondary : .primary)
                Spacer()
                if !offline {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(isSelected ? Color.accentColor : Color.secondary.opacity(0.5))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(offline)
    }

    /// From group chats together but not friends: the whole row is the
    /// one-tap "add friend".
    private func recentRow(_ user: User) -> some View {
        Button {
            sendRequest(to: user.handle)
        } label: {
            HStack {
                UserAvatar(avatar: user.avatar, size: 32)
                Text(user.handle)
                Spacer()
                Image(systemName: "person.badge.plus")
                    .foregroundStyle(Color.accentColor)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func toggle(_ id: UUID) {
        if selected.contains(id) {
            selected.remove(id)
        } else {
            selected.insert(id)
            query = ""
        }
    }

    private func addFriend() {
        sendRequest(to: trimmedQuery)
    }

    private func sendRequest(to handle: String) {
        errorMessage = nil
        Task {
            do {
                try await model.addBuddy(handle: handle)
                statusMessage = "Request sent to \(handle)."
                query = ""
            } catch URLError.resourceUnavailable {
                errorMessage = "No user with the handle \"\(handle)\"."
            } catch {
                errorMessage = "Couldn't reach the server."
            }
        }
    }

    private func start() {
        // Anyone who went offline since being selected is silently dropped.
        selected = selected.filter { (model.presences[$0]?.state ?? .offline) != .offline }
        guard !selected.isEmpty else {
            errorMessage = "Everyone selected went offline."
            return
        }
        busy = true
        Task {
            do {
                let conversationID = try await model.startChat(with: Array(selected))
                dismiss()
                onOpen(conversationID)
            } catch {
                errorMessage = "Couldn't start the chat."
                busy = false
            }
        }
    }
}

/// Subsequence fuzzy match: every needle character must appear in order.
/// Contiguous runs and prefix matches score higher.
func fuzzyScore(needle: String, in haystack: String) -> Int? {
    guard !needle.isEmpty else { return 0 }
    var score = 0
    var streak = 0
    var index = haystack.startIndex
    for character in needle {
        var found = false
        while index < haystack.endIndex {
            if haystack[index] == character {
                streak += 1
                score += 1 + streak
                index = haystack.index(after: index)
                found = true
                break
            }
            streak = 0
            index = haystack.index(after: index)
        }
        if !found { return nil }
    }
    if haystack.hasPrefix(needle) { score += 10 }
    return score
}
