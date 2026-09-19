import TotemKit
import XCTVapor
@testable import App

final class PusherTests: XCTestCase {
    var app: Application!

    override func setUp() async throws {
        app = try await makeTestApp()
        // Nothing here goes through `app.test`, which is what boots the app.
        try await app.asyncBoot()
    }

    override func tearDown() async throws {
        try await app.asyncShutdown()
    }

    func testPushWindowIsClaimedOncePerKindAndPair() async throws {
        let pusher = Pusher(app: app)
        let recipient = UUID(), subject = UUID()

        let first = await pusher.claimPushWindow(kind: "knock", recipient: recipient,
                                                 subject: subject, window: 60)
        XCTAssertTrue(first)
        let again = await pusher.claimPushWindow(kind: "knock", recipient: recipient,
                                                  subject: subject, window: 60)
        XCTAssertFalse(again)

        let otherKind = await pusher.claimPushWindow(kind: "signon", recipient: recipient,
                                                     subject: subject, window: 60)
        XCTAssertTrue(otherKind)
        let otherPair = await pusher.claimPushWindow(kind: "knock", recipient: subject,
                                                     subject: recipient, window: 60)
        XCTAssertTrue(otherPair)
    }
}
