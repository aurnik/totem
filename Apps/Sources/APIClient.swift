import Foundation
import TotemKit

/// Stateless HTTP client for auth, buddies, sessions, and settings. The live
/// channel is `SocketClient`.
struct APIClient {
    /// Distributed builds carry their server in `TotemDefaultServerURL`;
    /// development builds may set `TotemDevServerURL` (a LAN hostname for a
    /// physical device) and otherwise use loopback.
    static var defaultServerURL: String {
        let info = Bundle.main.infoDictionary ?? [:]
        for key in ["TotemDefaultServerURL", "TotemDevServerURL"] {
            if let url = info[key] as? String, !url.isEmpty { return url }
        }
        return "http://127.0.0.1:9047"
    }

    var baseURL = URL(string: APIClient.defaultServerURL)!
    var token: String?

    func devLogin(handle: String) async throws -> LoginResponse {
        try await post("auth/dev", body: ["handle": handle])
    }

    func buddies() async throws -> [Buddy] {
        try await get("buddies")
    }

    func sendBuddyRequest(handle: String) async throws {
        let _: EmptyResponse = try await post("buddies/requests", body: ["handle": handle])
    }

    func acceptBuddyRequest(id: UUID) async throws {
        let _: EmptyResponse = try await post("buddies/requests/\(id.uuidString)/accept", body: [String: String]())
    }

    func createSession(participantIDs: [UUID]) async throws -> SessionInfo {
        try await post("sessions", body: ["participantIDs": participantIDs.map(\.uuidString)])
    }

    /// Throws `URLError.resourceUnavailable` when the server has no YouTube key.
    func searchYouTube(_ query: String) async throws -> [YouTubeVideo] {
        try await get("youtube/search", query: [.init(name: "q", value: query)])
    }

    /// The stage's player page. YouTube refuses to embed into a web view fed
    /// raw HTML, so the server hosts the page at a real origin.
    func playerURL(videoID: String, start: Double, playing: Bool) -> URL {
        baseURL.appending(path: "player")
            .appending(queryItems: [
                .init(name: "v", value: videoID),
                .init(name: "t", value: String(Int(start))),
                .init(name: "playing", value: playing ? "1" : "0"),
            ])
    }

    func setAvatar(_ avatar: Avatar) async throws {
        let _: EmptyResponse = try await post("me/avatar", body: avatar)
    }

    func registerPushToken(_ token: String) async throws {
        let _: EmptyResponse = try await post("push/token", body: ["token": token])
    }

    func pushSettings() async throws -> PushSettings {
        try await get("push/settings")
    }

    func setPushSettings(_ settings: PushSettings) async throws {
        let _: PushSettings = try await post("push/settings", body: settings)
    }

    var socketURL: URL {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        components.scheme = components.scheme == "https" ? "wss" : "ws"
        components.path = "/ws"
        return components.url!
    }

    // MARK: - Plumbing

    private struct EmptyResponse: Codable {}

    private func request(_ path: String, query: [URLQueryItem] = [],
                         method: String, body: (some Encodable)?) throws -> URLRequest {
        var url = baseURL.appending(path: path)
        if !query.isEmpty { url.append(queryItems: query) }
        var request = URLRequest(url: url)
        request.httpMethod = method
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        }
        return request
    }

    private func run<T: Decodable>(_ request: URLRequest) async throws -> T {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            switch (response as? HTTPURLResponse)?.statusCode {
            case 401: throw URLError(.userAuthenticationRequired)
            case 404: throw URLError(.resourceUnavailable)
            default: throw URLError(.badServerResponse)
            }
        }
        if T.self == EmptyResponse.self { return EmptyResponse() as! T }
        return try WireCoder.decoder().decode(T.self, from: data)
    }

    private func get<T: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws -> T {
        try await run(request(path, query: query, method: "GET", body: String?.none))
    }

    private func post<T: Decodable>(_ path: String, body: (some Encodable)?) async throws -> T {
        try await run(request(path, method: "POST", body: body))
    }
}
