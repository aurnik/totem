import XCTest
@testable import TotemKit

final class StageReducerTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func video(_ id: String = "abc") -> StageAction {
        .youtube(.setVideo(videoID: id, title: "Video \(id)", thumbnailURL: nil))
    }

    private func youtube(_ stage: Stage) -> YouTubeState {
        guard case .youtube(let state) = stage.state else { fatalError("not a youtube stage") }
        return state
    }

    private func updated(_ outcome: StageReducer.Outcome, _ message: String = "") -> Stage? {
        guard case .updated(let stage) = outcome else {
            XCTFail("expected .updated, got \(outcome). \(message)")
            return nil
        }
        return stage
    }

    // MARK: - Claiming the stage

    func testSetVideoOnEmptyStageStartsPlayingFromZero() {
        guard let stage = updated(StageReducer.reduce(nil, video(), expectedVersion: nil, at: t0)) else { return }
        XCTAssertEqual(stage.version, 1)
        let state = youtube(stage)
        XCTAssertEqual(state.videoID, "abc")
        XCTAssertTrue(state.isPlaying)
        XCTAssertEqual(state.positionSeconds, 0)
        XCTAssertEqual(state.positionAt, t0)
    }

    /// The product call: picking a video always takes over, so a stale pick
    /// can't be silently dropped.
    func testSetVideoReplacesWhatWasPlayingRegardlessOfVersion() {
        let first = updated(StageReducer.reduce(nil, video("one"), expectedVersion: nil, at: t0))!
        let second = updated(StageReducer.reduce(first, video("two"), expectedVersion: nil, at: t0))!
        XCTAssertEqual(youtube(second).videoID, "two")
        XCTAssertEqual(second.version, 2)
    }

    // MARK: - Absolute play/pause

    func testPauseRecordsPositionAndStamp() {
        let started = updated(StageReducer.reduce(nil, video(), expectedVersion: nil, at: t0))!
        let at = t0.addingTimeInterval(47)
        let paused = updated(StageReducer.reduce(started, .youtube(.setPlaying(false, positionSeconds: 47)),
                                                 expectedVersion: started.version, at: at))!
        let state = youtube(paused)
        XCTAssertFalse(state.isPlaying)
        XCTAssertEqual(state.positionSeconds, 47)
        XCTAssertEqual(state.positionAt, at)
        XCTAssertEqual(paused.version, 2)
    }

    func testResumeKeepsStoredPosition() {
        let started = updated(StageReducer.reduce(nil, video(), expectedVersion: nil, at: t0))!
        let paused = updated(StageReducer.reduce(started, .youtube(.setPlaying(false, positionSeconds: 47)),
                                                 expectedVersion: started.version, at: t0))!
        let resumed = updated(StageReducer.reduce(paused, .youtube(.setPlaying(true, positionSeconds: 47)),
                                                  expectedVersion: paused.version, at: t0))!
        XCTAssertTrue(youtube(resumed).isPlaying)
        XCTAssertEqual(youtube(resumed).positionSeconds, 47)
    }

    /// Every client with the chat open reports the video ending. The first
    /// wins; re-reporting an already-paused stage must not rebroadcast, or
    /// everyone re-seeks on each duplicate.
    func testSetPlayingToCurrentValueIsUnchangedAndNotBroadcast() {
        let started = updated(StageReducer.reduce(nil, video(), expectedVersion: nil, at: t0))!
        let outcome = StageReducer.reduce(started, .youtube(.setPlaying(true, positionSeconds: 12)),
                                          expectedVersion: started.version, at: t0)
        XCTAssertEqual(outcome, .unchanged)
    }

    // MARK: - Compare-and-swap

    func testStaleVersionIsRejectedSoPauseCantLandOnANewVideo() {
        let first = updated(StageReducer.reduce(nil, video("one"), expectedVersion: nil, at: t0))!
        let second = updated(StageReducer.reduce(first, video("two"), expectedVersion: nil, at: t0))!
        // Someone hits pause still looking at "one".
        let outcome = StageReducer.reduce(second, .youtube(.setPlaying(false, positionSeconds: 30)),
                                          expectedVersion: first.version, at: t0)
        XCTAssertEqual(outcome, .rejected)
    }

    func testConditionalActionWithoutAVersionIsRejected() {
        let started = updated(StageReducer.reduce(nil, video(), expectedVersion: nil, at: t0))!
        let outcome = StageReducer.reduce(started, .youtube(.setPlaying(false, positionSeconds: 1)),
                                          expectedVersion: nil, at: t0)
        XCTAssertEqual(outcome, .rejected)
    }

    func testConditionalActionOnEmptyStageIsRejected() {
        let outcome = StageReducer.reduce(nil, .youtube(.setPlaying(true, positionSeconds: 0)),
                                          expectedVersion: 1, at: t0)
        XCTAssertEqual(outcome, .rejected)
    }

    // MARK: - Position math

    func testPositionAdvancesWhilePlayingAndHoldsWhilePaused() {
        let live = YouTubeState(videoID: "a", title: "t", isPlaying: true,
                                positionSeconds: 10, positionAt: t0)
        XCTAssertEqual(live.position(at: t0.addingTimeInterval(5)), 15, accuracy: 0.001)

        var held = live
        held.isPlaying = false
        XCTAssertEqual(held.position(at: t0.addingTimeInterval(5)), 10, accuracy: 0.001)
    }

    /// Clocks can disagree; a snapshot must never rewind past where it started.
    func testPositionNeverGoesBackwardsForAnEarlierClock() {
        let live = YouTubeState(videoID: "a", title: "t", isPlaying: true,
                                positionSeconds: 10, positionAt: t0)
        XCTAssertEqual(live.position(at: t0.addingTimeInterval(-30)), 10, accuracy: 0.001)
    }

    // MARK: - Wire round-trips

    func testStageActionFrameRoundTripsWithOptionalVersion() throws {
        let id = UUID()
        for expected in [nil, 7] as [Int?] {
            let frame = ClientFrame.stageAction(conversationID: id, action: video("xyz"),
                                                expectedVersion: expected)
            let data = try WireCoder.encoder().encode(frame)
            let decoded = try WireCoder.decoder().decode(ClientFrame.self, from: data)
            guard case let .stageAction(gotID, gotAction, gotVersion) = decoded else {
                return XCTFail("wrong case: \(decoded)")
            }
            XCTAssertEqual(gotID, id)
            XCTAssertEqual(gotVersion, expected)
            guard case .youtube(.setVideo(let videoID, _, _)) = gotAction else {
                return XCTFail("wrong action: \(gotAction)")
            }
            XCTAssertEqual(videoID, "xyz")
        }
    }

    func testStageFrameRoundTripsIncludingEmptyStage() throws {
        let id = UUID(), sender = UUID()
        let stage = Stage(version: 3, state: .youtube(
            YouTubeState(videoID: "v", title: "Title", thumbnailURL: URL(string: "https://img.example/1.jpg"),
                         isPlaying: true, positionSeconds: 12.5, positionAt: t0)))

        for payload in [stage, nil] as [Stage?] {
            let frame = ServerFrame.stage(conversationID: id, senderID: sender, stage: payload)
            let data = try WireCoder.encoder().encode(frame)
            let decoded = try WireCoder.decoder().decode(ServerFrame.self, from: data)
            guard case let .stage(gotID, gotSender, gotStage) = decoded else {
                return XCTFail("wrong case: \(decoded)")
            }
            XCTAssertEqual(gotID, id)
            XCTAssertEqual(gotSender, sender)
            XCTAssertEqual(gotStage, payload)
        }
    }
}
