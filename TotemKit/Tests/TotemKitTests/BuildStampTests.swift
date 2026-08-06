import XCTest
@testable import TotemKit

final class BuildStampTests: XCTestCase {
    func testABuildBehindTheLatestIsOutdated() {
        XCTAssertTrue(BuildStamp.isOutdated("202608041703", latestAvailable: "202608042134"))
        XCTAssertFalse(BuildStamp.isOutdated("202608042134", latestAvailable: "202608042134"))
        XCTAssertFalse(BuildStamp.isOutdated("202608042134", latestAvailable: "202608041703"))
    }

    /// Stamps are same-width and clock-ordered, so a rollover doesn't reorder
    /// them the way a shorter-string comparison could.
    func testStampsOrderAcrossMonthAndYearRollovers() {
        XCTAssertTrue(BuildStamp.isOutdated("202512312359", latestAvailable: "202601010000"))
        XCTAssertTrue(BuildStamp.isOutdated("202608312359", latestAvailable: "202609010000"))
    }

    /// `project.yml` defaults `CURRENT_PROJECT_VERSION` to "1" and only
    /// `testflight.sh` overrides it, so every locally-built copy reports "1".
    /// If that counted as behind, the banner would be permanent on the machine
    /// Totem is developed on.
    func testLocallyBuiltCopiesAreNeverOutdated() {
        XCTAssertFalse(BuildStamp.isOutdated("1", latestAvailable: "202608042134"))
        XCTAssertFalse(BuildStamp.isOutdated("", latestAvailable: "202608042134"))
        XCTAssertFalse(BuildStamp.isOutdated("1.0.3", latestAvailable: "202608042134"))
        XCTAssertFalse(BuildStamp.isOutdated("20260804213", latestAvailable: "202608042134"))
        XCTAssertFalse(BuildStamp.isOutdated("not-a-build", latestAvailable: "202608042134"))
    }

    /// A server that was never told fails closed: no claim, no banner.
    func testNothingIsOutdatedWithoutALatestBuild() {
        XCTAssertFalse(BuildStamp.isOutdated("202608041703", latestAvailable: nil))
        XCTAssertFalse(BuildStamp.isOutdated("202608041703", latestAvailable: ""))
        XCTAssertFalse(BuildStamp.isOutdated(nil, latestAvailable: "202608042134"))
        XCTAssertFalse(BuildStamp.isOutdated(nil, latestAvailable: nil))
    }

    /// The field rides an existing frame as an optional, so a server that
    /// doesn't send it and a client that doesn't know it both stay readable.
    func testWelcomeStillDecodesWithoutTheField() throws {
        let withoutField = """
        {"welcome":{"self_":{"state":"online"},"buddies":{},"sessions":[],"freshSignOn":true}}
        """
        let decoded = try WireCoder.decoder().decode(
            ServerFrame.self, from: Data(withoutField.utf8))
        guard case .welcome(_, _, _, _, _, _, let latestBuild) = decoded else {
            return XCTFail("expected a welcome frame, got \(decoded)")
        }
        XCTAssertNil(latestBuild)

        let round = try WireCoder.decoder().decode(ServerFrame.self, from: WireCoder.encoder()
            .encode(ServerFrame.welcome(
                self_: Presence(state: .online), buddies: [:], sessions: [],
                freshSignOn: true, selfAvatar: nil, bots: nil, latestBuild: "202608042134")))
        guard case .welcome(_, _, _, _, _, _, let carried) = round else {
            return XCTFail("expected a welcome frame, got \(round)")
        }
        XCTAssertEqual(carried, "202608042134")
    }
}
