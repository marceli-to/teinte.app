import Foundation
import Testing
@testable import TeinteCore

@Suite("Reconcile")
struct ReconcileTests {
    let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    func known(_ path: String, _ size: Int64, _ dt: TimeInterval = 0, id: UUID = UUID()) -> Reconcile.Known {
        .init(id: id, relativePath: path, size: size, modified: t0.addingTimeInterval(dt))
    }

    func disk(_ path: String, _ size: Int64, _ dt: TimeInterval = 0) -> Reconcile.OnDisk {
        .init(relativePath: path, size: size, modified: t0.addingTimeInterval(dt), created: t0)
    }

    @Test func unchangedIsEmpty() {
        let plan = Reconcile.plan(known: [known("a.jpg", 10), known("b/c.jpg", 20)],
                                  onDisk: [disk("a.jpg", 10), disk("b/c.jpg", 20, 0.5)])
        #expect(plan.isEmpty)
    }

    @Test func addedChangedRemoved() {
        let a = known("a.jpg", 10), b = known("b.jpg", 20)
        let plan = Reconcile.plan(known: [a, b], onDisk: [disk("a.jpg", 11, 5), disk("new.jpg", 30)])
        #expect(plan.changed.map(\.id) == [a.id])
        #expect(plan.added.map(\.relativePath) == ["new.jpg"])
        #expect(plan.removed == [b.id])
        #expect(plan.renamed.isEmpty)
    }

    @Test func renameKeepsTheRecord() {
        let a = known("shoot/a.jpg", 10, 3)
        let plan = Reconcile.plan(known: [a], onDisk: [disk("archive/a-final.jpg", 10, 3)])
        #expect(plan.renamed.map(\.id) == [a.id])
        #expect(plan.renamed.first?.file.relativePath == "archive/a-final.jpg")
        #expect(plan.added.isEmpty && plan.removed.isEmpty)
    }

    @Test func renameNeedsSameSizeAndDate() {
        let a = known("a.jpg", 10), b = known("b.jpg", 20)
        let plan = Reconcile.plan(known: [a, b], onDisk: [disk("x.jpg", 10, 60), disk("y.jpg", 21)])
        #expect(plan.renamed.isEmpty)
        #expect(plan.added.count == 2)
        #expect(Set(plan.removed) == [a.id, b.id])
    }

    @Test func eachRecordIsMatchedOnce() {
        // Two identical copies vanish, three appear: two renames and one new file.
        let a = known("a.jpg", 10), b = known("b.jpg", 10)
        let plan = Reconcile.plan(known: [a, b], onDisk: [disk("x.jpg", 10), disk("y.jpg", 10), disk("z.jpg", 10)])
        #expect(Set(plan.renamed.map(\.id)) == [a.id, b.id])
        #expect(plan.added.map(\.relativePath) == ["z.jpg"])
        #expect(plan.removed.isEmpty)
    }

    @Test func aFileStillInPlaceIsNotARenameSource() {
        // A copy of a.jpg appears; a.jpg is still there, so the copy is new.
        let a = known("a.jpg", 10)
        let plan = Reconcile.plan(known: [a], onDisk: [disk("a.jpg", 10), disk("a copy.jpg", 10)])
        #expect(plan.added.map(\.relativePath) == ["a copy.jpg"])
        #expect(plan.renamed.isEmpty && plan.removed.isEmpty)
    }
}
