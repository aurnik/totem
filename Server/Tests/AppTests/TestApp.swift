import Fluent
import FluentSQLiteDriver
import Foundation
import XCTVapor
@testable import App

/// A fully configured app on a throwaway SQLite file.
func makeTestApp() async throws -> Application {
    let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("totem-tests-\(UUID().uuidString).sqlite").path
    setenv("DB_PATH", path, 1)
    let app = try await Application.make(.testing)
    try await configure(app)
    return app
}

extension Application {
    /// Signs in with the dev handle login and returns the bearer token.
    func login(_ handle: String) async throws -> String {
        var token = ""
        try await test(.POST, "auth/dev", beforeRequest: { req in
            try req.content.encode(["handle": handle])
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .ok)
            token = try res.content.get(String.self, at: "token")
        })
        return token
    }
}

extension HTTPHeaders {
    static func bearer(_ token: String) -> HTTPHeaders {
        ["Authorization": "Bearer \(token)"]
    }
}
