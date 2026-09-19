import XCTest
@testable import TotemKit

final class ConversationIDTests: XCTestCase {
    let a = UUID(uuidString: "0919FA5F-5C1B-49D7-888D-F4AB37000ED6")!
    let b = UUID(uuidString: "ABC5AD32-21AA-4B62-A42C-ED5EA545BDE4")!
    let c = UUID(uuidString: "3FF771BA-8C83-4060-8CA6-711EFD5B2BB3")!

    /// Golden values: if these move, every existing conversation re-keys.
    func testGoldenValues() {
        XCTAssertEqual(ConversationID.derive([a, b]),
                       UUID(uuidString: "A97C1A62-6535-5BD0-9AE3-48C692F5647B"))
        XCTAssertEqual(ConversationID.derive([a, b, c]),
                       UUID(uuidString: "5993B242-7538-5319-BA66-DEBF4A0A13F4"))
    }

    func testOrderInsensitive() {
        XCTAssertEqual(ConversationID.derive([a, b]), ConversationID.derive([b, a]))
        XCTAssertEqual(ConversationID.derive([a, b, c]), ConversationID.derive([c, b, a]))
    }

    func testDuplicateInsensitive() {
        XCTAssertEqual(ConversationID.derive([a, b, b]), ConversationID.derive([a, b]))
    }

    func testPairIsNotItsSuperset() {
        XCTAssertNotEqual(ConversationID.derive([a, b]), ConversationID.derive([a, b, c]))
    }

    func testDistinctSetsDiffer() {
        XCTAssertNotEqual(ConversationID.derive([a, b]), ConversationID.derive([a, c]))
        XCTAssertNotEqual(ConversationID.derive([a, b]), ConversationID.derive([b, c]))
    }

    /// The version nibble distinguishes a derived ID from the v4s used elsewhere.
    func testVersionAndVariantBits() {
        let derived = ConversationID.derive([a, b]).uuid
        XCTAssertEqual(derived.6 >> 4, 5)
        XCTAssertEqual(derived.8 >> 6, 0b10)
    }
}
