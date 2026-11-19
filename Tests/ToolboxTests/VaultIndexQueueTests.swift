import XCTest
@testable import Toolbox

final class VaultIndexQueueTests: XCTestCase {
    private func item(_ name: String) -> VaultItem {
        VaultItem(url: URL(fileURLWithPath: "/vault/\(name)"), kind: .video, added: Date(timeIntervalSince1970: 0), bytes: 1)
    }

    private func drain(_ queue: inout VaultIndexQueue, pending: [VaultItem], in items: [VaultItem]) -> (order: [String], gone: [String]) {
        var pending = pending
        var order: [String] = []
        var gone: [String] = []
        while let next = queue.next(from: &pending, in: items, gone: { gone.append($0) }) { order.append(next.name) }
        return (order, gone)
    }

    func testAnItemAskedForGoesBeforeWhatWasPendingAndIsIndexedOnce() {
        let all = [item("a.mov"), item("b.mov"), item("c.mov")]
        var queue = VaultIndexQueue()
        queue.putFirst(item("c.mov").id)

        let result = drain(&queue, pending: all, in: all)

        XCTAssertEqual(result.order, ["c.mov", "a.mov", "b.mov"])
        XCTAssertEqual(result.gone, [])
    }

    func testAnItemThatArrivedAfterThePassListedWhatWasPendingIsStillTaken() {
        let late = item("late.mov")
        var queue = VaultIndexQueue()
        queue.putFirst(late.id)

        let result = drain(&queue, pending: [item("a.mov")], in: [item("a.mov"), late])

        XCTAssertEqual(result.order, ["late.mov", "a.mov"])
    }

    func testAnItemNoLongerInTheVaultIsReportedGoneAndSkipped() {
        var queue = VaultIndexQueue()
        queue.putFirst(item("deleted.mov").id)

        let result = drain(&queue, pending: [item("a.mov")], in: [item("a.mov")])

        XCTAssertEqual(result.order, ["a.mov"])
        XCTAssertEqual(result.gone, [item("deleted.mov").id])
    }

    func testTheLatestItemAskedForGoesFirstAndAskingTwiceListsItOnce() {
        let all = [item("a.mov"), item("b.mov")]
        var queue = VaultIndexQueue()
        queue.putFirst(item("a.mov").id)
        queue.putFirst(item("b.mov").id)
        queue.putFirst(item("a.mov").id)

        let result = drain(&queue, pending: [], in: all)

        XCTAssertEqual(result.order, ["a.mov", "b.mov"])
    }

    func testARenamedItemKeepsItsPlace() {
        let renamed = item("new.mov")
        var queue = VaultIndexQueue()
        queue.putFirst(item("old.mov").id)
        queue.carry(from: item("old.mov").id, to: renamed.id)

        let result = drain(&queue, pending: [item("a.mov"), renamed], in: [item("a.mov"), renamed])

        XCTAssertEqual(result.order, ["new.mov", "a.mov"])
        XCTAssertEqual(result.gone, [])
    }

    func testRemovedAndClearedItemsAreNotTakenFirst() {
        let all = [item("a.mov"), item("b.mov"), item("c.mov")]
        var queue = VaultIndexQueue()
        queue.putFirst(item("c.mov").id)
        queue.putFirst(item("b.mov").id)
        queue.remove(item("b.mov").id)

        XCTAssertEqual(drain(&queue, pending: all, in: all).order, ["c.mov", "a.mov", "b.mov"])

        queue.putFirst(item("c.mov").id)
        queue.clear()

        XCTAssertEqual(drain(&queue, pending: all, in: all).order, ["a.mov", "b.mov", "c.mov"])
    }
}
