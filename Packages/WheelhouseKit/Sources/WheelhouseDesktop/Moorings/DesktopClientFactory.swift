#if os(macOS)
import Foundation
import WheelhouseKit

/// A client that refuses every call with one error: a host the safety gate blocks, or a Production-suggested cluster that has not
/// been checked yet. No request is ever made.
public struct RefusedKubeClient: KubeClientProtocol {
    public let error: KubeError
    public init(error: KubeError) { self.error = error }

    public func version() async throws -> KubeVersion { throw error }
    public func discovery() async throws -> DiscoveryInfo { throw error }
    public func list<T: KubeObject>(_ type: T.Type, kind: ResourceKind, namespace: String?, options: ListOptions) async throws -> KubeList<T> { throw error }
    public func get<T: KubeObject>(_ type: T.Type, kind: ResourceKind, name: String, namespace: String?) async throws -> T { throw error }
    public func listRaw(_ kind: ResourceKind, namespace: String?, options: ListOptions) async throws -> JSONValue { throw error }
    public func getRaw(_ kind: ResourceKind, name: String, namespace: String?) async throws -> JSONValue { throw error }
    public func watch<T: KubeObject>(_ type: T.Type, kind: ResourceKind, namespace: String?, options: WatchOptions) -> AsyncThrowingStream<WatchEvent<T>, Error> {
        let e = error
        return AsyncThrowingStream { $0.finish(throwing: e) }
    }
    public func create(_ kind: ResourceKind, namespace: String?, name: String?, subresource: String?, body: JSONValue, options: MutationOptions) async throws -> JSONValue { throw error }
    public func replace(_ kind: ResourceKind, name: String, namespace: String?, body: JSONValue, options: MutationOptions) async throws -> JSONValue { throw error }
    public func patch(_ kind: ResourceKind, name: String, namespace: String?, subresource: String?, patch: KubePatch, options: MutationOptions) async throws -> JSONValue { throw error }
    public func delete(_ kind: ResourceKind, name: String, namespace: String?, options: DeleteOptions) async throws { throw error }
    public func logs(namespace: String, pod: String, options: LogOptions) -> AsyncThrowingStream<String, Error> {
        let e = error
        return AsyncThrowingStream { $0.finish(throwing: e) }
    }
    public func podMetrics(namespace: String?) async throws -> [PodMetrics] { throw error }
    public func nodeMetrics() async throws -> [NodeMetrics] { throw error }
    public func proxyGET(namespace: String, service: String, port: String, path: String, query: [String: String]) async throws -> Data { throw error }
    public func prepareStreaming() async throws { throw error }
    public func execWebSocket(namespace: String, pod: String, options: ExecOptions) throws -> KubeWebSocket { throw error }
    public func portForwardWebSocket(namespace: String, pod: String, ports: [Int]) throws -> KubeWebSocket { throw error }
}

/// Builds the client of every cluster on the Mac (`ClusterRegistry.ClientFactory`): `LiveKubeClient(config:secrets:tokenSource:)`,
/// with `.dynamic(ExecCredentialProvider)` for exec contexts and `.dynamic(TokenFileProvider)` for a `tokenFile`.
///
/// Gate (ARCHITECTURE-MAC §13.2): while development safety is active a server whose host is not an allowed test host gets a
/// ``RefusedKubeClient``, whatever its origin (a Keychain cluster included).
public final class DesktopClientFactory: Sendable {
    private let state: MooringsState
    private let settings: MacClusterSettingsStore
    private let broker: ExecCredentialBroker
    /// Read on every use, never copied: the registry builds its factory in `App.init`, before the allowed test hosts exist.
    private let gate: @Sendable () -> DevSafetyPolicy
    private let onCertificateRotation: @Sendable (ClusterID) -> Void

    /// `onCertificateRotation` runs when an exec plugin rotates a client certificate; the app then rebuilds the client
    /// (`ClusterEvents.postInvalidated`).
    public init(state: MooringsState, settings: MacClusterSettingsStore, broker: ExecCredentialBroker, gate fixedGate: DevSafetyPolicy? = nil,
                gateProvider: (@Sendable () -> DevSafetyPolicy)? = nil,
                onCertificateRotation: @escaping @Sendable (ClusterID) -> Void = { _ in }) {
        self.state = state
        self.settings = settings
        self.broker = broker
        self.gate = DevSafetyPolicy.provider(fixed: fixedGate, provider: gateProvider)
        self.onCertificateRotation = onCertificateRotation
    }

    public var clientFactory: ClusterRegistry.ClientFactory {
        { [self] config, secrets in make(config: config, secrets: secrets) }
    }

    public func make(config: ClusterConfig, secrets: ClusterSecrets) -> any KubeClientProtocol {
        if config.isDemo { return DemoFleet.client(for: config) }
        do { try gate().validate(server: config.server) } catch {
            return RefusedKubeClient(error: .unreachable(cause: error.localizedDescription))
        }
        if state.isContactHeld(config.id) {
            return RefusedKubeClient(error: .unreachable(cause: "Not checked yet. Click Check to connect to this cluster."))
        }
        return LiveKubeClient(config: config, secrets: secrets, tlsServerName: config.tlsServerName, tokenSource: resolveTokenSource(for: config, secrets: secrets),
                              hostAllowed: { [gate] in gate().isAllowed(server: $0) })
    }

    /// nil keeps the stored token (`.static`).
    func resolveTokenSource(for config: ClusterConfig, secrets: ClusterSecrets) -> BearerTokenSource? {
        let discovered = state.context(for: config.id)
        if let spec = discovered?.context.exec {
            return .dynamic(makeProvider(spec: spec, kubeconfigPath: discovered?.key.definingFile ?? "", config: config, secrets: secrets))
        }
        if let adoption = settings.execAdoption(for: config.id) {
            return .dynamic(makeProvider(spec: adoption.spec, kubeconfigPath: adoption.kubeconfigPath, config: config, secrets: secrets))
        }
        if let path = discovered?.context.files?.tokenFile { return .dynamic(TokenFileProvider(path: path, gate: gate())) }
        return nil
    }

    func makeProvider(spec: KubeconfigExecSpec, kubeconfigPath: String, config: ClusterConfig, secrets: ClusterSecrets) -> ExecCredentialProvider {
        let info = ExecClusterInfo(server: config.server.absoluteString, tlsServerName: config.tlsServerName,
                                   certificateAuthorityData: secrets.caPEM.map { Data($0.utf8).base64EncodedString() },
                                   insecureSkipTLSVerify: config.allowsInsecureTLS)
        let provider = ExecCredentialProvider(spec: spec, cluster: info, kubeconfigPath: kubeconfigPath, broker: broker)
        let id = config.id
        let notify = onCertificateRotation
        Task { await provider.onCertificateRotation { notify(id) } }
        return provider
    }
}
#endif
