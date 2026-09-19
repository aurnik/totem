import XCTest
@testable import TotemKit

final class DoodleTests: XCTestCase {
    /// An avatar encoded without the key still decodes.
    func testAvatarWithoutDoodleDecodes() throws {
        let json = #"{"skinTone":0.5,"hair":0.2,"glasses":true,"cigarette":false}"#
        let avatar = try JSONDecoder().decode(Avatar.self, from: Data(json.utf8))
        XCTAssertNil(avatar.doodle)
        XCTAssertTrue(avatar.glasses)
    }

    /// No doodle means no key on the wire.
    func testNilDoodleIsOmitted() throws {
        let data = try JSONEncoder().encode(Avatar())
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("doodle"))
    }

    func testRoundTrip() throws {
        let doodle = Doodle(strokes: [
            .init(color: 3, points: [0, 0, 255, 255]),
            .init(color: 0, points: [10, 20]),
        ])
        let avatar = Avatar(doodle: doodle)
        let decoded = try JSONDecoder().decode(Avatar.self, from: JSONEncoder().encode(avatar))
        XCTAssertEqual(decoded, avatar)
        XCTAssertEqual(decoded.doodle?.pointCount, 3)
    }

    func testValidation() {
        XCTAssertTrue(Doodle().isValid)
        XCTAssertTrue(Doodle(strokes: [.init(color: 7, points: [0, 255])]).isValid)
        XCTAssertFalse(Doodle(strokes: [.init(color: 8, points: [0, 0])]).isValid)
        XCTAssertFalse(Doodle(strokes: [.init(color: -1, points: [0, 0])]).isValid)
        XCTAssertFalse(Doodle(strokes: [.init(color: 0, points: [0, 256])]).isValid)
        XCTAssertFalse(Doodle(strokes: [.init(color: 0, points: [0, 0, 1])]).isValid)
        XCTAssertFalse(Doodle(strokes: [.init(color: 0, points: [])]).isValid)

        let tooMany = Doodle(strokes: Array(repeating: .init(color: 0, points: [1, 1]),
                                            count: Doodle.maxStrokes + 1))
        XCTAssertFalse(tooMany.isValid)

        let longest = Doodle(strokes: [.init(color: 0, points: Array(repeating: 1, count: Doodle.maxPoints * 2))])
        XCTAssertTrue(longest.isValid)
        let overLong = Doodle(strokes: [.init(color: 0, points: Array(repeating: 1, count: Doodle.maxPoints * 2 + 2))])
        XCTAssertFalse(overLong.isValid)
    }

    /// A maximal doodle fits the server's default request body limit.
    func testMaximalDoodleFitsRequestBody() throws {
        var strokes: [Doodle.Stroke] = []
        let perStroke = Doodle.maxPoints / Doodle.maxStrokes
        for i in 0..<Doodle.maxStrokes {
            strokes.append(.init(color: i % Doodle.paletteSize,
                                 points: Array(repeating: 255, count: perStroke * 2)))
        }
        let avatar = Avatar(doodle: Doodle(strokes: strokes))
        XCTAssertTrue(avatar.doodle!.isValid)
        XCTAssertLessThan(try JSONEncoder().encode(avatar).count, 1 << 14)
    }
}
