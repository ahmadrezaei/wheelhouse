import Testing
import Foundation
@testable import WheelhouseMac

@Suite("KubeTable diff")
struct KubeTableDiffTests {
    private func keys(_ ids: [String], version: String = "1") -> [KubeRowKey] { ids.map { KubeRowKey(id: $0, version: version) } }

    @Test func identicalRowsAreAnEmptyDelta() {
        let a = keys(["a", "b", "c"])
        #expect(KubeTableDiffer.diff(old: a, new: a).isEmpty)
    }

    @Test func appendsRemovalsAndUpdatesAreIncremental() {
        let old = keys((0..<20).map { "p\($0)" })
        var new = old
        new.remove(at: 3)                                  // removed
        new[10].version = "2"                              // updated (its index in the NEW array)
        new.append(KubeRowKey(id: "p-new", version: "1"))  // inserted at the end
        let d = KubeTableDiffer.diff(old: old, new: new)
        #expect(!d.needsReload)
        #expect(d.removed == IndexSet(integer: 3))
        #expect(d.inserted == IndexSet(integer: 19))
        #expect(d.updated == IndexSet(integer: 10))
    }

    @Test func insertionsInTheMiddleKeepOrder() {
        let old = keys(["a", "c", "e", "g", "i", "k", "m", "o", "q", "s", "u", "w"])
        var new = old
        new.insert(KubeRowKey(id: "d", version: "1"), at: 2)
        let d = KubeTableDiffer.diff(old: old, new: new)
        #expect(d == KubeTableDelta(removed: [], inserted: [2], updated: [], needsReload: false))
    }

    @Test func aReorderIsAFullReload() {
        let old = keys((0..<30).map { "p\($0)" })
        let new = Array(old.reversed())
        #expect(KubeTableDiffer.diff(old: old, new: new).needsReload)
    }

    @Test func touchingMoreThanHalfTheRowsIsAFullReload() {
        let old = keys((0..<40).map { "p\($0)" })
        let new = keys((0..<40).map { "p\($0)" }, version: "2")
        #expect(KubeTableDiffer.diff(old: old, new: new).needsReload)
    }

    @Test func smallTablesAreNotReloadedForOneChange() {
        let old = keys(["a", "b", "c"])
        let new = keys(["a", "c"])
        let d = KubeTableDiffer.diff(old: old, new: new)
        #expect(!d.needsReload && d.removed == [1])
    }

    @Test func firstLoadAndEmptyingReload() {
        #expect(KubeTableDiffer.diff(old: [], new: keys(["a"])).needsReload)
        #expect(KubeTableDiffer.diff(old: keys(["a"]), new: []).needsReload)
        #expect(KubeTableDiffer.diff(old: [], new: []).isEmpty)
    }

    @Test func duplicateIDsFallBackToAReload() {
        #expect(KubeTableDiffer.diff(old: keys(["a", "b"]), new: keys(["a", "a"])).needsReload)
    }

    @Test func diffingTenThousandRowsIsCheap() {
        let old = keys((0..<10_000).map { "p\($0)" })
        var new = old
        new.removeFirst(5)
        for i in 0..<20 { new[100 + i].version = "2" }
        new.append(contentsOf: keys((0..<5).map { "n\($0)" }))
        let start = ContinuousClock.now
        let d = KubeTableDiffer.diff(old: old, new: new)
        let elapsed = ContinuousClock.now - start
        #expect(!d.needsReload && d.removed.count == 5 && d.inserted.count == 5 && d.updated.count == 20)
        #expect(elapsed < .milliseconds(100), "diff took \(elapsed)")
    }

    @Test func columnsFollowTheKind() {
        let pods = KubeColumn.columns(for: .pod, showNamespace: true, extra: [])
        #expect(pods.map(\.id) == ["name", "namespace", "ready", "status", "restarts", "cpu", "memory", "node", "age"])
        let nodes = KubeColumn.columns(for: .node, showNamespace: true, extra: [])
        #expect(!nodes.contains { $0.id == "namespace" })                           // cluster-scoped kinds have no namespace column
        let crd = KubeColumn.columns(for: .configMap, showNamespace: false, extra: ["Ready", "Synced"])
        #expect(crd.map(\.id) == ["name", "status", "details", "extra0", "extra1", "age"])
    }
}
