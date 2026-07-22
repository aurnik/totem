import XCTest
@testable import TotemKit

final class ReconnectPolicyTests: XCTestCase {

    func testDoublesFromOneSecondToThirtyCap() {
        var p = ReconnectPolicy()
        let delays = (0..<7).map { _ in p.nextDelay() }
        XCTAssertEqual(delays, [1, 2, 4, 8, 16, 30, 30])
    }

    func testResetRestartsAtOneSecond() {
        var p = ReconnectPolicy()
        _ = p.nextDelay()
        _ = p.nextDelay()
        p.reset()
        XCTAssertEqual(p.nextDelay(), 1)
    }
}
