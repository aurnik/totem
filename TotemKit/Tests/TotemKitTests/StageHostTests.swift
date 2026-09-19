import XCTest
@testable import TotemKit

final class StageHostTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private let owner = UUID()
    private let second = UUID()
    private let third = UUID()

    private func video(_ id: String = "abc") -> StageAction {
        .youtube(.setVideo(videoID: id, title: "Video \(id)", thumbnailURL: nil))
    }

    /// The stage a `broadcast` effect carries, failing the test otherwise.
    private func broadcast(_ effects: [StageHost.Effect],
                           file: StaticString = #filePath, line: UInt = #line) -> Stage? {
        guard effects.count == 1, case .broadcast(let stage, _) = effects[0] else {
            XCTFail("expected one broadcast, got \(effects)", file: file, line: line)
            return nil
        }
        return stage
    }

    private func game(_ stage: Stage?) -> FourState? {
        guard case .four(let state)? = stage?.state else { return nil }
        return state
    }

    // MARK: - Claiming

    func testFirstActionOnAnEmptyStageMakesTheActorOwnerAndBroadcasts() {
        let effects = StageHost.act(.four(.start), on: nil, by: owner, at: t0)
        let stage = broadcast(effects)
        XCTAssertEqual(stage?.ownerID, owner)
        XCTAssertEqual(effects, [.broadcast(stage, actorID: owner)])
    }

    func testActionOnSomeoneElsesStageIsForwardedToThemWithTheVersionSeen() {
        let stage = broadcast(StageHost.act(.four(.start), on: nil, by: owner, at: t0))!
        let effects = StageHost.act(.four(.join), on: stage, by: second, at: t0)
        XCTAssertEqual(effects, [.forward(.four(.join), expectedVersion: stage.version, to: owner)])
    }

    func testUnconditionalActionIsForwardedWithoutAVersion() {
        let stage = broadcast(StageHost.act(video("one"), on: nil, by: owner, at: t0))!
        let effects = StageHost.act(video("two"), on: stage, by: second, at: t0)
        XCTAssertEqual(effects, [.forward(video("two"), expectedVersion: nil, to: owner)])
    }

    /// A new video does not change ownership; only emptying the stage does.
    func testOwnerKeepsTheStageWhenSomeoneElseReplacesTheVideo() {
        let stage = broadcast(StageHost.act(video("one"), on: nil, by: owner, at: t0))!
        let replaced = broadcast(StageHost.receive(video("two"), expectedVersion: nil, from: second,
                                                   on: stage, selfID: owner, at: t0))
        XCTAssertEqual(replaced?.ownerID, owner)
        XCTAssertEqual(replaced?.version, 2)
    }

    // MARK: - The join race

    /// The owner applies the first join and re-syncs the second sender alone.
    func testSecondJoinIsRefusedAndResyncedToTheLoser() {
        let empty = broadcast(StageHost.act(.four(.start), on: nil, by: owner, at: t0))!

        let joined = broadcast(StageHost.receive(.four(.join), expectedVersion: empty.version,
                                                 from: second, on: empty, selfID: owner, at: t0))!
        XCTAssertEqual(game(joined)?.yellow, second)

        let late = StageHost.receive(.four(.join), expectedVersion: empty.version,
                                     from: third, on: joined, selfID: owner, at: t0)
        XCTAssertEqual(late, [.resync(joined, to: third)])
        XCTAssertEqual(game(joined)?.yellow, second, "the seat stays with the first to arrive")
    }

    // MARK: - Preserving state

    func testVideoOverALiveGameIsRefusedByTheOwner() {
        let empty = broadcast(StageHost.act(.four(.start), on: nil, by: owner, at: t0))!
        let live = broadcast(StageHost.receive(.four(.join), expectedVersion: empty.version,
                                               from: second, on: empty, selfID: owner, at: t0))!
        let effects = StageHost.receive(video(), expectedVersion: nil, from: third,
                                        on: live, selfID: owner, at: t0)
        XCTAssertEqual(effects, [.resync(live, to: third)])
    }

    func testOwnerRefusingTheirOwnStaleActionHasNothingToCorrect() {
        let empty = broadcast(StageHost.act(.four(.start), on: nil, by: owner, at: t0))!
        // The owner tries to join their own game.
        XCTAssertEqual(StageHost.act(.four(.join), on: empty, by: owner, at: t0), [])
    }

    // MARK: - Actions aimed at the wrong device

    func testActionSentToANonOwnerIsAnsweredWithTheRealStage() {
        let stage = broadcast(StageHost.act(video(), on: nil, by: owner, at: t0))!
        let effects = StageHost.receive(.youtube(.seek(positionSeconds: 5)), expectedVersion: 1,
                                        from: third, on: stage, selfID: second, at: t0)
        XCTAssertEqual(effects, [.resync(stage, to: third)])
    }

    func testActionForAStageThatIsGoneIsAnsweredWithNothing() {
        let effects = StageHost.receive(.four(.join), expectedVersion: 1, from: second,
                                        on: nil, selfID: owner, at: t0)
        XCTAssertEqual(effects, [.resync(nil, to: second)])
    }

    // MARK: - Broadcasts

    func testOnlyTheOwnersBroadcastCounts() {
        let stage = broadcast(StageHost.act(video(), on: nil, by: owner, at: t0))!
        XCTAssertTrue(StageHost.accepts(stage, from: owner, on: nil, selfID: second))
        XCTAssertFalse(StageHost.accepts(stage, from: third, on: nil, selfID: second),
                       "a stage owned by someone else, sent by a third party")
        XCTAssertTrue(StageHost.accepts(nil, from: owner, on: stage, selfID: second))
        XCTAssertFalse(StageHost.accepts(nil, from: third, on: stage, selfID: second))
        XCTAssertFalse(StageHost.accepts(nil, from: owner, on: nil, selfID: second),
                       "nothing to clear")
    }

    /// Two claims from empty: everyone keeps the lower ID's stage.
    func testSimultaneousClaimsConvergeOnTheLowerID() {
        let ids = [UUID(), UUID()].sorted { $0.uuidString < $1.uuidString }
        let (low, high) = (ids[0], ids[1])
        let lowStage = broadcast(StageHost.act(video("low"), on: nil, by: low, at: t0))!
        let highStage = broadcast(StageHost.act(.four(.start), on: nil, by: high, at: t0))!

        XCTAssertTrue(StageHost.accepts(lowStage, from: low, on: highStage, selfID: high))
        XCTAssertFalse(StageHost.accepts(highStage, from: high, on: lowStage, selfID: low))
        // A bystander who heard `high` first switches; one who heard `low`
        // first stays put.
        XCTAssertTrue(StageHost.accepts(lowStage, from: low, on: highStage, selfID: third))
        XCTAssertFalse(StageHost.accepts(highStage, from: high, on: lowStage, selfID: third))
    }

    // MARK: - Requests and closing

    func testOnlyTheOwnerAnswersARequest() {
        let stage = broadcast(StageHost.act(video(), on: nil, by: owner, at: t0))!
        XCTAssertEqual(StageHost.receiveRequest(from: third, on: stage, selfID: owner),
                       [.resync(stage, to: third)])
        XCTAssertEqual(StageHost.receiveRequest(from: third, on: stage, selfID: second), [])
        XCTAssertEqual(StageHost.receiveRequest(from: third, on: nil, selfID: owner), [])
    }

    func testClosingGoesThroughTheOwnerAndIsAttributedToWhoeverClosed() {
        let stage = broadcast(StageHost.act(video(), on: nil, by: owner, at: t0))!
        XCTAssertEqual(StageHost.close(on: stage, by: second), [.forwardClose(to: owner)])
        XCTAssertEqual(StageHost.receiveClose(from: second, on: stage, selfID: owner),
                       [.broadcast(nil, actorID: second)])
        XCTAssertEqual(StageHost.close(on: stage, by: owner), [.broadcast(nil, actorID: owner)])
        XCTAssertEqual(StageHost.receiveClose(from: second, on: stage, selfID: third), [])
        XCTAssertEqual(StageHost.close(on: nil, by: owner), [])
    }

    /// The owner clears once and refuses the rest against an empty stage.
    func testExpiryClearsOnceAndUnattributed() {
        let empty = broadcast(StageHost.act(.four(.start), on: nil, by: owner, at: t0))!
        var stage = broadcast(StageHost.receive(.four(.join), expectedVersion: empty.version,
                                                from: second, on: empty, selfID: owner, at: t0))!
        for (column, player) in zip([0, 1, 0, 1, 0, 1, 0], [owner, second, owner, second, owner, second, owner]) {
            stage = broadcast(StageHost.receive(.four(.drop(column: column)), expectedVersion: stage.version,
                                                from: player, on: stage, selfID: owner, at: t0))!
        }
        XCTAssertNotNil(game(stage)?.outcome)
        XCTAssertEqual(StageHost.act(.four(.expire), on: stage, by: owner, at: t0),
                       [.broadcast(nil, actorID: nil)])
        XCTAssertEqual(StageHost.receive(.four(.expire), expectedVersion: stage.version, from: second,
                                         on: nil, selfID: owner, at: t0),
                       [.resync(nil, to: second)])
    }
}
