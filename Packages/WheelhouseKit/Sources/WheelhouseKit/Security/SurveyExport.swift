import Foundation

public enum SurveyExportFormat: String, CaseIterable, Sendable, Identifiable {
    case csv, json, sarif, html
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .csv: "CSV"
        case .json: "JSON"
        case .sarif: "SARIF 2.1"
        case .html: "HTML report"
        }
    }
    public var fileExtension: String { self == .sarif ? "sarif" : rawValue }
}

public struct SurveyExportOptions: Sendable {
    /// Include findings that have an active accepted risk (marked as such). Off: they are left out.
    public var includeAcceptedRisks = true
    /// Replace the registry host of image references in evidence with `<registry>`.
    public var redactImageRegistries = false
    public init(includeAcceptedRisks: Bool = true, redactImageRegistries: Bool = false) {
        self.includeAcceptedRisks = includeAcceptedRisks
        self.redactImageRegistries = redactImageRegistries
    }
}

/// CSV, JSON, SARIF 2.1 and HTML exports of Survey findings (ARCHITECTURE-MAC §6.2). Pure functions over findings: no cluster access,
/// and findings never hold Secret data (only spec and rule excerpts), so an export never contains any.
public enum SurveyExporter {
    public static let toolName = "Wheelhouse Survey"
    public static let toolVersion = "1.0"
    public static let sarifSchema = "https://docs.oasis-open.org/sarif/sarif/v2.1.0/errata01/os/schemas/sarif-schema-2.1.0.json"

    struct Entry {
        var finding: SecurityFinding
        var status: FindingStatus
        var evidence: [String]
        var title: String
    }

    static func entries(_ findings: [SecurityFinding], book: AcceptedRiskBook, options: SurveyExportOptions, now: Date) -> [Entry] {
        findings.compactMap { f in
            let status = book.status(of: f, now: now)
            if status.isAccepted, !options.includeAcceptedRisks { return nil }
            let evidence = options.redactImageRegistries ? f.evidence.map(redactRegistry) : f.evidence
            return Entry(finding: f, status: status, evidence: evidence, title: options.redactImageRegistries ? redactRegistry(f.title) : f.title)
        }
    }

    public static func export(_ findings: [SecurityFinding], format: SurveyExportFormat, book: AcceptedRiskBook = AcceptedRiskBook(),
                              options: SurveyExportOptions = SurveyExportOptions(), clusterNames: [ClusterID: String] = [:], now: Date = Date()) -> Data {
        let list = entries(findings, book: book, options: options, now: now)
        let text: String
        switch format {
        case .csv: text = csv(list, clusterNames: clusterNames)
        case .json: text = json(list, clusterNames: clusterNames, now: now)
        case .sarif: text = sarif(list, clusterNames: clusterNames)
        case .html: text = html(list, clusterNames: clusterNames, now: now)
        }
        return Data(text.utf8)
    }

