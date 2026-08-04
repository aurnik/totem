import Foundation
import TotemKit

/// Stateless HTTP: auth and buddy management (spec §4). The live channel is SocketClient.
struct APIClient {
    /// Simulator and macOS reach the dev server on loopback; a physical phone
    /// needs the Mac's Bonjour hostname (stable across DHCP renewals).
    /// 127.0.0.1 rather than localhost: the server binds IPv4 only, and
    /// localhost resolves to ::1 first. Port 9047 rather than 8080: local
    /// proxy/filter software inspects the well-known http-alt port and
    /// corrupts inbound WebSocket frames.
    static var defaultServerURL: String {
        // Distributed builds carry their server baked in (set by
        // Server/onboard/testflight.sh) so a friend signs in with just a handle.
        if let baked = Bundle.main.object(forInfoDictionaryKey: "TotemDefaultServerURL") as? String,
           !baked.isEmpty {
            return baked
        }
        #if os(iOS) && !targetEnvironment(simulator)
        return "http://Aurniks-MacBook-Pro.local:9047"
        #else
        return "http://127.0.0.1:9047"
        #endif
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

    /// Throws `URLError.resourceUnavailable` (404) when the server has no
    /// YouTube key configured — the picker falls back to pasted links.
    func searchYouTube(_ query: String) async throws -> [YouTubeVideo] {
        let escaped = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        return try await get("youtube/search?q=\(escaped)")
    }

    /// The stage's player page, which must be served from a real HTTP origin —
    /// YouTube refuses to embed into a web view fed raw HTML.
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

    private func request(_ path: String, method: String, body: (some Encodable)?) throws -> URLRequest {
        var request = URLRequest(url: baseURL.appending(path: path))
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

    private func get<T: Decodable>(_ path: String) async throws -> T {
        try await run(request(path, method: "GET", body: String?.none))
    }

    private func post<T: Decodable>(_ path: String, body: (some Encodable)?) async throws -> T {
        try await run(request(path, method: "POST", body: body))
    }
}
