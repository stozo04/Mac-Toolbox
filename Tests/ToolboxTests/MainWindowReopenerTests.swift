import XCTest
@testable import Toolbox

final class MainWindowReopenerTests: XCTestCase {
    func testNoWindowsMeansNoMainWindow() {
        XCTAssertFalse(WindowPresence.hasMainWindow([]))
    }

    func testHelperWindowsThatCannotBecomeMainDoNotCount() {
        let helpers = [
            WindowPresence(canBecomeMain: false, isVisible: true, isMinimized: false),
            WindowPresence(canBecomeMain: false, isVisible: false, isMinimized: false),
        ]
        XCTAssertFalse(WindowPresence.hasMainWindow(helpers))
    }

    func testClosedMainWindowDoesNotCount() {
        XCTAssertFalse(WindowPresence.hasMainWindow([WindowPresence(canBecomeMain: true, isVisible: false, isMinimized: false)]))
    }

    func testVisibleMainWindowCounts() {
        XCTAssertTrue(WindowPresence.hasMainWindow([WindowPresence(canBecomeMain: true, isVisible: true, isMinimized: false)]))
    }

    func testMinimizedMainWindowCounts() {
        XCTAssertTrue(WindowPresence.hasMainWindow([WindowPresence(canBecomeMain: false, isVisible: false, isMinimized: true)]))
    }
}
