#if os(macOS)
import Foundation
import Testing
import WheelhouseKit
@testable import WheelhouseDesktop

@Suite("ActivityLogTests")
struct ActivityLogTests {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "wh-activity-\(UUID().uuidString)/activity.sqlite")
    }

    @Test func creatingTheLogOpensNothing() {
        let url = tempURL()
        let log = ActivityLog(url: url)
        #expect(!log.isOpen)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        log.record(ActivityEntry(verb: "scale", result: "ok"))
        log.flush()
        #expect(log.isOpen)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test func recordsRoundTripWithEveryField() async {
        let log = ActivityLog(url: tempURL())
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        log.record(ActivityEntry(time: t, cluster: "kc-1", origin: .terminal(session: "s1", reportedCommand: "kubectl delete pod x"), verb: "delete", object: "pod/x", result: "refused",
                                 commandLine: "kubectl delete pod x"))
        log.record(ActivityEntry(time: t.addingTimeInterval(1), cluster: "kc-2", origin: .beacon(client: "claude"), verb: "get", object: nil, result: "ok"))
        let rows = await log.records()
        #expect(rows.count == 2)
        #expect(rows[0].entry.cluster == "kc-2")                          // newest first
        #expect(rows[0].entry.origin == .beacon(client: "claude"))
        #expect(rows[1].entry.origin == .terminal(session: "s1", reportedCommand: "kubectl delete pod x"))
        #expect(rows[1].entry.commandLine == "kubectl delete pod x")
        #expect(rows[1].entry.time == t)
        #expect(await log.count() == 2)
    }

    @Test func filtersByClusterTextAndTime() async {
        let log = ActivityLog(url: tempURL())
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        log.record(ActivityEntry(time: t, cluster: "a", verb: "scale", object: "deployment/api", result: "ok"))
        log.record(ActivityEntry(time: t.addingTimeInterval(100), cluster: "b", verb: "delete", object: "pod/100%_x", result: "ok"))
        log.record(ActivityEntry(time: t.addingTimeInterval(200), cluster: "b", origin: .tides, verb: "sync", object: "app/shop", result: "failed: timeout"))
        #expect(await log.records(ActivityQuery(cluster: "b")).count == 2)
        #expect(await log.records(ActivityQuery(text: "deployment")).count == 1)
        #expect(await log.records(ActivityQuery(text: "tides")).count == 1)          // origin label
        #expect(await log.records(ActivityQuery(text: "100%_")).count == 1)          // wildcards are literal
        #expect(await log.records(ActivityQuery(text: "%")).count == 1)
        #expect(await log.records(ActivityQuery(cluster: "b", since: t.addingTimeInterval(150))).count == 1)
        #expect(await log.records(ActivityQuery(limit: 1)).count == 1)
        #expect(await log.records(ActivityQuery(cluster: "b", since: t.addingTimeInterval(150), limit: 5)).first?.entry.verb == "sync")
    }

    @Test func rowsOlderThanTheRetentionAreRemovedWhenTheDatabaseOpens() async {
        let url = tempURL()
        let day: TimeInterval = 86_400
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let first = ActivityLog(url: url, now: { now })
        first.record(ActivityEntry(time: now.addingTimeInterval(-91 * day), verb: "old", result: "ok"))
        first.record(ActivityEntry(time: now.addingTimeInterval(-89 * day), verb: "recent", result: "ok"))
        first.flush()
        #expect(await first.count() == 2)       // pruning happened at open, before these were written
        let second = ActivityLog(url: url, now: { now })
        let rows = await second.records()
        #expect(rows.map(\.entry.verb) == ["recent"])
    }

    @Test func concurrentRecordsAreAllKept() async {
        let log = ActivityLog(url: tempURL())
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<200 { group.addTask { log.record(ActivityEntry(verb: "v\(i)", result: "ok")) } }
        }
        #expect(await log.count() == 200)
    }

    @Test func clearEmptiesTheLog() async {
        let log = ActivityLog(url: tempURL())
        log.record(ActivityEntry(verb: "x", result: "ok"))
        log.clear()
        #expect(await log.count() == 0)
    }

    @Test func csvQuotesAndNeutralisesFormulas() {
        let t = Date(timeIntervalSince1970: 0)
        let rows = [ActivityRecord(id: 1, entry: ActivityEntry(time: t, cluster: "a,b", origin: .ui, verb: "=cmd()", object: "say \"hi\"\nthere", result: "+1", commandLine: "@x"))]
        let csv = ActivityLog.csv(rows)
        let lines = csv.split(separator: "\n", omittingEmptySubsequences: false)
        #expect(lines[0].hasPrefix("time,cluster,origin,verb,object,result,"))
        #expect(csv.contains("\"a,b\""))
        #expect(csv.contains("'=cmd()"))
        #expect(csv.contains("\"say \"\"hi\"\"\nthere\""))
        #expect(csv.contains("'+1"))
        #expect(csv.contains("'@x"))
    }

    @Test func jsonExportListsTheRows() throws {
        let rows = [ActivityRecord(id: 1, entry: ActivityEntry(cluster: "a", origin: .firstMate(conversation: "c1"), verb: "patch", object: "deployment/x", result: "ok"))]
        let data = try ActivityLog.json(rows)
        let decoded = try JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        #expect(decoded?.count == 1)
        #expect(decoded?.first?["origin"] as? String == "First Mate c1")
        #expect(decoded?.first?["verb"] as? String == "patch")
    }

    @Test func longFieldsAreTruncated() async {
        let log = ActivityLog(url: tempURL())
        log.record(ActivityEntry(verb: "x", result: String(repeating: "a", count: 10_000)))
        #expect(await log.records().first?.entry.result.count == ActivityLog.maxFieldLength)
    }
}
#endif
