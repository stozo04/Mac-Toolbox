import XCTest
@testable import Toolbox

final class CompanionAppTests: XCTestCase {
    private let folioURL = URL(filePath: "/Applications/Folio.app")

    private func companions(installed: [String: URL], launched: Locked<[URL]>) -> CompanionApps {
        CompanionApps(locate: { installed[$0] }, launch: { url in launched.update { $0.append(url) } })
    }

    private func tool(_ name: String) throws -> Tool {
        try XCTUnwrap(ToolCatalog.all.first { $0.name == name }, "\(name) is not in the catalog")
    }

    func testOpeningAnInstalledCompanionLaunchesItAndStaysOnThePage() throws {
        let launched = Locked<[URL]>([])
        let state = AppState(arguments: [], companionApps: companions(installed: ["app.folio.reader": folioURL], launched: launched))
        state.page = .category(.docs)

        state.open(try tool("Folio"))

        XCTAssertEqual(launched.value, [folioURL])
        XCTAssertEqual(state.page, .category(.docs))
        XCTAssertEqual(state.recents.first, "Docs/Folio")
    }

    func testOpeningAMissingCompanionShowsItsPage() throws {
        let launched = Locked<[URL]>([])
        let state = AppState(arguments: [], companionApps: companions(installed: [:], launched: launched))
        let scarlet = try tool("Scarlet")

        state.open(scarlet)

        XCTAssertTrue(launched.value.isEmpty)
        XCTAssertEqual(state.page, .tool(scarlet))
    }

    func testEachCompanionIsFoundByItsBundleIdentifier() {
        let launched = Locked<[URL]>([])
        let scarletURL = URL(filePath: "/Applications/Scarlet.app")
        let apps = companions(installed: ["com.forwardfuture.scarlet": scarletURL], launched: launched)

        XCTAssertEqual(apps.installedURL(of: .scarlet), scarletURL)
        XCTAssertNil(apps.installedURL(of: .folio))
        XCTAssertFalse(apps.open(.folio))
        XCTAssertTrue(apps.open(.scarlet))
        XCTAssertEqual(launched.value, [scarletURL])
    }

    func testDocsIsOnlyFolio() {
        XCTAssertEqual(ToolCatalog.tools(in: .docs).map(\.name), ["Folio"])
    }

    func testVideoKeepsEveryToolAndAddsScarlet() {
        let expected: Set = ["Scarlet", "Download Video", "Burn In Subtitles", "Change Speed", "Extract Frames", "Convert Video", "Record Screen",
                             "Compress Video", "Resize Video", "Crop & Rotate Video", "Media Info", "Trim Video", "Merge Videos", "Mute Video",
                             "Video to GIF"]
        XCTAssertEqual(Set(ToolCatalog.tools(in: .video).map(\.name)), expected)
    }

    func testDownloadPagesAreTheAppsGitHubReleases() {
        for app in CompanionApp.allCases {
            XCTAssertEqual(app.downloadPage.host(), "github.com")
            XCTAssertTrue(app.downloadPage.path().hasSuffix("/releases/latest"), app.name)
        }
    }
}
