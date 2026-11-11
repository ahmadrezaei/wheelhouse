import Foundation
import WheelhouseDesktop
import WheelhouseKit
import WheelhouseUI

/// Turns what Gangway holds into the ConfirmSheet request (ARCHITECTURE-MAC section 3.6, step 5). The API request (method, path, object) is
/// the authoritative fact; the command line is shown as "reported by your shell", a hint.
enum GangwaySheetBuilder {
    /// At most this many requests are listed one by one.
    static let listLimit = 12

    /// What the person types: the object's name when every request is about the same one, otherwise the cluster's name.
    static func confirmationText(for sheet: GangwaySheet, clusterName: String) -> String {
        let names = Set(sheet.holds.map(objectName(of:)))
        if names.count == 1, let only = names.first, let name = only { return name }
        return clusterName
    }

    private static func objectName(of hold: GangwayHold) -> String? {
        guard let segments = try? RequestClassifier.canonicalSegments(of: hold.path) else { return nil }
        let shape = RequestClassifier.shape(of: segments)
        return shape.isResourcePath ? shape.name : nil
    }

    static func describe(_ hold: GangwayHold) -> String {
        let target = hold.query.map { "\(hold.path)?\($0)" } ?? hold.path
        return "\(hold.method) \(target)"
    }

    static func title(for sheet: GangwaySheet, cluster: String) -> String {
        switch sheet.kind {
        case .command: "Allow this command on \(cluster)?"
        case .requests: sheet.holds.count == 1 ? "Allow this change on \(cluster)?" : "Allow \(sheet.holds.count) changes on \(cluster)?"
        case .stream: "Allow this connection to \(cluster)?"
        }
    }

    static func message(for sheet: GangwaySheet) -> String {
        switch sheet.kind {
        case .command(let line):
            return "A terminal command wants to change this cluster. Approving lets it run until it finishes (at most 10 minutes). Command reported by your shell: \(line)"
        case .requests:
            return "A program in a terminal wants to make the changes listed below. Approving covers exactly these requests and nothing that arrives later."
        case .stream:
            return "A program in a terminal wants to open a live connection (exec, attach or port-forward). Approving covers this one connection only."
        }
    }

    static func verb(for sheet: GangwaySheet) -> String {
        switch sheet.kind {
        case .command: "Allow Command"
        case .requests: "Allow Changes"
        case .stream: "Allow Connection"
        }
    }

    static func facts(for sheet: GangwaySheet) -> [ConfirmRequest.Fact] {
        var facts: [ConfirmRequest.Fact] = []
        if case .command(let line) = sheet.kind { facts.append(.init("Command (reported by your shell)", line)) }
        else if let line = sheet.holds.compactMap(\.reportedCommand).first { facts.append(.init("Reported by your shell", line)) }
        for hold in sheet.holds.prefix(listLimit) {
            facts.append(.init(hold.isStream ? "Connection" : "Request", describe(hold)))
            if !hold.execCommand.isEmpty { facts.append(.init("Runs", hold.execCommand.joined(separator: " "))) }
        }
        if sheet.holds.count > listLimit { facts.append(.init("Request", "and \(sheet.holds.count - listLimit) more")) }
        return facts
    }

    /// `approve` runs when the person confirms. Cancel needs no callback: the sheet's disappearance answers "no".
    @MainActor
    static func request(for sheet: GangwaySheet, cluster: ClusterConfig, paneName: String, approve: @escaping @MainActor @Sendable () -> Void) -> ConfirmRequest {
        let first = sheet.holds[0]
        let typed = sheet.requiresTyping
        var facts = facts(for: sheet)
        facts.insert(.init("Terminal", paneName), at: 0)
        return ConfirmRequest(
            title: title(for: sheet, cluster: cluster.name),
            message: message(for: sheet),
            verb: verb(for: sheet),
            isDestructive: false,
            cluster: cluster,
            namespace: nil,
            resource: first.isStream ? describe(first) : (sheet.holds.count == 1 ? describe(first) : "\(sheet.holds.count) requests"),
            confirmationText: confirmationText(for: sheet, clusterName: cluster.name),
            facts: facts,
            alwaysRequireTyping: typed,
            typeToConfirmOnProduction: typed,
            origin: first.origin.changeOrigin,
            action: { approve() })
    }
}
