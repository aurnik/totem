import XCTVapor
@testable import App

final class AuthTests: XCTestCase {
    var app: Application!

    override func setUp() async throws {
        app = try await makeTestApp()
    }

    override func tearDown() async throws {
        try await app.asyncShutdown()
    }

    func testFreshDatabaseMigratesAndServes() async throws {
        let token = try await app.login("alice")
        XCTAssertFalse(token.isEmpty)
        try await app.test(.GET, "buddies", headers: .bearer(token)) { res in
            XCTAssertEqual(res.status, .ok)
            XCTAssertEqual(res.body.string, "[]")
        }
    }

    func testRejectsMalformedHandles() async throws {
        for handle in ["ab", "has space", "way_too_long_for_a_handle"] {
            try await app.test(.POST, "auth/dev", beforeRequest: { req in
                try req.content.encode(["handle": handle])
            }, afterResponse: { res in
                XCTAssertEqual(res.status, .badRequest, handle)
            })
        }
    }

    func testRequiresBearerToken() async throws {
        try await app.test(.GET, "buddies") { res in
            XCTAssertEqual(res.status, .unauthorized)
        }
    }

    func testSameHandleIsSameUser() async throws {
        _ = try await app.login("alice")
        _ = try await app.login("ALICE")
        let users = try await UserModel.query(on: app.db).all()
        XCTAssertEqual(users.map(\.handle), ["alice"])
    }
}
