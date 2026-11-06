import Foundation
import Testing
@testable import WheelhouseKit

@Suite struct BackgroundTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    func item(_ kind: AttentionKind, cluster: String = "c1", name: String = "api", since: Date? = nil) -> AttentionItem {
        AttentionItem(id: "\(cluster)/\(kind)/\(name)", clusterID: cluster, severity: .critical, kind: kind, title: "T-\(kind.rawValue)", detail: "\(name) detail",
                      resource: kind == .unreachable ? nil : ResourceRef(clusterID: cluster, kind: .pod, namespace: "shop", name: name), since: since)
    }
    func health(_ items: [AttentionItem], cluster: String = "c1", reachable: Bool = true) -> ClusterHealth {
        ClusterHealth(clusterID: cluster, status: .critical, isReachable: reachable, items: items, counts: ClusterCounts(), updatedAt: now)
    }
    func plan(_ h: [ClusterHealth], settings: AlertSettings = AlertSettings(), state: AlertState = AlertState(), at time: Date? = nil) -> AlertPlan {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        return AlertPlanner.plan(health: h, clusterNames: ["c1": "prod", "c2": "stg"], settings: settings, state: state, now: time ?? now, calendar: cal)
    }

    @Test func newAlertPostsOnceThenDedupes() {
        let h = [health([item(.crashLoop)])]
        let first = plan(h)
        #expect(first.toPost.count == 1)
        #expect(first.toPost[0].level == .timeSensitive)
        #expect(first.toPost[0].url?.absoluteString == "wheelhouse://cluster/c1/ns/shop/pods/api")
        let second = plan(h, state: first.newState)
        #expect(second.toPost.isEmpty)
        #expect(second.newState.notified.count == 1)
    }

    @Test func recoveryClearsAndReNotifies() {
        let h = [health([item(.crashLoop)])]
        let first = plan(h)
        // A crash loop looks healthy between back-offs, so it only counts as recovered after a grace period.
        let later = now.addingTimeInterval(AlertPlanner.crashLoopRecoveryGrace + 60)
        let recovered = plan([health([])], state: first.newState, at: later)
        #expect(recovered.resolved == Set(first.newState.notified.keys))
        #expect(recovered.newState.notified.isEmpty)
        #expect(plan(h, state: recovered.newState, at: later).toPost.count == 1)
    }

    @Test func disabledRulesAndClustersAreIgnored() {
        var s = AlertSettings(); s.rules = [.jobFailed]
        #expect(plan([health([item(.crashLoop)])], settings: s).toPost.isEmpty)
        var s2 = AlertSettings(); s2.disabledClusters = ["c1"]
        #expect(plan([health([item(.crashLoop)])], settings: s2).toPost.isEmpty)
        var s3 = AlertSettings(); s3.enabled = false
        #expect(plan([health([item(.crashLoop)])], settings: s3).toPost.isEmpty)
    }

    @Test func nodeNotReadyNeedsFiveMinutes() {
        let young = item(.nodeNotReady, name: "n1", since: now.addingTimeInterval(-120))
        let old = item(.nodeNotReady, name: "n2", since: now.addingTimeInterval(-600))
        let p = plan([health([young, old])])
        #expect(p.toPost.map(\.fingerprint).count == 1)
        #expect(p.toPost[0].body.contains("n2"))
    }

    @Test func unreachableNeedsThreeConsecutiveFailures() {
        var s = AlertSettings(); s.rules = [.unreachable]
        let h = [health([item(.unreachable)], reachable: false)]
        var state = AlertState()
        for i in 1...2 {
            let p = plan(h, settings: s, state: state)
            #expect(p.toPost.isEmpty, "run \(i)")
            state = p.newState
        }
        let third = plan(h, settings: s, state: state)
        #expect(third.toPost.count == 1)
        #expect(third.toPost[0].level == .passive)
        // reachable again resets the streak
        #expect(plan([health([], reachable: true)], settings: s, state: third.newState).newState.unreachableStreak.isEmpty)
    }

    @Test func quietHoursDeferWithoutRecording() {
        var s = AlertSettings(); s.quietHoursEnabled = true
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        let at = { (h: Int) in cal.date(bySettingHour: h, minute: 0, second: 0, of: self.now)! }
        #expect(s.isQuiet(at: at(23), calendar: cal))
        #expect(s.isQuiet(at: at(3), calendar: cal))
        #expect(!s.isQuiet(at: at(12), calendar: cal))
        var wide = s; wide.quietStartMinutes = 0; wide.quietEndMinutes = 24 * 60
        #expect(wide.isQuiet(at: at(12), calendar: cal))
        // Force quiet via a window that always contains `now`.
        var c2 = Calendar(identifier: .gregorian); c2.timeZone = TimeZone(identifier: "UTC")!
        let mins = c2.component(.hour, from: now) * 60
        s.quietStartMinutes = mins; s.quietEndMinutes = mins + 60
        let p = AlertPlanner.plan(health: [health([item(.crashLoop)])], clusterNames: [:], settings: s, state: AlertState(), now: now, calendar: c2)
        #expect(p.toPost.isEmpty)
        #expect(p.newState.notified.isEmpty)   // will fire after quiet hours
    }

    @Test func summaryWhenMoreThanFive() {
        let items = (0..<7).map { item(.crashLoop, name: "p\($0)") }
        let p = plan([health(items)])
        #expect(p.isSummary)
        #expect(p.toPost.count == 1)
        #expect(p.toPost[0].title == "7 issues across 1 cluster")
        #expect(p.newState.notified.count == 7)
    }

    @Test func hideDetailsRedacts() {
        var s = AlertSettings(); s.hideDetails = true
        let c = plan([health([item(.crashLoop)])], settings: s).toPost[0]
        #expect(!c.body.contains("api"))
        #expect(!c.title.contains("T-"))
    }

    @Test func skippedClustersKeepState() {
        let first = plan([health([item(.crashLoop)])])
        let skipped = plan([health([], cluster: "c2")], state: first.newState)
        #expect(skipped.newState.notified == first.newState.notified)
        #expect(skipped.resolved.isEmpty)
    }
}
