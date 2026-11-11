import Foundation
import Observation
import WheelhouseDesktop
import WheelhouseKit
import WheelhouseUI

enum HelmFlowKind: String, Sendable {
    case install, upgrade, rollback, uninstall

    var title: String {
        switch self {
        case .install: "Install"
        case .upgrade: "Upgrade"
        case .rollback: "Roll Back"
        case .uninstall: "Uninstall"
        }
    }
}

/// What the review step shows: the object changes, the hooks that will run, the warnings, and the exact object set the run is granted.
struct HelmReviewData {
    var plan: HelmGrantPlan
    var comparison: HelmComparison?
    /// The objects an install creates (an install has nothing to compare with).
    var created: [HelmManifestObject]
    /// The rendered objects, for the server dry run.
    var rendered: [HelmManifestObject]
    var removed: [HelmManifestObject]
    var notes: String?
    var helmVersion: String
}

/// One install, upgrade, rollback or uninstall (ARCHITECTURE-MAC section 5.2): configure, render and review, confirm, run.
///
/// Nothing here changes the cluster before the confirmation sheet's action runs, and that sheet only exists after a person pressed
/// Review and then the button. The run starts from that action alone: there is no other path to `HelmRunner.apply`.
@MainActor @Observable
final class HelmFlowModel: Identifiable {
    enum Step: Equatable { case configure, working(String), review, running, finished(success: Bool) }

    nonisolated let id = UUID()
    let kind: HelmFlowKind
    let session: ClusterSession
    let services: ChartRoomServices
    /// Builds the helm adapter and its runner. Injected so tests never start Gangway.
    let makeRunner: @MainActor () async throws -> HelmRunner

    var releaseName: String
    var namespace: String
    var chart: String
    var chartVersion: String
    var valuesText: String
    var createNamespace = false
    var wait = true
    var rollbackOnFailure: Bool
    var skipCRDs = false
    var keepHistory = false
    var resetThenReuse = false
    var targetRevision: Int?

    private(set) var step: Step = .configure
    private(set) var error: String?
    private(set) var review: HelmReviewData?
    private(set) var output = ""
    private(set) var hints: ValuesSchemaHints?
    private(set) var current: HelmRelease?
    var confirm: ConfirmRequest?

    @ObservationIgnored private var history: [HelmRevisionSummary] = []
    @ObservationIgnored private var runTask: Task<Void, Never>?
    @ObservationIgnored private var renderedRelease: HelmRelease?
    @ObservationIgnored private var helm: HelmRunner?

    init(kind: HelmFlowKind, session: ClusterSession, services: ChartRoomServices, releaseName: String = "", namespace: String = "default", chart: String = "",
         chartVersion: String = "", valuesText: String = "", current: HelmRelease? = nil, history: [HelmRevisionSummary] = [],
         makeRunner: @escaping @MainActor () async throws -> HelmRunner) {
        self.kind = kind
        self.session = session
        self.services = services
        self.releaseName = releaseName
        self.namespace = namespace
        self.chart = chart
        self.chartVersion = chartVersion
        self.valuesText = valuesText
        self.current = current
        self.history = history
        self.makeRunner = makeRunner
        self.rollbackOnFailure = session.config.isProduction                  // on by default for Production
        if kind == .rollback { targetRevision = history.first { $0.revision != current?.version }?.revision }
        if let current { hints = Self.hints(for: current) }
    }

    var clusterConfig: ClusterConfig { session.config }
    var revisions: [HelmRevisionSummary] { history.filter { $0.revision != current?.version } }

    /// Values hints for a release's own chart: its `values.schema.json` when it has one, else types inferred from its default values.
    static func hints(for release: HelmRelease) -> ValuesSchemaHints {
        ValuesSchemaHints(schemaData: release.chart.schema, defaults: YAMLCodec.dump(release.chart.values))
    }

    func setHints(_ hints: ValuesSchemaHints?) { self.hints = hints }

    // MARK: Validation

    /// Why Review is not available yet, or nil.
    var blocker: String? {
        guard HelmInputCheck.isValidReleaseName(releaseName) || kind != .install else { return "A release name uses lowercase letters, digits, - and . (at most 53 characters)." }
        if namespace.isEmpty { return "Choose a namespace." }
        switch kind {
        case .install, .upgrade:
            if chart.isEmpty { return "Choose a chart." }
            if chart.hasPrefix("-") { return "That chart reference is not valid." }
            if let hints, hints.diagnostics(for: valuesText).contains(where: { $0.severity == .error }) { return "The values have errors." }
        case .rollback:
            if targetRevision == nil { return "Choose a revision." }
        case .uninstall:
            break
        }
        return nil
    }

