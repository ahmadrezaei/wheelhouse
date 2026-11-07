import Foundation

public enum HelmDecodeError: Error, Equatable, Sendable, LocalizedError {
    case missingPayload
    case notBase64
    case gzip(GzipError)
    case notJSON
    case notARelease

    public var errorDescription: String? {
        switch self {
        case .missingPayload: "The release record has no payload."
        case .notBase64: "The release payload is not valid base64."
        case .gzip(let e): "The release payload could not be decompressed (\(e))."
        case .notJSON: "The release payload is not valid JSON."
        case .notARelease: "The payload is not a Helm release."
        }
    }
}

/// Decodes `sh.helm.release.v1.<name>.v<N>` records (Helm 3 and Helm 4 write the same format).
///
/// Layers, outermost first:
/// - Secret: `data.release` is base64 from the Kubernetes API, holding Helm's own base64 text, holding gzip.
/// - ConfigMap: `data.release` is Helm's base64 text (one layer), holding gzip.
/// - Older or hand-made records may skip the gzip (plain JSON) or the Helm base64.
public enum HelmReleaseCodec {
    /// Decodes a Secret object (the raw JSON of `GET /api/v1/namespaces/<ns>/secrets/<name>`).
    public static func decodeSecret(_ object: JSONValue, limit: Int = Gzip.defaultLimit) throws -> HelmRelease {
        guard let text = object.value(at: "data.release")?.stringValue, !text.isEmpty else { throw HelmDecodeError.missingPayload }
        guard let apiLayer = Data(base64Encoded: text, options: .ignoreUnknownCharacters) else { throw HelmDecodeError.notBase64 }
        return try decode(payload: apiLayer, object: object, limit: limit)
    }

    /// Decodes a ConfigMap object (`HELM_DRIVER=configmap`).
    public static func decodeConfigMap(_ object: JSONValue, limit: Int = Gzip.defaultLimit) throws -> HelmRelease {
        guard let text = object.value(at: "data.release")?.stringValue, !text.isEmpty else { throw HelmDecodeError.missingPayload }
        return try decode(payload: Data(text.utf8), object: object, limit: limit)
    }

    /// Decodes the bytes found after the Kubernetes layer: Helm's base64 text, raw gzip, or plain JSON.
    public static func decode(payload: Data, object: JSONValue? = nil, limit: Int = Gzip.defaultLimit) throws -> HelmRelease {
        var bytes = payload
        if !Gzip.isGzip(bytes) && !looksLikeJSON(bytes) {
            guard let inner = Data(base64Encoded: bytes, options: .ignoreUnknownCharacters), !inner.isEmpty else { throw HelmDecodeError.notBase64 }
            bytes = inner
        }
        if Gzip.isGzip(bytes) {
            do { bytes = try Gzip.decompress(bytes, limit: limit) } catch let e as GzipError { throw HelmDecodeError.gzip(e) }
        } else if bytes.count > limit {
            throw HelmDecodeError.gzip(.tooLarge(limit: limit))
        }
        guard let json = try? JSONValue.parse(bytes) else { throw HelmDecodeError.notJSON }
        return try release(from: json, object: object, payloadBytes: bytes.count)
    }

    private static func looksLikeJSON(_ data: Data) -> Bool {
        guard let first = data.first(where: { $0 != 0x20 && $0 != 0x0a && $0 != 0x0d && $0 != 0x09 }) else { return false }
        return first == UInt8(ascii: "{")
    }

    // MARK: JSON to model

