import Foundation
import Observation

/// Reflector-backed store for one kind in one namespace: list → watch → relist on 410 Gone.
///
/// Reference counted: call ``start()`` / ``stop()`` (or use ``run()`` from `.task`). Items are kept when stopped so
/// returning to a screen shows cached content while it refreshes. UI updates are coalesced to ~10 Hz.
@MainActor @Observable
public final class ResourceStore<T: KubeObject> {
    public enum Phase: Sendable, Equatable { case idle, loading, loaded, failed }

    public let kind: ResourceKind
    public let namespace: String?
    public let labelSelector: String?
    public let fieldSelector: String?

    /// Current objects, sorted by ``sortOrder`` (default: namespace, name).
    public private(set) var items: [T] = []
    public private(set) var phase: Phase = .idle
    public private(set) var error: KubeError?
    public private(set) var lastUpdated: Date?
    /// True until the first list completes and there is nothing cached.
    public var isLoading: Bool { phase == .loading && items.isEmpty }
    /// True while a refresh is in flight and cached items are being shown.
    public var isRefreshing: Bool { phase == .loading && !items.isEmpty }
    public var sortOrder: @MainActor @Sendable (T, T) -> Bool = { a, b in
        (a.metadata.namespace ?? "", a.metadata.name) < (b.metadata.namespace ?? "", b.metadata.name)
    } { didSet { publish() } }

    @ObservationIgnored private let client: any KubeClientProtocol
    @ObservationIgnored private var objects: [String: T] = [:]
    @ObservationIgnored private var refCount = 0
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var publishScheduled = false
    @ObservationIgnored private var resourceVersion: String?
    @ObservationIgnored private var isPaused = false
    /// When the last consumer stopped (or the store was created and never started). Used to evict idle stores.
    @ObservationIgnored public private(set) var idleSince: Date? = Date()

    public init(client: any KubeClientProtocol, kind: ResourceKind? = nil, namespace: String? = nil, labelSelector: String? = nil, fieldSelector: String? = nil) {
        self.client = client
        self.kind = kind ?? T.resourceKind
        self.namespace = namespace
        self.labelSelector = labelSelector
        self.fieldSelector = fieldSelector
    }

    // MARK: Lifecycle

    public func start() {
        refCount += 1
        idleSince = nil
        guard task == nil, !isPaused else { return }
        if items.isEmpty { phase = .loading }
        task = Task { [weak self] in await self?.reflect() }
    }

    public func stop() {
        refCount = max(0, refCount - 1)
        guard refCount == 0 else { return }
        task?.cancel()
        task = nil
        idleSince = Date()
    }

    /// Number of active consumers (screens) currently using this store.
    public var consumerCount: Int { refCount }
    /// True while the reflector is running and the last list succeeded, i.e. ``items`` is fresh.
    public var isLive: Bool { task != nil && phase == .loaded && error == nil }

    /// Runs while the calling task is alive: `.task { await store.run() }`.
    public func run() async {
        start()
        defer { stop() }
        while !Task.isCancelled { try? await Task.sleep(for: .seconds(3600)) }
    }