    var operation: HelmOperation {
        switch kind {
        case .install: .install(release: releaseName, chart: chart, version: chartVersion.isEmpty ? nil : chartVersion, namespace: namespace, createNamespace: createNamespace)
        case .upgrade: .upgrade(release: releaseName, chart: chart, version: chartVersion.isEmpty ? nil : chartVersion, namespace: namespace,
                                strategy: resetThenReuse ? .resetThenReuse : .reset)
        case .rollback: .rollback(release: releaseName, namespace: namespace, revision: targetRevision ?? 0)
        case .uninstall: .uninstall(release: releaseName, namespace: namespace, keepHistory: keepHistory)
        }
    }

    var applyOptions: HelmApplyOptions { HelmApplyOptions(wait: wait, timeout: .seconds(300), rollbackOnFailure: rollbackOnFailure, skipCRDs: skipCRDs) }

    // MARK: Render and review

    func prepareReview() async {
        guard blocker == nil else { error = blocker; return }
        error = nil
        step = .working(kind == .install || kind == .upgrade ? "Rendering with helm…" : "Reading the revisions…")
        do {
            let runner = try await makeRunner()
            helm = runner
            let op = operation
            let discovery = try? await session.client.discovery()
            var inputs = HelmGrantPlan.Inputs(operation: op, current: current, skipCRDs: skipCRDs, discovery: discovery)
            var data = HelmReviewData(plan: HelmGrantPlan(objects: [], hooks: [], warnings: []), comparison: nil, created: [], rendered: [], removed: [], notes: nil,
                                      helmVersion: runner.cli.version.description)
            switch op {
            case .install, .upgrade:
                let result = try await runner.render(op, cluster: session.config.id, valuesYAML: valuesText, skipCRDs: skipCRDs)
                renderedRelease = result.release
                inputs.next = result.release
                inputs.crdsYAML = result.crdsYAML
                data.rendered = HelmManifest.objects(in: result.release.manifest)
                data.notes = result.release.info.notes.isEmpty ? nil : result.release.info.notes
                if let current, case .upgrade = op {
                    data.comparison = HelmComparison.compare(old: current, new: result.release)
                } else {
                    data.created = data.rendered
                }
            case .rollback(_, _, let revision):
                guard let current, let summary = history.first(where: { $0.revision == revision }) else { throw HelmCLIError.unsupported("That revision is not available.") }
                let reader = HelmReleaseReader(client: session.client, cluster: session.config.id, cache: services.releaseCache)
                let target = try await reader.read(summary)
                inputs.next = target
                data.rendered = HelmManifest.objects(in: target.manifest)
                data.comparison = HelmComparison.compare(old: current, new: target)
            case .uninstall:
                data.removed = HelmManifest.objects(in: current?.manifest ?? "")
            }
            data.plan = HelmGrantPlan.build(inputs)
            review = data
            confirm = nil
            step = .review
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            step = .configure
        }
    }

    func backToConfigure() {
        step = .configure
        review = nil
        error = nil
    }

    // MARK: Confirm

    /// The ConfirmSheet request for the reviewed operation. Production needs the release name typed; a read-only cluster is refused by the
    /// sheet itself. The sheet's action starts the run; nothing else does.
    func makeConfirmRequest() -> ConfirmRequest? {
        guard let review else { return nil }
        let op = operation
        let cluster = session.config
        var facts: [ConfirmRequest.Fact] = [.init("Release", releaseName), .init("Namespace", namespace), .init("helm", review.helmVersion)]
        if op.rendersWithHelm { facts.append(.init("Chart", chart + (chartVersion.isEmpty ? "" : " \(chartVersion)"))) }
        if case .rollback(_, _, let revision) = op { facts.append(.init("Revision", "\(revision)")) }
        facts.append(.init("Objects it may change", "\(review.plan.objects.count)"))
        if !review.plan.hooks.isEmpty { facts.append(.init("Hooks that will run", review.plan.hooks.map(\.name).joined(separator: ", "))) }
        facts.append(.init("Roll back automatically on failure", rollbackOnFailure && op.rendersWithHelm ? "Yes" : "No"))
        let rendered = review.rendered
        let client = session.client
        let namespace = op.namespace
        let discovery = Task { try? await client.discovery() }
        var dryRun: (@MainActor @Sendable () async -> DryRunOutcome)?
        if op.rendersWithHelm {
            dryRun = { @MainActor in
                let found = await discovery.value
                return await HelmFlowModel.serverDryRun(objects: rendered, namespace: namespace, client: client, discovery: found)
            }
        }
        return ConfirmRequest(
            title: "\(kind.title) \(releaseName)", message: Self.message(kind, release: releaseName, namespace: namespace), verb: kind.title,
            isDestructive: kind == .uninstall, cluster: cluster, namespace: namespace, resource: "release/\(releaseName)", confirmationText: releaseName,
            facts: facts, alwaysRequireTyping: kind == .uninstall, origin: .chartRoom,
            dryRun: dryRun,
            action: { @MainActor [weak self] in try await self?.begin() })
    }

