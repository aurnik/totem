import SwiftUI
import TotemKit

/// "New chat with…" composer: fuzzy-search input over friends, a checkbox
/// list for multi-select, and group chat creation when more than one friend
/// is picked.
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
    /// exact handle — no separate add-buddy flow.
    private var showsAddFriendRow: Bool {
        trimmedQuery.count >= 3 && !model.acceptedBuddies.contains {
            $0.user.handle.lowercased() == trimmedQuery
        }
    }

    private var results: [Buddy] {
        let friends = model.acceptedBuddies
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return friends }
        return friends
            .compactMap { buddy in
                fuzzyScore(needle: needle, in: buddy.user.handle.lowercased())
                    .map { (buddy, $0) }
            }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }

    private var selectedHandles: [String] {
        model.acceptedBuddies
            .filter { selected.contains($0.user.id) }
            .map(\.user.handle)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New chat with…")
                .font(.headline)
            TextField("Type a handle", text: $query)
                .textFieldStyle(.roundedBorder)
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                #endif
            if !selected.isEmpty {
                Text(selectedHandles.joined(separator: ", "))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            List {
                if showsAddFriendRow {
                    Button {
                        addFriend()
                    } label: {
                        HStack {
                            Image(systemName: "person.badge.plus")
                                .foregroundStyle(Color.accentColor)
                            Text("Add friend: \(trimmedQuery)")
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                ForEach(results) { buddy in
                    Button {
                        tapped(buddy.user.id)
                    } label: {
                        HStack {
                            // Checkbox tap builds a group; a plain row tap with
                            // nothing selected opens the chat in one step.
                            Image(systemName: selected.contains(buddy.user.id)
                                  ? "checkmark.square.fill" : "square")
                                .foregroundStyle(selected.contains(buddy.user.id) ? Color.accentColor : .secondary)
                                .onTapGesture { toggle(buddy.user.id) }
                            Text(buddy.user.handle)
                            Spacer()
                            StateDot(state: model.presence(of: buddy).state)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .listStyle(.plain)
            .frame(minHeight: 180)
            if let errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
            if let statusMessage {
                Text(statusMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button(startLabel) { start() }
                    .buttonStyle(.borderedProminent)
                    .disabled(selected.isEmpty || busy)
            }
        }
        .padding()
        .frame(minWidth: 320, minHeight: 400)
    }

    private var startLabel: String {
        selected.count > 1 ? "Start Group Chat (\(selected.count))" : "Start Chat"
    }

    /// Row tap: with an in-progress group selection it toggles membership;
    /// otherwise it opens the 1:1 chat immediately — fewest taps to a chat.
    private func tapped(_ id: UUID) {
        if selected.isEmpty {
            dismiss()
            onOpen(id)
        } else {
            toggle(id)
        }
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
        let handle = trimmedQuery
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
