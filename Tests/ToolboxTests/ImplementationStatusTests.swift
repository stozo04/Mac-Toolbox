import XCTest
@testable import Toolbox

final class ImplementationStatusTests: XCTestCase {
    private func tool(_ name: String) throws -> Tool {
        try XCTUnwrap(ToolCatalog.all.first { $0.name == name }, "\(name) is not in the catalog")
    }

    func testPlaceholderToolsAreNotImplemented() throws {
        for name in ["Transcribe", "Summarize", "Translate", "Capture Text", "Merge PDFs", "Record Audio"] {
            XCTAssertFalse(try tool(name).isImplemented, "\(name) should show the not-implemented banner")
        }
    }

    func testToolsWithADedicatedWorkspaceAreImplemented() throws {
        for name in ["Convert Images", "Annotate Screenshot", "Download Video", "Trim Video", "Keep Awake", "Media Info", "Scan Document", "Redact PDF", "Rotate Images", "Color Picker", "Compress Video"] {
            XCTAssertTrue(try tool(name).isImplemented, "\(name) has its own workspace")
        }
    }

    func testEveryTextAndSpeechToolIsNotImplemented() {
        let tools = ToolCatalog.tools(in: .textAndSpeech)
        XCTAssertFalse(tools.isEmpty)
        XCTAssertTrue(tools.allSatisfy { !$0.isImplemented })
    }

    func testFlagFollowsTheInputCase() {
        XCTAssertFalse(ToolInput.text.isImplemented)
        XCTAssertFalse(ToolInput.live(symbol: "mic", idle: "", action: "").isImplemented)
        XCTAssertFalse(ToolInput.dropFiles(title: "", hint: "", symbol: "").isImplemented)
        XCTAssertTrue(ToolInput.convertImages.isImplemented)
        XCTAssertTrue(ToolInput.link.isImplemented)
    }
}