    static func message(_ kind: HelmFlowKind, release: String, namespace: String) -> String {
        switch kind {
        case .install: "Installs \(release) into \(namespace) with helm. Only the objects in this review can change."
        case .upgrade: "Upgrades \(release) in \(namespace) with helm. Only the objects in this review can change."
        case .rollback: "Rolls \(release) in \(namespace) back to the revision shown. Only the objects in this review can change."
        case .uninstall: "Uninstalls \(release) from \(namespace) and deletes the objects it created."
        }
    }

    /// A server-side apply dry run of every rendered object (four at a time): admission and validation errors that `helm --dry-run` does not
    /// see. A kind the cluster does not know yet (a CRD the chart installs) is skipped, not failed.
    static func serverDryRun(objects: [HelmManifestObject], namespace: String, client: any KubeClientProtocol, discovery: DiscoveryInfo?) async -> DryRunOutcome {
        enum Result: Sendable { case accepted, skipped, failed(String) }
        func check(_ object: HelmManifestObject) async -> Result {
            let kind = HelmManifest.resourceKind(for: object, discovery: discovery)
            if let discovery, !kind.group.isEmpty, !discovery.topLevel.contains(where: { $0.kind == object.kind && ($0.group ?? "") == kind.group }) { return .skipped }
            do {
                _ = try await client.patch(kind, name: object.name, namespace: kind.namespaced ? (object.namespace ?? namespace) : nil, subresource: nil,
                                           patch: .apply(object.value), options: MutationOptions(dryRun: true, fieldManager: "wheelhouse-helm", force: true))
                return .accepted
            } catch {
                return .failed("\(object.id): \((error as? KubeError)?.summary ?? error.localizedDescription)")
            }
        }
        var results: [Result] = []
        await withTaskGroup(of: Result.self) { group in
            var iterator = objects.makeIterator()
            for _ in 0..<4 { if let object = iterator.next() { group.addTask { await check(object) } } }
            while let result = await group.next() {
                results.append(result)
                if let object = iterator.next() { group.addTask { await check(object) } }
            }
        }
        var failures: [String] = [], skipped = 0, accepted = 0
        for result in results {
            switch result {
            case .accepted: accepted += 1
            case .skipped: skipped += 1
            case .failed(let message): failures.append(message)
            }
        }
        if !failures.isEmpty { return .failed(failures.sorted().prefix(5).joined(separator: "\n")) }
        return .passed("\(accepted) object\(accepted == 1 ? "" : "s") accepted" + (skipped > 0 ? ", \(skipped) of a kind the cluster does not have yet" : ""))
    }

    // MARK: Run

    /// Called by the ConfirmSheet's action: checks the live cluster once more, then starts helm and returns (the sheet closes; progress shows
    /// here).
    func begin() async throws {
        guard let review, let helm else { throw HelmCLIError.unsupported("Review the operation first.") }
        guard case .review = step else { throw HelmCLIError.unsupported("This operation was already started.") }
        if case .refuse(let reason) = MutationPolicy.decide(.mutation(dryRun: false), cluster: session.config, origin: .chartRoom) {
            throw HelmCLIError.unsupported(reason)
        }
        let op = operation, options = applyOptions, values = valuesText, cluster = session.config.id, plan = review.plan
        step = .running
        output = ""
        let sink: @Sendable (String) -> Void = { [weak self] chunk in Task { @MainActor in self?.append(chunk) } }
        runTask = Task { [weak self] in
            var success = false
            do {
                let exit = try await helm.apply(op, plan: plan, cluster: cluster, valuesYAML: values, options: options, output: sink)
                success = exit.succeeded
                if !success { await self?.fail(exit.timedOut ? "helm did not finish in time." : "helm exited with code \(exit.code.map(String.init) ?? "?").") }
            } catch {
                await self?.fail((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
            await self?.finish(success: success)
        }
    }

    private func append(_ chunk: String) {
        output += chunk
        if output.utf8.count > 256 * 1024 { output = String(output.suffix(200 * 1024)) }       // a long run keeps its tail only
    }
    private func fail(_ message: String) { error = message }
    private func finish(success: Bool) {
        step = .finished(success: success)
        if success { NotificationCenter.default.post(name: HelmFlowModel.didChangeRelease, object: nil, userInfo: ["cluster": session.config.id]) }
    }

    /// Posted after a successful run so the Releases list reloads.
    nonisolated static let didChangeRelease = Notification.Name("WheelhouseHelmReleaseChanged")

    /// Ends a run that is still going (the sheet was closed): helm gets SIGTERM through its task's cancellation.
    func cancel() {
        runTask?.cancel()
        confirm = nil
    }
}
