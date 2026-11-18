import XCTest
@testable import Toolbox

final class BatchFilesTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("batch-files-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    func testOutputFolderIsMadeWithADatedName() throws {
        let folder = try BatchFiles.makeOutputFolder(named: "Toolbox Things", in: dir)

        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory) && isDirectory.boolValue)
        XCTAssertEqual(folder.deletingLastPathComponent().standardizedFileURL, dir.standardizedFileURL)
        XCTAssertNotNil(folder.lastPathComponent.range(of: #"^Toolbox Things \d{4}-\d{2}-\d{2} \d{2}\.\d{2}\.\d{2}$"#, options: .regularExpression))
    }

    func testOutputFolderThatCannotBeMadeIsAnErrorNotAFolder() throws {
        let notAFolder = dir.appendingPathComponent("Reports")
        try Data("a file where the folder should go".utf8).write(to: notAFolder)

        XCTAssertThrowsError(try BatchFiles.makeOutputFolder(named: "Toolbox Things", in: notAFolder)) { error in
            XCTAssertTrue(error is OutputFolderError)
            XCTAssertTrue(error.localizedDescription.hasPrefix("Couldn't create the output folder in “Reports”."), error.localizedDescription)
            let details = Log.details(error)
            XCTAssertEqual(details["error_description"], error.localizedDescription)
            XCTAssertTrue(details["underlying"]?.hasPrefix("NSCocoaErrorDomain ") ?? false, "the reason macOS gave is not in the log: \(details)")
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), ["Reports"])
    }

    func testOutputFolderWithANameTooLongForTheDiskIsAnError() {
        XCTAssertThrowsError(try BatchFiles.makeOutputFolder(named: String(repeating: "x", count: 300), in: dir))
    }

    func testClearingDropsOnlyAFolderFailureNotice() {
        let failure = OutputFolderError(parentName: "Downloads", underlying: CocoaError(.fileWriteNoPermission)).localizedDescription
        XCTAssertNil(OutputFolderError.clearing(failure))
        XCTAssertEqual(OutputFolderError.clearing("2 item(s) had no videos and were skipped."), "2 item(s) had no videos and were skipped.")
        XCTAssertNil(OutputFolderError.clearing(nil))
    }
}
