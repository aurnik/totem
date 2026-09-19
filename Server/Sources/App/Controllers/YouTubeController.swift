import TotemKit
import Vapor

/// Search for the YouTube picker. The API key stays server-side; without
/// `YOUTUBE_API_KEY` search is off and the picker falls back to pasted links.
struct YouTubeController: RouteCollection {

    func boot(routes: RoutesBuilder) throws {
        routes.grouped("youtube").get("search", use: search)
    }

    func search(req: Request) async throws -> [YouTubeVideo] {
        guard let key = Environment.get("YOUTUBE_API_KEY") else {
            throw Abort(.notFound, reason: "Search is not configured on this server.")
        }
        guard let query = try? req.query.get(String.self, at: "q"),
              !query.trimmingCharacters(in: .whitespaces).isEmpty
        else {
            throw Abort(.badRequest, reason: "Missing search query.")
        }

        var url = URI(string: "https://www.googleapis.com/youtube/v3/search")
        url.query = [
            "part=snippet", "type=video", "videoEmbeddable=true", "maxResults=15",
            "q=\(query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")",
            "key=\(key)",
        ].joined(separator: "&")

        let response = try await req.client.get(url)
        guard response.status == .ok else {
            req.logger.warning("YouTube search failed: \(response.status)")
            throw Abort(.badGateway, reason: "Search is unavailable right now.")
        }
        let results = try response.content.decode(SearchResponse.self)
        return results.items.compactMap(\.video)
    }

    /// Only the fields the picker renders.
    private struct SearchResponse: Content {
        struct Item: Content {
            struct ID: Content { let videoId: String? }
            struct Snippet: Content {
                struct Thumbnails: Content {
                    struct Image: Content { let url: String }
                    let medium: Image?
                    let high: Image?
                }
                let title: String
                let channelTitle: String
                let thumbnails: Thumbnails?
            }
            let id: ID
            let snippet: Snippet

            var video: YouTubeVideo? {
                guard let videoId = id.videoId else { return nil }
                let thumbnail = snippet.thumbnails?.medium ?? snippet.thumbnails?.high
                return YouTubeVideo(
                    id: videoId,
                    title: snippet.title.htmlUnescaped,
                    channel: snippet.channelTitle.htmlUnescaped,
                    thumbnailURL: thumbnail.flatMap { URL(string: $0.url) })
            }
        }
        let items: [Item]
    }
}

extension TotemKit.YouTubeVideo: Content {}

private extension String {
    /// Titles come back with HTML entities, which render literally in a Text.
    var htmlUnescaped: String {
        var out = self
        for (entity, character) in [("&amp;", "&"), ("&quot;", "\""), ("&#39;", "'"),
                                    ("&lt;", "<"), ("&gt;", ">")] {
            out = out.replacingOccurrences(of: entity, with: character)
        }
        return out
    }
}