    static func release(from json: JSONValue, object: JSONValue?, payloadBytes: Int) throws -> HelmRelease {
        guard case .object(let root) = json, let name = root["name"]?.stringValue, root["chart"] != nil || root["manifest"] != nil else {
            throw HelmDecodeError.notARelease
        }
        let info = root["info"] ?? .object([:])
        let chart = root["chart"] ?? .object([:])
        let meta = chart["metadata"] ?? .object([:])

        // The record's own labels and namespace are authoritative when present; otherwise the Kubernetes object's.
        let labels = (root["labels"]?.objectValue ?? [:]).compactMapValues(\.stringValue)
        let namespace = root["namespace"]?.stringValue ?? object?.value(at: "metadata.namespace")?.stringValue ?? ""
        let version = root["version"]?.intValue ?? object?.value(at: "metadata.labels.version")?.stringValue.flatMap(Int.init) ?? 0

        let templates = chart["templates"]?.arrayValue ?? []
        let files = chart["files"]?.arrayValue ?? []
        let schema = chart["schema"]?.stringValue.flatMap { Data(base64Encoded: $0, options: .ignoreUnknownCharacters) }.flatMap { $0.isEmpty ? nil : $0 }

        let chartModel = HelmRelease.Chart(
            metadata: HelmRelease.ChartMetadata(
                name: meta["name"]?.stringValue ?? "",
                version: meta["version"]?.stringValue ?? "",
                appVersion: meta["appVersion"]?.stringValue,
                description: meta["description"]?.stringValue,
                icon: meta["icon"]?.stringValue,
                apiVersion: meta["apiVersion"]?.stringValue,
                home: meta["home"]?.stringValue,
                kubeVersion: meta["kubeVersion"]?.stringValue,
                type: meta["type"]?.stringValue,
                keywords: meta["keywords"]?.arrayValue?.compactMap(\.stringValue) ?? [],
                sources: meta["sources"]?.arrayValue?.compactMap(\.stringValue) ?? [],
                maintainers: (meta["maintainers"]?.arrayValue ?? []).compactMap { m in
                    m["name"]?.stringValue.map { HelmRelease.Maintainer(name: $0, email: m["email"]?.stringValue, url: m["url"]?.stringValue) }
                },
                dependencies: (meta["dependencies"]?.arrayValue ?? []).compactMap { d in
                    d["name"]?.stringValue.map {
                        HelmRelease.Dependency(name: $0, version: d["version"]?.stringValue, repository: d["repository"]?.stringValue,
                                               condition: d["condition"]?.stringValue, alias: d["alias"]?.stringValue)
                    }
                },
                extra: remainder(meta, except: ["name", "version", "appVersion", "description", "icon", "apiVersion", "home", "kubeVersion",
                                                "type", "keywords", "sources", "maintainers", "dependencies"])),
            values: chart["values"].flatMap { $0.isNull ? nil : $0 } ?? .object([:]),
            schema: schema,
            templateCount: templates.count,
            fileNames: files.compactMap { $0["name"]?.stringValue })

        let hooks = (root["hooks"]?.arrayValue ?? []).map { h -> HelmRelease.Hook in
            let run = h["last_run"].flatMap { r -> HelmRelease.HookRun? in
                guard let phase = r["phase"]?.stringValue, !phase.isEmpty else { return nil }
                return HelmRelease.HookRun(phase: phase, startedAt: date(r["started_at"]), completedAt: date(r["completed_at"]))
            }
            return HelmRelease.Hook(name: h["name"]?.stringValue ?? "", kind: h["kind"]?.stringValue ?? "", path: h["path"]?.stringValue ?? "",
                                    manifest: h["manifest"]?.stringValue ?? "",
                                    events: h["events"]?.arrayValue?.compactMap(\.stringValue) ?? [],
                                    weight: h["weight"]?.intValue ?? 0,
                                    deletePolicies: h["delete_policies"]?.arrayValue?.compactMap(\.stringValue) ?? [],
                                    lastRun: run)
        }

        let status = HelmReleaseStatus(label: info["status"]?.stringValue ?? labels["status"])
        return HelmRelease(
            name: name, namespace: namespace, version: version,
            info: HelmRelease.Info(firstDeployed: date(info["first_deployed"]), lastDeployed: date(info["last_deployed"]),
                                   deleted: date(info["deleted"]), description: info["description"]?.stringValue ?? "", status: status,
                                   notes: info["notes"]?.stringValue ?? "",
                                   extra: remainder(info, except: ["first_deployed", "last_deployed", "deleted", "description", "status", "notes"])),
            chart: chartModel,
            config: root["config"].flatMap { $0.isNull ? nil : $0 } ?? .object([:]),
            manifest: root["manifest"]?.stringValue ?? "",
            hooks: hooks, labels: labels,
            extra: remainder(.object(root), except: ["name", "info", "chart", "config", "manifest", "hooks", "version", "namespace", "labels"]),
            payloadBytes: payloadBytes)
    }

    private static func remainder(_ value: JSONValue, except known: Set<String>) -> JSONValue {
        .object((value.objectValue ?? [:]).filter { !known.contains($0.key) })
    }

    /// Go timestamps (`2026-01-02T03:04:05.123456789+01:00`); the zero time (`0001-01-01…`) means "never".
    static func date(_ value: JSONValue?) -> Date? {
        guard var text = value?.stringValue, !text.isEmpty, !text.hasPrefix("0001-01-01") else { return nil }
        // Foundation's fractional-seconds parser rejects nanosecond precision: cut the fraction to milliseconds.
        if let dot = text.firstIndex(of: ".") {
            var end = text.index(after: dot)
            while end < text.endIndex, text[end].isNumber { end = text.index(after: end) }
            let digits = String(text[text.index(after: dot)..<end].prefix(3))
            let fraction = digits + String(repeating: "0", count: 3 - digits.count)
            text = String(text[..<dot]) + "." + fraction + String(text[end...])
            return try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(text)
        }
        return try? Date.ISO8601FormatStyle().parse(text)
    }
}
