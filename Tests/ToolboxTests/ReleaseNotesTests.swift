import XCTest
@testable import Toolbox

final class ReleaseNotesTests: XCTestCase {
    func testCurrentVersionIsTheNewestRelease() {
        XCTAssertEqual(ReleaseNotes.all.first?.version, AppVersion.current,
                       "Add a Release for \(AppVersion.current) at the top of ReleaseNotes.all")
    }

    func testVersionsAreSemVerAndStrictlyDescending() {
        let versions = ReleaseNotes.all.map(\.version)
        for v in versions { XCTAssertNotNil(SemVer.parse(v), "\(v) is not MAJOR.MINOR.PATCH") }
        for (newer, older) in zip(versions, versions.dropFirst()) {
            XCTAssertTrue(SemVer.isGreater(newer, than: older), "\(newer) must be higher than \(older)")
        }
    }

    func testEveryReleaseHasADateAndChanges() {
        for r in ReleaseNotes.all {
            XCTAssertFalse(r.changes.isEmpty, "\(r.version) has no changes")
            XCTAssertNotEqual(ReleaseNotesView.displayDate(r.date), r.date, "\(r.version) date \(r.date) is not yyyy-MM-dd")
        }
    }

    func testSemVerComparison() {
        XCTAssertTrue(SemVer.isGreater("0.10.0", than: "0.9.9"))
        XCTAssertTrue(SemVer.isGreater("1.0.0", than: "0.99.99"))
        XCTAssertFalse(SemVer.isGreater("0.2.0", than: "0.2.0"))
        XCTAssertFalse(SemVer.isGreater("0.1.9", than: "0.2.0"))
        XCTAssertNil(SemVer.parse("1.2"))
        XCTAssertNil(SemVer.parse("1.2.x"))
    }
}
