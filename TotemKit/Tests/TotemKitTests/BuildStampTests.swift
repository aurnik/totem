import XCTest
@testable import TotemKit

final class BuildStampTests: XCTestCase {
    func testABuildBehindTheLatestIsOutdated() {
        XCTAssertTrue(BuildStamp.isOutdated("202608041703", latestAvailable: "202608042134"))
        XCTAssertFalse(BuildStamp.isOutdated("202608042134", latestAvailable: "202608042134"))
        XCTAssertFalse(BuildStamp.isOutdated("202608042134", latestAvailable: "202608041703"))
    }

    /// Stamps are fixed-width and clock-ordered.
    func testStampsOrderAcrossMonthAndYearRollovers() {
        XCTAssertTrue(BuildStamp.isOutdated("202512312359", latestAvailable: "202601010000"))
        XCTAssertTrue(BuildStamp.isOutdated("202608312359", latestAvailable: "202609010000"))
    }

    /// Locally-built copies report "1" and are never behind.
    func testLocallyBuiltCopiesAreNeverOutdated() {
        XCTAssertFalse(BuildStamp.isOutdated("1", latestAvailable: "202608042134"))
        XCTAssertFalse(BuildStamp.isOutdated("", latestAvailable: "202608042134"))
        XCTAssertFalse(BuildStamp.isOutdated("1.0.3", latestAvailable: "202608042134"))
        XCTAssertFalse(BuildStamp.isOutdated("20260804213", latestAvailable: "202608042134"))
        XCTAssertFalse(BuildStamp.isOutdated("not-a-build", latestAvailable: "202608042134"))
    }

    /// A server that was never told the latest build makes no claim.
    func testNothingIsOutdatedWithoutALatestBuild() {
        XCTAssertFalse(BuildStamp.isOutdated("202608041703", latestAvailable: nil))
        XCTAssertFalse(BuildStamp.isOutdated("202608041703", latestAvailable: ""))
        XCTAssertFalse(BuildStamp.isOutdated(nil, latestAvailable: "202608042134"))
        XCTAssertFalse(BuildStamp.isOutdated(nil, latestAvailable: nil))
    }

    /// The optional field stays readable in both directions.
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
