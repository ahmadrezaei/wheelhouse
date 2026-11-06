import Foundation

/// Server-managed noise that is hidden from the editor and ignored by the diff.
public enum YAMLNormalizer {
    /// `metadata` fields owned by the API server.
    public static let serverMetadataKeys = ["managedFields", "resourceVersion", "uid", "creationTimestamp", "generation", "selfLink", "deletionTimestamp", "deletionGracePeriodSeconds"]

    /// Returns the object as the user should edit it: no `status`, no server-owned `metadata` fields,
    /// and no empty `annotations`/`labels` left behind.
    public static func editable(_ object: JSONValue) -> JSONValue {
        guard case .object(var root) = object else { return object }
        root["status"] = nil
        if case .object(var meta)? = root["metadata"] {
            for k in serverMetadataKeys { meta[k] = nil }
            for k in ["annotations", "labels"] {
                if case .object(let m)? = meta[k], m.isEmpty { meta[k] = nil }
            }
            root["metadata"] = .object(meta)
        }
        return .object(root)
    }

    /// Everything except `managedFields` (the "Show server fields" view).
    public static func withoutManagedFields(_ object: JSONValue) -> JSONValue {
        var copy = object
        if case .object(var meta)? = copy["metadata"] {
            meta["managedFields"] = nil
            copy["metadata"] = .object(meta)
        }
        return copy
    }

    public static func resourceVersion(of object: JSONValue) -> String? { object.value(at: "metadata.resourceVersion")?.stringValue }

    /// Builds the PUT body for an edited document: re-attaches the `resourceVersion` for optimistic concurrency
    /// and the original `status` (which the editor hides) so kinds without a status subresource keep it.
    public static func replaceBody(edited: JSONValue, original: JSONValue, resourceVersion: String?) -> JSONValue {
        var body = edited
        if body["status"] == nil, let status = original["status"] { body["status"] = status }
        if let rv = resourceVersion { body.setValue(.string(rv), at: "metadata.resourceVersion") }
        if let uid = original.value(at: "metadata.uid") { body.setValue(uid, at: "metadata.uid") }
        return body
    }

    /// Number of changed lines (added + removed) between two objects after normalisation.
    public static func semanticallyEqual(_ a: JSONValue, _ b: JSONValue) -> Bool {
        YAMLCodec.dump(editable(a)) == YAMLCodec.dump(editable(b))
    }
}

// MARK: - Secrets

public enum SecretMasking {
    public static let placeholder = "••••••••"

    public static func isSecret(_ object: JSONValue) -> Bool { object["kind"]?.stringValue == "Secret" }

    /// Replaces every `data` / `stringData` value with a fingerprint placeholder, so a diff still shows *that* a value
    /// changed without showing it. Equal values yield equal placeholders.
    public static func masked(_ object: JSONValue, fingerprint: Bool = true) -> JSONValue {
        guard isSecret(object) else { return object }
        var copy = object
        for section in ["data", "stringData"] {
            guard case .object(let entries)? = copy[section] else { continue }
            var out: [String: JSONValue] = [:]
            for (k, v) in entries {
                out[k] = .string(fingerprint ? "\(placeholder) \(shortHash(v.stringValue ?? v.jsonString()))" : placeholder)
            }
            copy[section] = .object(out)
        }
        return copy
    }

    /// Stable, non-reversible 6-hex fingerprint (FNV-1a). Not for security; only to tell values apart on screen.
    static func shortHash(_ s: String) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return String(String(h, radix: 16).suffix(6))
    }
}

// MARK: - Validation of an edited manifest against the object being edited

public enum YAMLEditValidator {
    /// Semantic checks on top of syntax: single mapping document, identity unchanged.
    public static func validate(text: String, ref: ResourceRef) -> (diagnostics: [YAMLDiagnostic], value: JSONValue?) {
        let docs = YAMLCodec.parseDocuments(text)
        if let bad = docs.compactMap(\.diagnostic).first { return ([bad], nil) }
        guard let doc = docs.first else { return ([YAMLDiagnostic(line: 1, message: "The document is empty")], nil) }
        if docs.count > 1 { return ([YAMLDiagnostic(line: docs[1].startLine, message: "Only one document can be edited at a time")], nil) }
        guard let value = doc.value, case .object = value else { return ([YAMLDiagnostic(line: 1, message: "The document must be a mapping")], nil) }
        var out: [YAMLDiagnostic] = []
        func line(_ path: String) -> Int { YAMLCodec.line(forPath: path, in: text) ?? 1 }
        if value["apiVersion"]?.stringValue != ref.kind.apiVersion {
            out.append(YAMLDiagnostic(line: line("apiVersion"), message: "apiVersion must stay “\(ref.kind.apiVersion)”"))
        }
        if value["kind"]?.stringValue != ref.kind.kind {
            out.append(YAMLDiagnostic(line: line("kind"), message: "kind must stay “\(ref.kind.kind)”"))
        }
        if value.value(at: "metadata.name")?.stringValue != ref.name {
            out.append(YAMLDiagnostic(line: line("metadata.name"), message: "metadata.name is immutable (“\(ref.name)”)"))
        }
        if ref.kind.namespaced, value.value(at: "metadata.namespace")?.stringValue != ref.namespace {
            out.append(YAMLDiagnostic(line: line("metadata.namespace"), message: "metadata.namespace is immutable (“\(ref.namespace ?? "")”)"))
        }
        return (out, out.isEmpty ? value : nil)
    }
}