    /// `registry.example.com/team/app:1.2` becomes `<registry>/team/app:1.2`. A first path segment is a registry when it has a dot, a
    /// colon or is `localhost`.
    public static func redactRegistry(_ s: String) -> String {
        var result = s
        let pattern = #"(?<![\w./-])((?:[A-Za-z0-9-]+\.)+[A-Za-z0-9-]+(?::\d+)?|localhost(?::\d+)?)/(?=[\w.-]+(?:/|:|@|\s|$))"#
        if let regex = try? NSRegularExpression(pattern: pattern) {
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: "<registry>/")
        }
        return result
    }

    // MARK: CSV

    /// RFC 4180 quoting. A cell that starts with `=`, `+`, `-` or `@` gets a leading apostrophe so spreadsheets do not run it.
    static func csvCell(_ s: String) -> String {
        var v = s
        if let first = v.first, "=+-@\t\r".contains(first) { v = "'" + v }
        guard v.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return v }
        return "\"" + v.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    static func csv(_ list: [Entry], clusterNames: [ClusterID: String]) -> String {
        var lines = ["rule,severity,cluster,namespace,kind,name,title,status,accepted_until,reason,evidence"]
        let iso = ISO8601DateFormatter()
        for e in list {
            let f = e.finding
            var status = "open", until = "", reason = ""
            if case .accepted(let u, let r) = e.status { status = "accepted"; until = iso.string(from: u); reason = r }
            let cells = [f.ruleID, f.severity.rawValue, clusterNames[f.clusterID] ?? f.clusterID, f.namespace ?? "", f.object.kind, f.object.name,
                         e.title, status, until, reason, e.evidence.joined(separator: " | ")]
            lines.append(cells.map(csvCell).joined(separator: ","))
        }
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    // MARK: JSON

    static func json(_ list: [Entry], clusterNames: [ClusterID: String], now: Date) -> String {
        let iso = ISO8601DateFormatter()
        let findings: [JSONValue] = list.map { e in
            let f = e.finding
            var o: [String: JSONValue] = [
                "id": .string(f.id), "rule": .string(f.ruleID), "severity": .string(f.severity.rawValue), "title": .string(e.title),
                "cluster": .string(clusterNames[f.clusterID] ?? f.clusterID), "clusterID": .string(f.clusterID),
                "object": ["kind": .string(f.object.kind), "name": .string(f.object.name)],
                "location": .string(f.logicalLocation), "evidence": .array(e.evidence.map(JSONValue.string)),
                "status": .string(e.status.isAccepted ? "accepted" : "open"),
            ]
            if let ns = f.namespace { o["namespace"] = .string(ns) }
            if let ns = f.object.namespace { o["object"]?["namespace"] = .string(ns) }
            if !f.containers.isEmpty { o["containers"] = .array(f.containers.map(JSONValue.string)) }
            if case .accepted(let until, let reason) = e.status {
                o["acceptedRisk"] = ["until": .string(iso.string(from: until)), "reason": .string(reason)]
            }
            return .object(o)
        }
        let doc: JSONValue = ["tool": ["name": .string(toolName), "version": .string(toolVersion)], "generatedAt": .string(iso.string(from: now)),
                              "findingCount": .int(findings.count), "findings": .array(findings)]
        return doc.jsonString(pretty: true) + "\n"
    }

    // MARK: SARIF 2.1.0

    static func sarif(_ list: [Entry], clusterNames: [ClusterID: String]) -> String {
        let rules = RuleCatalogue.all
        let ruleIndex = Dictionary(uniqueKeysWithValues: rules.enumerated().map { ($1.id, $0) })
        let driverRules: [JSONValue] = rules.map { r in
            [
                "id": .string(r.id),
                "name": .string(r.title.split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined().filter { $0.isLetter || $0.isNumber }),
                "shortDescription": ["text": .string(r.title)],
                "fullDescription": ["text": .string(r.summary)],
                "help": ["text": .string(r.whyItMatters + "\n\nFix:\n" + r.fix.map { "- \($0)" }.joined(separator: "\n"))],
                "helpUri": .string(r.docsURL),
                "defaultConfiguration": ["level": .string(r.severity.sarifLevel)],
                "properties": ["tags": ["security", "kubernetes", .string(r.category.rawValue)], "security-severity": .string(r.severity.securitySeverity)],
            ]
        }
        let results: [JSONValue] = list.map { e in
            let f = e.finding
            let location = f.logicalLocation.replacingOccurrences(of: f.clusterID, with: clusterNames[f.clusterID] ?? f.clusterID)
            var logical: [String: JSONValue] = ["name": .string(f.object.name), "fullyQualifiedName": .string(location), "kind": "resource"]
            logical["decoratedName"] = .string(f.object.kind)
            var result: [String: JSONValue] = [
                "ruleId": .string(f.ruleID),
                "level": .string(f.severity.sarifLevel),
                "message": ["text": .string(e.title + (e.evidence.isEmpty ? "" : ". " + e.evidence.joined(separator: "; ")))],
                "locations": [["logicalLocations": [.object(logical)]]],
                "partialFingerprints": ["wheelhouseFindingId/v1": .string(f.id)],
                "properties": ["security-severity": .string(f.severity.securitySeverity), "severity": .string(f.severity.rawValue),
                               "cluster": .string(clusterNames[f.clusterID] ?? f.clusterID)],
            ]
            if let i = ruleIndex[f.ruleID] { result["ruleIndex"] = .int(i) }
            if case .accepted(_, let reason) = e.status {
                result["suppressions"] = [["kind": "external", "status": "accepted", "justification": .string(reason)]]
            }
            return .object(result)
        }
        let doc: JSONValue = [
            "$schema": .string(sarifSchema), "version": "2.1.0",
            "runs": [["tool": ["driver": ["name": .string(toolName), "version": .string(toolVersion), "semanticVersion": .string(toolVersion + ".0"),
                                          "rules": .array(driverRules)]],
                      "results": .array(results)]],
        ]
        return doc.jsonString(pretty: true) + "\n"
    }

    // MARK: HTML

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "'", with: "&#39;")
    }

    static func html(_ list: [Entry], clusterNames: [ClusterID: String], now: Date) -> String {
        let counts = list.filter { !$0.status.isAccepted }.reduce(into: [Severity: Int]()) { $0[$1.finding.severity, default: 0] += 1 }
        let stamp = now.formatted(date: .abbreviated, time: .shortened)
        var h = """
        <!doctype html>
        <html lang="en"><head><meta charset="utf-8"><title>Survey report</title>
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
        :root { color-scheme: light dark; --fg:#1d1d1f; --muted:#6e6e73; --bg:#fff; --line:#d2d2d7; }
        @media (prefers-color-scheme: dark) { :root { --fg:#f5f5f7; --muted:#a1a1a6; --bg:#1c1c1e; --line:#3a3a3c; } }
        body { font: 14px/1.45 -apple-system, system-ui, sans-serif; color: var(--fg); background: var(--bg); margin: 2rem auto; max-width: 960px; padding: 0 1rem; }
        h1 { font-size: 1.5rem; margin-bottom: .2rem; } .muted { color: var(--muted); }
        .bar { display: flex; gap: .5rem; margin: 1rem 0; flex-wrap: wrap; }
        .chip { border: 1px solid var(--line); border-radius: 6px; padding: .25rem .6rem; }
        table { border-collapse: collapse; width: 100%; } th, td { text-align: left; vertical-align: top; padding: .45rem .5rem; border-bottom: 1px solid var(--line); }
        .sev { font-weight: 600; } .critical { color: #cc1f2b; } .high { color: #c2410c; } .medium { color: #a85600; } .low { color: #0060c7; }
        code { font: 12px ui-monospace, Menlo, monospace; word-break: break-word; } li { margin: 0 0 .15rem; } ul { margin: 0; padding-left: 1.1rem; }
        @media print { body { margin: 0; max-width: none; } tr { break-inside: avoid; } }
        </style></head><body>
        <h1>Survey report</h1>
        <div class="muted">Generated \(escape(stamp)) by \(escape(toolName)). Built-in access and workload rules; no Secret data is included.</div>
        <div class="bar">
        """
        for s in Severity.allCases where s != .unknown {
            h += "<span class=\"chip\"><span class=\"sev \(s.rawValue)\">\(s.title)</span> \(counts[s] ?? 0)</span>"
        }
        h += "</div>\n<table><thead><tr><th>Rule</th><th>Severity</th><th>Object</th><th>Finding</th><th>Status</th></tr></thead><tbody>\n"
        for e in list {
            let f = e.finding
            let rule = RuleCatalogue.rule(f.ruleID)
            var status = "Open"
            if case .accepted(let until, let reason) = e.status { status = "Accepted until \(until.formatted(date: .abbreviated, time: .omitted)): \(reason)" }
            h += "<tr><td><strong>\(escape(f.ruleID))</strong></td>"
            h += "<td class=\"sev \(f.severity.rawValue)\">\(f.severity.title)</td>"
            h += "<td><code>\(escape(f.logicalLocation.replacingOccurrences(of: f.clusterID, with: clusterNames[f.clusterID] ?? f.clusterID)))</code></td>"
            h += "<td>\(escape(e.title))"
            if let rule { h += "<div class=\"muted\">\(escape(rule.title))</div>" }
            if !e.evidence.isEmpty { h += "<ul>" + e.evidence.map { "<li><code>\(escape($0))</code></li>" }.joined() + "</ul>" }
            h += "</td><td>\(escape(status))</td></tr>\n"
        }
        h += "</tbody></table>\n"
        if list.isEmpty { h += "<p class=\"muted\">No findings.</p>\n" }
        h += "</body></html>\n"
        return h
    }
}
