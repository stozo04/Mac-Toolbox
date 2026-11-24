import XCTest
@testable import Toolbox

final class ImplementationStatusTests: XCTestCase {
    private func tool(_ name: String) throws -> Tool {
        try XCTUnwrap(ToolCatalog.all.first { $0.name == name }, "\(name) is not in the catalog")
    }

    func testPlaceholderToolsAreNotImplemented() throws {
        for name in ["Record Audio", "Convert Audio", "Merge Videos"] {
            XCTAssertFalse(try tool(name).isImplemented, "\(name) should show the not-implemented banner")
        }
    }

    func testToolsWithADedicatedWorkspaceAreImplemented() throws {
        for name in ["Convert Images", "Annotate Screenshot", "Download Video", "Trim Video", "Keep Awake", "Media Info", "Folio",
                     "Scarlet", "Rotate Images", "Color Picker", "Compress Video", "Extract Frames", "Extract Audio"] {
            XCTAssertTrue(try tool(name).isImplemented, "\(name) has its own workspace")
        }
    }

    func testFlagFollowsTheInputCase() {
        XCTAssertFalse(ToolInput.live(symbol: "mic", idle: "", action: "").isImplemented)
        XCTAssertFalse(ToolInput.dropFiles(title: "", hint: "", symbol: "").isImplemented)
        XCTAssertTrue(ToolInput.convertImages.isImplemented)
        XCTAssertTrue(ToolInput.link.isImplemented)
    }
}
