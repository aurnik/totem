import XCTest
@testable import TotemKit

final class FourReducerTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private let red = UUID()
    private let yellow = UUID()
    private let bystander = UUID()

    // MARK: - Helpers

    private func updated(_ outcome: StageReducer.Outcome,
                         _ message: String = "",
                         file: StaticString = #filePath, line: UInt = #line) -> Stage? {
        guard case .updated(let stage) = outcome else {
            XCTFail("expected .updated, got \(outcome). \(message)", file: file, line: line)
            return nil
        }
        return stage
    }

    private func game(_ stage: Stage) -> FourState {
        guard case .four(let state) = stage.state else { fatalError("not a four stage") }
        return state
    }

    private func started() -> Stage {
        updated(StageReducer.reduce(nil, .four(.start), by: red, expectedVersion: nil, at: t0))!
    }

    /// A board with both seats taken and nothing played.
    private func joined() -> Stage {
        let stage = started()
        return updated(StageReducer.reduce(stage, .four(.join), by: yellow,
                                           expectedVersion: stage.version, at: t0))!
    }

    /// Plays the columns in order, failing the test if any drop is refused.
    @discardableResult
    private func play(_ columns: [Int], from stage: Stage,
                      file: StaticString = #filePath, line: UInt = #line) -> Stage {
        var stage = stage
        for column in columns {
            let mover = game(stage).turn == .red ? red : yellow
            guard let next = updated(StageReducer.reduce(stage, .four(.drop(column: column)), by: mover,
                                                         expectedVersion: stage.version, at: t0),
                                     "dropping in column \(column)", file: file, line: line)
            else { return stage }
            stage = next
        }
        return stage
    }

    // MARK: - Claiming the stage

    func testStartClaimsTheStageWithTheSenderAsRed() {
        let stage = started()
        XCTAssertEqual(stage.version, 1)
        let state = game(stage)
        XCTAssertEqual(state.red, red)
        XCTAssertNil(state.yellow)
        XCTAssertNil(state.outcome)
        XCTAssertEqual(state.stacks.count, FourState.columns)
        XCTAssertTrue(state.stacks.allSatisfy(\.isEmpty))
        XCTAssertEqual(state.turn, .red, "red always moves first")
    }

    /// Starting is unconditional, so the reducer itself guards a live board.
    func testStartOnAGameInProgressIsRejected() {
        let stage = joined()
        XCTAssertEqual(StageReducer.reduce(stage, .four(.start), by: bystander,
                                           expectedVersion: nil, at: t0), .rejected)
    }

    func testStartOnAFinishedGameStartsAFreshOne() {
        let finished = play([0, 1, 0, 1, 0, 1, 0], from: joined())
        XCTAssertNotNil(game(finished).outcome)

        let restarted = updated(StageReducer.reduce(finished, .four(.start), by: yellow,
                                                    expectedVersion: nil, at: t0))!
        let state = game(restarted)
        XCTAssertEqual(state.red, yellow, "whoever starts the next game is red in it")
        XCTAssertNil(state.outcome)
        XCTAssertTrue(state.stacks.allSatisfy(\.isEmpty))
    }

    // MARK: - Joining

    func testJoinTakesTheSecondSeat() {
        let stage = joined()
        XCTAssertEqual(game(stage).yellow, yellow)
        XCTAssertEqual(stage.version, 2)
    }

    func testSecondJoinIsRejectedSoTheSeatCantBeStolen() {
        let stage = joined()
        XCTAssertEqual(StageReducer.reduce(stage, .four(.join), by: bystander,
                                           expectedVersion: stage.version, at: t0), .rejected)
    }

    func testRedCantJoinTheirOwnGame() {
        let stage = started()
        XCTAssertEqual(StageReducer.reduce(stage, .four(.join), by: red,
                                           expectedVersion: stage.version, at: t0), .rejected)
    }

    // MARK: - Dropping

    func testDropLandsOnTopOfTheColumnAndPassesTheTurn() {
        let stage = play([3], from: joined())
        let state = game(stage)
        XCTAssertEqual(state.stacks[3], [.red])
        XCTAssertEqual(state.turn, .yellow)

        let next = play([3], from: stage)
        XCTAssertEqual(game(next).stacks[3], [.red, .yellow], "the second piece stacks on the first")
        XCTAssertEqual(game(next).turn, .red)
    }

    /// The version check serializes actions but cannot tell whose turn it is.
    func testDropOutOfTurnIsRejected() {
        let stage = joined()
        XCTAssertEqual(StageReducer.reduce(stage, .four(.drop(column: 0)), by: yellow,
                                           expectedVersion: stage.version, at: t0), .rejected)
    }

    func testDropByABystanderIsRejected() {
        let stage = joined()
        XCTAssertEqual(StageReducer.reduce(stage, .four(.drop(column: 0)), by: bystander,
                                           expectedVersion: stage.version, at: t0), .rejected)
    }

    /// Red opens the board but has nobody to play against yet.
    func testDropBeforeAnyoneJoinsIsRejected() {
        let stage = started()
        XCTAssertEqual(StageReducer.reduce(stage, .four(.drop(column: 0)), by: red,
                                           expectedVersion: stage.version, at: t0), .rejected)
    }

    func testDropInAFullColumnIsRejected() {
        let stage = play([0, 0, 0, 0, 0, 0], from: joined())
        XCTAssertEqual(game(stage).stacks[0].count, FourState.rows)
        XCTAssertEqual(StageReducer.reduce(stage, .four(.drop(column: 0)), by: game(stage).turn == .red ? red : yellow,
                                           expectedVersion: stage.version, at: t0), .rejected)
    }

    func testDropOutsideTheBoardIsRejected() {
        let stage = joined()
        for column in [-1, FourState.columns] {
            XCTAssertEqual(StageReducer.reduce(stage, .four(.drop(column: column)), by: red,
                                               expectedVersion: stage.version, at: t0), .rejected,
                           "column \(column) is off the board")
        }
    }

    /// A drop aimed at a board the opponent has since moved on is refused.
    func testDropWithStaleVersionIsRejected() {
        let stage = joined()
        let moved = play([0], from: stage)
        XCTAssertEqual(StageReducer.reduce(moved, .four(.drop(column: 1)), by: yellow,
                                           expectedVersion: stage.version, at: t0), .rejected)
    }

    // MARK: - Winning

    func testVerticalWin() {
        // red 0, yellow 1, red 0, yellow 1, red 0, yellow 1, red 0.
        let stage = play([0, 1, 0, 1, 0, 1, 0], from: joined())
        guard case .won(let disc, let line)? = game(stage).outcome else {
            return XCTFail("expected a win, got \(String(describing: game(stage).outcome))")
        }
        XCTAssertEqual(disc, .red)
        XCTAssertEqual(line, (0..<4).map { FourSlot(column: 0, row: $0) })
        XCTAssertEqual(game(stage).finishedAt, t0)
    }

    func testHorizontalWin() {
        // red takes the bottom of 0-3, yellow answers on row 1 each time.
        let stage = play([0, 0, 1, 1, 2, 2, 3], from: joined())
        guard case .won(let disc, let line)? = game(stage).outcome else {
            return XCTFail("expected a win, got \(String(describing: game(stage).outcome))")
        }
        XCTAssertEqual(disc, .red)
        XCTAssertEqual(line, (0..<4).map { FourSlot(column: $0, row: 0) })
    }

    func testRisingDiagonalWin() {
        // A staircase: red ends up on (0,0) (1,1) (2,2) (3,3).
        let stage = play([0, 1, 1, 2, 2, 3, 2, 3, 3, 6, 3], from: joined())
        guard case .won(let disc, let line)? = game(stage).outcome else {
            return XCTFail("expected a win, got \(String(describing: game(stage).outcome))")
        }
        XCTAssertEqual(disc, .red)
        XCTAssertEqual(line, (0..<4).map { FourSlot(column: $0, row: $0) })
    }

    func testFallingDiagonalWin() {
        // The mirror image: red on (0,3) (1,2) (2,1) (3,0).
        let stage = play([3, 2, 2, 1, 1, 0, 1, 0, 0, 6, 0], from: joined())
        guard case .won(let disc, let line)? = game(stage).outcome else {
            return XCTFail("expected a win, got \(String(describing: game(stage).outcome))")
        }
        XCTAssertEqual(disc, .red)
        XCTAssertEqual(line, (0..<4).map { FourSlot(column: $0, row: 3 - $0) })
    }

    /// A run past four is one line, sorted so its ends are the array's ends.
    func testWinningLineCoversTheWholeRun() {
        var stacks = [[FourDisc]](repeating: [], count: FourState.columns)
        for column in [0, 1, 3, 4] { stacks[column] = [.red] }
        let state = FourState(stacks: stacks, red: red, yellow: yellow)
        let stage = Stage(version: 1, state: .four(state), ownerID: red)

        // Eight pieces are down, so it is red's turn, and column 2 joins the
        // two halves into a run of five.
        let won = updated(StageReducer.reduce(stage, .four(.drop(column: 2)), by: red,
                                              expectedVersion: 1, at: t0))!
        guard case .won(_, let line)? = game(won).outcome else {
            return XCTFail("expected a win")
        }
        XCTAssertEqual(line, (0..<5).map { FourSlot(column: $0, row: 0) })
    }

    func testNoInteractionsAfterAWin() {
        let stage = play([0, 1, 0, 1, 0, 1, 0], from: joined())
        XCTAssertEqual(StageReducer.reduce(stage, .four(.drop(column: 5)), by: yellow,
                                           expectedVersion: stage.version, at: t0), .rejected)
    }

    func testFullBoardWithNoLineIsADraw() {
        // Columns alternate RRYYRR / YYRRYY, so every row, column and diagonal
        // tops out at a run of two. Built directly, since no alternating move
        // order reaches this pattern.
        let even: [FourDisc] = [.red, .red, .yellow, .yellow, .red, .red]
        let odd: [FourDisc] = [.yellow, .yellow, .red, .red, .yellow, .yellow]
        var stacks = (0..<FourState.columns).map { $0.isMultiple(of: 2) ? even : odd }
        stacks[1].removeLast()

        let stage = Stage(version: 4, state: .four(FourState(stacks: stacks, red: red, yellow: yellow)), ownerID: red)
        XCTAssertEqual(game(stage).turn, .yellow, "the one cell left wants a yellow")

        let full = updated(StageReducer.reduce(stage, .four(.drop(column: 1)), by: yellow,
                                               expectedVersion: 4, at: t0))!
        XCTAssertTrue(game(full).isFull)
        XCTAssertEqual(game(full).outcome, .draw)
        XCTAssertEqual(game(full).finishedAt, t0)
    }

    // MARK: - Expiry

    func testExpireIsRefusedWhileTheGameIsLive() {
        let stage = joined()
        XCTAssertEqual(StageReducer.reduce(stage, .four(.expire), by: red,
                                           expectedVersion: stage.version, at: t0), .rejected)
    }

    func testExpireClearsAFinishedGame() {
        let stage = play([0, 1, 0, 1, 0, 1, 0], from: joined())
        XCTAssertEqual(StageReducer.reduce(stage, .four(.expire), by: bystander,
                                           expectedVersion: stage.version, at: t0), .cleared)
    }

    /// Every client runs the same countdown; only the first report clears.
    func testSecondExpireReportIsRefused() {
        let stage = play([0, 1, 0, 1, 0, 1, 0], from: joined())
        XCTAssertEqual(StageReducer.reduce(stage, .four(.expire), by: red,
                                           expectedVersion: stage.version, at: t0), .cleared)
        XCTAssertEqual(StageReducer.reduce(nil, .four(.expire), by: yellow,
                                           expectedVersion: stage.version, at: t0), .rejected)
    }

    // MARK: - Guarding the stage

    func testYouTubeCantTakeTheStageFromALiveGame() {
        let stage = joined()
        let takeover = StageAction.youtube(.setVideo(videoID: "abc", title: "T", thumbnailURL: nil))
        XCTAssertEqual(StageReducer.reduce(stage, takeover, by: bystander,
                                           expectedVersion: nil, at: t0), .rejected)
    }

    /// A finished board does not hold the stage for the rest of its countdown.
    func testYouTubeCanTakeTheStageFromAFinishedGame() {
        let finished = play([0, 1, 0, 1, 0, 1, 0], from: joined())
        let takeover = StageAction.youtube(.setVideo(videoID: "abc", title: "T", thumbnailURL: nil))
        let stage = updated(StageReducer.reduce(finished, takeover, by: bystander,
                                                expectedVersion: nil, at: t0))!
        XCTAssertEqual(stage.state.extensionID, .youtube)
    }

    func testAGameCantTakeTheStageFromAnotherLiveGame() {
        // Same extension, so `preservesState` does not apply and the reducer
        // has to refuse this itself.
        let stage = joined()
        XCTAssertEqual(StageReducer.reduce(stage, .four(.start), by: bystander,
                                           expectedVersion: nil, at: t0), .rejected)
    }

    func testAGameTakesTheStageFromAVideo() {
        let video = StageAction.youtube(.setVideo(videoID: "abc", title: "T", thumbnailURL: nil))
        let playing = updated(StageReducer.reduce(nil, video, by: red, expectedVersion: nil, at: t0))!
        let stage = updated(StageReducer.reduce(playing, .four(.start), by: red,
                                                expectedVersion: nil, at: t0))!
        XCTAssertEqual(stage.state.extensionID, .four)
        XCTAssertEqual(stage.version, 2)
    }

    // MARK: - Wire round-trips

    func testFourActionFrameRoundTrips() throws {
        let id = UUID()
        for action in [FourAction.start, .join, .drop(column: 4), .expire] {
            let frame = PeerFrame.stageAction(conversationID: id, action: .four(action),
                                              expectedVersion: 3)
            let data = try WireCoder.encoder().encode(frame)
            let decoded = try WireCoder.decoder().decode(PeerFrame.self, from: data)
            guard case let .stageAction(gotID, .four(gotAction), gotVersion) = decoded else {
                return XCTFail("wrong case: \(decoded)")
            }
            XCTAssertEqual(gotID, id)
            XCTAssertEqual(gotVersion, 3)
            if case .drop(let column) = action {
                guard case .drop(let gotColumn) = gotAction else {
                    return XCTFail("wrong action: \(gotAction)")
                }
                XCTAssertEqual(gotColumn, column)
            }
        }
    }

    func testFourStageFrameRoundTripsIncludingAFinishedBoard() throws {
        let id = UUID(), sender = UUID()
        let live = game(play([0, 1, 0], from: joined()))
        let finished = game(play([0, 1, 0, 1, 0, 1, 0], from: joined()))

        for state in [live, finished] {
            let frame = PeerFrame.stage(conversationID: id,
                                        stage: Stage(version: 9, state: .four(state), ownerID: red),
                                        actorID: sender)
            let data = try WireCoder.encoder().encode(frame)
            let decoded = try WireCoder.decoder().decode(PeerFrame.self, from: data)
            guard case let .stage(gotID, gotStage, gotSender) = decoded else {
                return XCTFail("wrong case: \(decoded)")
            }
            XCTAssertEqual(gotID, id)
            XCTAssertEqual(gotSender, sender)
            XCTAssertEqual(gotStage, Stage(version: 9, state: .four(state), ownerID: red))
        }
    }
}