    /// Forces a fresh list + watch (pull to refresh). Returns once the first list has completed or failed.
    public func refresh() async {
        task?.cancel()
        task = nil
        resourceVersion = nil
        phase = .loading
        if refCount > 0 && !isPaused {
            task = Task { [weak self] in await self?.reflect() }
            // Wait for the new reflector's first list so pull-to-refresh spins for the real duration.
            let deadline = ContinuousClock.now.advanced(by: .seconds(30))
            while phase == .loading, !Task.isCancelled, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(40))
            }
        } else {
            await listOnce()
        }
    }

    /// Cancels the reflector but keeps the reference count, e.g. while the app is in the background.
    /// Consumers stay registered; ``resume()`` restarts the watch for them.
    public func pause() {
        isPaused = true
        task?.cancel()
        task = nil
    }

    /// Restarts the reflector after ``pause()`` if there are still consumers.
    public func resume() {
        guard isPaused else { return }
        isPaused = false
        guard refCount > 0, task == nil else { return }
        if items.isEmpty { phase = .loading }
        task = Task { [weak self] in await self?.reflect() }
    }

    /// Cancels the reflector and drops all consumers (cluster removed or its credentials replaced).
    public func invalidate() {
        refCount = 0
        isPaused = false
        task?.cancel()
        task = nil
        idleSince = Date()
    }

    /// Kept for source compatibility; same as ``invalidate()``.
    public func cancel() { invalidate() }

    // MARK: Reflector

    private func listOnce() async {
        do {
            let list = try await client.list(T.self, kind: kind, namespace: namespace, options: ListOptions(labelSelector: labelSelector, fieldSelector: fieldSelector))
            objects = Dictionary(list.items.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
            resourceVersion = list.metadata.resourceVersion
            phase = .loaded
            error = nil
            lastUpdated = Date()
            publish()
        } catch let e as KubeError {
            if e != .cancelled { error = e; phase = .failed }
        } catch {}
    }

    private func reflect() async {
        var backoff: Double = 1
        while !Task.isCancelled {
            do {
                if resourceVersion == nil || phase != .loaded {
                    let list = try await client.list(T.self, kind: kind, namespace: namespace, options: ListOptions(labelSelector: labelSelector, fieldSelector: fieldSelector))
                    objects = Dictionary(list.items.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
                    resourceVersion = list.metadata.resourceVersion
                    phase = .loaded
                    error = nil
                    lastUpdated = Date()
                    publish()
                    backoff = 1
                }
                let stream = client.watch(T.self, kind: kind, namespace: namespace,
                                          options: WatchOptions(labelSelector: labelSelector, fieldSelector: fieldSelector, resourceVersion: resourceVersion))
                let watchStarted = ContinuousClock.now
                var received = 0
                for try await event in stream {
                    received += 1
                    apply(event)
                }
                // Server closed the watch (timeout): resume from the last resourceVersion.
                // A watch that ends at once without events would otherwise spin: back off.
                if received == 0, ContinuousClock.now - watchStarted < .seconds(1) {
                    try? await Task.sleep(for: .seconds(backoff))
                    backoff = min(backoff * 2, 30)
                } else {
                    backoff = 1
                }
            } catch is CancellationError {
                return
            } catch let e as KubeError {
                if e == .cancelled || Task.isCancelled { return }
                if e == .gone {
                    resourceVersion = nil
                    phase = items.isEmpty ? .loading : .loaded
                    continue
                }
                error = e
                phase = items.isEmpty ? .failed : .loaded   // keep cached items usable; never leave a refresh spinning
                resourceVersion = nil
                let nonTransient: Bool = { if case .forbidden = e { true } else if case .unauthorized = e { true } else { false } }()
                try? await Task.sleep(for: .seconds(nonTransient ? max(backoff, 15) : backoff))
                backoff = min(backoff * 2, 30)
            } catch {
                if Task.isCancelled { return }
                self.error = .unreachable(cause: error.localizedDescription)
                phase = items.isEmpty ? .failed : .loaded
                resourceVersion = nil
                try? await Task.sleep(for: .seconds(backoff))
                backoff = min(backoff * 2, 30)
            }
        }
    }

    private func apply(_ event: WatchEvent<T>) {
        switch event {
        case .added(let o), .modified(let o):
            objects[o.id] = o
            resourceVersion = o.metadata.resourceVersion ?? resourceVersion
            error = nil
        case .deleted(let o):
            objects[o.id] = nil
            resourceVersion = o.metadata.resourceVersion ?? resourceVersion
        case .bookmark(let rv):
            if !rv.isEmpty { resourceVersion = rv }
            return
        }
        schedulePublish()
    }

    private func schedulePublish() {
        guard !publishScheduled else { return }
        publishScheduled = true
        Task { [weak self] in
            // 100 ms normally; slower in Low Power Mode / when the device is hot.
            try? await Task.sleep(for: .milliseconds(Int(EnergyPolicy.current.publishInterval * 1000)))
            self?.publishScheduled = false
            self?.publish()
        }
    }

    private func publish() {
        items = objects.values.sorted(by: sortOrder)
        lastUpdated = Date()
    }
}
