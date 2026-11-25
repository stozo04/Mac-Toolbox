import XCTest
@testable import Toolbox

@MainActor
final class VaultComparisonTests: XCTestCase {
    private func item(_ name: String) -> VaultItem {
        VaultItem(url: URL(fileURLWithPath: "/compare/\(name)"), kind: .image, added: .distantPast, bytes: 4)
    }

    private func group(vault: [String], incoming: [String], match: VaultDuplicates.Match = .exact) -> VaultComparison.Group {
        VaultComparison.Group(copies: vault.map { .init(item: item($0), place: .vault) } + incoming.map { .init(item: item($0), place: .incoming) },
                              match: match)
    }

    private func comparison() -> VaultComparison {
        VaultComparison(origin: .adding) { $0.url }
    }

    func testNothingIsTickedAndNothingCanBeConfirmedUntilACopyIsTicked() async throws {
        let review = comparison()
        let shown = group(vault: ["a.png"], incoming: ["b.png"])
        let choice = Task { await review.choose(shown, number: 1, of: 1) }
        try await waitUntil("the set is shown") { review.group != nil }

        XCTAssertTrue(review.ticked.isEmpty)
        XCTAssertFalse(review.canConfirm)
        review.confirm()
        review.toggleFocused()
        XCTAssertTrue(review.canConfirm)
        review.confirm()

        let decision = await choice.value
        XCTAssertEqual(decision, .keep([item("a.png").id]))
        review.end()
    }

    func testTheExactChoiceIsRepeatedForLaterExactSetsOnlyWhenAsked() async throws {
        let review = comparison()
        let first = group(vault: ["a.png"], incoming: ["a copy.png"])
        let choice = Task { await review.choose(first, number: 1, of: 3) }
        try await waitUntil("the set is shown") { review.group != nil }
        review.toggle(item("a.png").id)
        XCTAssertNil(review.whyNoRepeat)
        review.repeatsExactChoice = true
        review.confirm()
        _ = await choice.value

        let later = await review.choose(group(vault: ["b.png"], incoming: ["b copy.png"]), number: 2, of: 3)
        XCTAssertEqual(later, .keep([item("b.png").id]), "the vault copy was not kept without asking")

        let likely = Task { await review.choose(group(vault: ["c.png"], incoming: ["c 2.png"], match: .likely), number: 3, of: 3) }
        try await waitUntil("a likely set is still shown") { review.group?.match == .likely }
        review.cancel()
        let stopped = await likely.value
        XCTAssertEqual(stopped, .stop)
        review.end()
    }

    func testAChoiceThatIsNotOneSideCannotBeRepeated() async throws {
        let review = comparison()
        let shown = group(vault: ["a.png", "b.png"], incoming: ["c.png"])
        let choice = Task { await review.choose(shown, number: 1, of: 2) }
        try await waitUntil("the set is shown") { review.group != nil }

        review.toggle(item("a.png").id)
        review.toggle(item("c.png").id)

        XCTAssertNotNil(review.whyNoRepeat)
        review.cancel()
        _ = await choice.value
        review.end()
    }

    func testAReviewWhoseTaskIsCancelledStopsWithoutAnAnswer() async throws {
        let review = comparison()
        let choice = Task { await review.choose(group(vault: ["a.png"], incoming: ["b.png"]), number: 1, of: 1) }
        try await waitUntil("the set is shown") { review.group != nil }

        choice.cancel()

        let stopped = await choice.value
        XCTAssertEqual(stopped, .stop)
        review.end()
    }

    func testKeepAllTicksEveryCopy() async throws {
        let review = comparison()
        let shown = group(vault: ["a.png", "b.png"], incoming: ["c.png"])
        let choice = Task { await review.choose(shown, number: 1, of: 1) }
        try await waitUntil("the set is shown") { review.group != nil }

        review.keepAll()
        review.confirm()

        let kept = await choice.value
        XCTAssertEqual(kept, .keep(Set(shown.copies.map(\.id))))
        review.end()
    }
}
