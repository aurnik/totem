import SwiftUI
import TotemKit

/// One field that takes either a search or a pasted link, because the server's
/// YouTube key is optional — without it search 404s and pasting is the whole
/// interface. Picking a result puts it on the stage for everyone immediately;
/// there's no confirm step and no queue.
struct YouTubePickerSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let conversationID: UUID

    @State private var query = ""
    @State private var results: [YouTubeVideo] = []
    @State private var searching = false
    @State private var message: String?

    /// A pasted link resolves locally through YouTube's keyless oEmbed
    /// endpoint, so it works even when the server has no API key.
    private var pastedVideoID: String? {
        Self.videoID(fromURL: query)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("Search YouTube or paste a link", text: $query)
                        .textFieldStyle(.plain)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .submitLabel(.search)
                        #endif
                        .onSubmit(run)
                }
                if searching {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Searching…").foregroundStyle(.secondary)
                    }
                }
                if let message {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                ForEach(results) { video in
                    Button { play(video) } label: { row(video) }
                        .buttonStyle(.plain)
                }
            }
            .navigationTitle("YouTube")
            .inlineTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onChange(of: query) {
                // A pasted link needs no search, and no button either.
                if pastedVideoID != nil { run() }
            }
        }
        #if os(iOS)
        .presentationDetents([.medium, .large])
        #else
        .frame(minWidth: 340, minHeight: 380)
        #endif
    }

    private func row(_ video: YouTubeVideo) -> some View {
        HStack(spacing: 10) {
            AsyncImage(url: video.thumbnailURL) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                Rectangle().fill(.quaternary)
            }
            .frame(width: 64, height: 36)
            .clipShape(.rect(cornerRadius: 4))
            VStack(alignment: .leading, spacing: 2) {
                Text(video.title).font(.footnote).lineLimit(2)
                Text(video.channel).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }

    private func play(_ video: YouTubeVideo) {
        model.sendStageAction(
            .youtube(.setVideo(videoID: video.id, title: video.title,
                               thumbnailURL: video.thumbnailURL)),
            in: conversationID)
        dismiss()
    }

    private func run() {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        message = nil
        if let videoID = pastedVideoID {
            Task { await resolvePasted(videoID) }
        } else {
            Task { await search(text) }
        }
    }

    private func search(_ text: String) async {
        searching = true
        defer { searching = false }
        do {
            results = try await model.searchYouTube(text)
            if results.isEmpty { message = "No results." }
        } catch URLError.resourceUnavailable {
            message = "Search isn't set up on this server — paste a YouTube link instead."
        } catch {
            message = "Couldn't search right now."
        }
    }

    /// oEmbed needs no API key, so a pasted link works regardless of server
    /// configuration. If it fails the ID is still good enough to play.
    private func resolvePasted(_ videoID: String) async {
        searching = true
        defer { searching = false }
        let fallback = YouTubeVideo(id: videoID, title: "YouTube video", channel: "",
                                    thumbnailURL: URL(string: "https://img.youtube.com/vi/\(videoID)/mqdefault.jpg"))
        guard let url = URL(string:
            "https://www.youtube.com/oembed?format=json&url=https://www.youtube.com/watch?v=\(videoID)")
        else {
            results = [fallback]
            return
        }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let info = try JSONDecoder().decode(OEmbed.self, from: data)
            results = [YouTubeVideo(id: videoID, title: info.title,
                                    channel: info.author_name ?? "",
                                    thumbnailURL: info.thumbnail_url.flatMap(URL.init(string:))
                                        ?? fallback.thumbnailURL)]
        } catch {
            results = [fallback]
        }
    }

    private struct OEmbed: Decodable {
        let title: String
        let author_name: String?
        let thumbnail_url: String?
    }

    /// Recognises the link shapes people actually paste, including the mobile
    /// share and Shorts forms.
    static func videoID(fromURL text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URLComponents(string: trimmed), let host = url.host,
              host.contains("youtube.com") || host.contains("youtu.be")
        else { return nil }

        let candidate: String?
        if host.contains("youtu.be") {
            candidate = url.path.split(separator: "/").first.map(String.init)
        } else if url.path == "/watch" {
            candidate = url.queryItems?.first { $0.name == "v" }?.value
        } else if url.path.hasPrefix("/shorts/") || url.path.hasPrefix("/embed/") {
            candidate = url.path.split(separator: "/").dropFirst().first.map(String.init)
        } else {
            candidate = nil
        }
        guard let candidate, !candidate.isEmpty,
              candidate.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
        else { return nil }
        return candidate
    }
}
