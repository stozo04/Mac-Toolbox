import XCTest

final class ReproCrashDemoATests: XCTestCase {
    func testT1CountAssertionDoesNotProtectTheSubscript() {
        let tracks: [Int] = []
        XCTAssertEqual(tracks.count, 1)
        XCTAssertEqual(tracks[0], 7)
    }
}

final class ReproCrashDemoBTests: XCTestCase {
    func testT1ThisResultIsLostWhenTheEarlierTestTraps() {
        XCTAssertTrue(true)
    }
}
