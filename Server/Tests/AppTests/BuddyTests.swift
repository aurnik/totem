import Fluent
import TotemKit
import XCTVapor
@testable import App

final class BuddyTests: XCTestCase {
    var app: Application!

    override func setUp() async throws {
        app = try await makeTestApp()
    }

    override func tearDown() async throws {
        try await app.asyncShutdown()
    }

    func testRequestAndAcceptFormsAMutualBuddyship() async throws {
        let alice = try await app.login("alice")
        let bob = try await app.login("bob")

        try await app.test(.POST, "buddies/requests", headers: .bearer(alice), beforeRequest: { req in
            try req.content.encode(["handle": "bob"])
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .created)
        })

        var requestID: UUID?
        try await app.test(.GET, "buddies", headers: .bearer(bob)) { res in
            let buddies = try res.content.decode([Buddy].self)
            XCTAssertEqual(buddies.count, 1)
            XCTAssertEqual(buddies.first?.status, .pending)
            XCTAssertEqual(buddies.first?.incoming, true)
            requestID = buddies.first?.id
        }

        try await app.test(.POST, "buddies/requests/\(requestID!.uuidString)/accept",
                           headers: .bearer(bob)) { res in
            XCTAssertEqual(res.status, .ok)
        }

        for token in [alice, bob] {
            try await app.test(.GET, "buddies", headers: .bearer(token)) { res in
                let buddies = try res.content.decode([Buddy].self)
                XCTAssertEqual(buddies.map(\.status), [.accepted])
            }
        }
    }

    func testCrossedRequestsAutoAccept() async throws {
        let alice = try await app.login("alice")
        let bob = try await app.login("bob")
        for (token, other) in [(alice, "bob"), (bob, "alice")] {
            try await app.test(.POST, "buddies/requests", headers: .bearer(token), beforeRequest: { req in
                try req.content.encode(["handle": other])
            }, afterResponse: { res in
                XCTAssertEqual(res.status, .created)
            })
        }
        let rows = try await BuddyModel.query(on: app.db).all()
        XCTAssertEqual(rows.count, 2)
        XCTAssertTrue(rows.allSatisfy { $0.status == .accepted })
    }

    func testBuddyshipCreatesTheDerivedPairConversation() async throws {
        let alice = try await app.login("alice")
        let bob = try await app.login("bob")
        try await app.test(.POST, "buddies/requests", headers: .bearer(alice), beforeRequest: { req in
            try req.content.encode(["handle": "bob"])
        })
        try await app.test(.POST, "buddies/requests", headers: .bearer(bob), beforeRequest: { req in
            try req.content.encode(["handle": "alice"])
        })

        let ids = try await UserModel.query(on: app.db).all().map { try $0.requireID() }
        let expected = ConversationID.derive(ids)
        let conversation = try await ConversationModel.find(expected, on: app.db)
        XCTAssertNotNil(conversation)
        XCTAssertEqual(Set(conversation?.participants ?? []), Set(ids))
        XCTAssertFalse(conversation?.isGroup ?? true)
    }

    func testSessionsAreIdempotentPerParticipantSet() async throws {
        let alice = try await app.login("alice")
        let bob = try await app.login("bob")
        let carol = try await app.login("carol")
        for (token, other) in [(alice, "bob"), (bob, "alice"), (alice, "carol"), (carol, "alice")] {
            try await app.test(.POST, "buddies/requests", headers: .bearer(token), beforeRequest: { req in
                try req.content.encode(["handle": other])
            })
        }
        let users = try await UserModel.query(on: app.db).all()
        let others = users.filter { $0.handle != "alice" }.map { try! $0.requireID() }

        var first: UUID?
        for _ in 0..<2 {
            try await app.test(.POST, "sessions", headers: .bearer(alice), beforeRequest: { req in
                try req.content.encode(["participantIDs": others.map(\.uuidString)])
            }, afterResponse: { res in
                XCTAssertEqual(res.status, .ok)
                let info = try res.content.decode(SessionInfo.self)
                XCTAssertTrue(info.isGroup)
                if let first { XCTAssertEqual(info.session.id, first) }
                first = info.session.id
            })
        }
        let rows = try await ConversationModel.query(on: app.db).all()
        XCTAssertEqual(rows.filter(\.isGroup).count, 1)
    }

    func testStrangersCannotStartASession() async throws {
        let alice = try await app.login("alice")
        _ = try await app.login("bob")
        let bobID = try await UserModel.query(on: app.db).filter(\.$handle == "bob").first()!.requireID()
        try await app.test(.POST, "sessions", headers: .bearer(alice), beforeRequest: { req in
            try req.content.encode(["participantIDs": [bobID.uuidString]] as [String: [String]])
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .forbidden)
        })
    }
}
