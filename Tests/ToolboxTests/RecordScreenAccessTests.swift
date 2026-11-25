import XCTest
@testable import Toolbox

@MainActor
final class RecordScreenAccessTests: XCTestCase {
    private final class Requests { var count = 0 }

    private struct Refused: LocalizedError {
        var errorDescription: String? { "The user declined TCCs for application, window, display capture" }
    }

    private func access(preflight: Bool, requests: Requests = Requests(),
                        load: @escaping @MainActor () async throws -> CaptureSources.Listing) -> ScreenCaptureAccess {
        ScreenCaptureAccess(preflight: { preflight }, request: { requests.count += 1 }, loadSources: load)
    }

    func testARefusalIsLoggedWithTheErrorAndWhatPreflightSaid() async throws {
        let sink = MemorySink(minimumLevel: .warning)
        Log.configure(sinks: [sink])
        defer { Log.configure(sinks: []) }
        let model = RecordScreenModel(screenAccess: access(preflight: true) { throw Refused() })

        await model.refresh()

        XCTAssertEqual(model.access, .denied)
        let event = try XCTUnwrap(sink.events.first)
        XCTAssertEqual(event.level, .warning)
        XCTAssertEqual(event.category, "record")
        XCTAssertEqual(event.metadata["preflight_allowed"], "true")
        XCTAssertEqual(event.metadata["error_description"], "The user declined TCCs for application, window, display capture")
    }

    func testAllowedAccessLogsNothing() async {
        let sink = MemorySink(minimumLevel: .warning)
        Log.configure(sinks: [sink])
        defer { Log.configure(sinks: []) }
        let model = RecordScreenModel(screenAccess: access(preflight: true) { CaptureSources.Listing(displays: [], windows: []) })

        await model.refresh()

        XCTAssertEqual(model.access, .allowed)
        XCTAssertTrue(sink.events.isEmpty)
    }

    func testAsksMacOSOnlyOnTheFirstLookWithoutPermission() async {
        let requests = Requests()
        let model = RecordScreenModel(screenAccess: access(preflight: false, requests: requests) { throw Refused() })

        await model.refresh()
        await model.refresh()

        XCTAssertEqual(requests.count, 1)
    }
}
