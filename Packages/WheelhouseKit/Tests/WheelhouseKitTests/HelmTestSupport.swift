import Compression
import Foundation
import Synchronization
@testable import WheelhouseKit

// MARK: - Recorded fixtures

enum HelmFixtures {
    /// `Fixtures/helm/<name>.json`, recorded from the test cluster by `scripts/testcluster-fixtures.sh --section m6a-helm`.
    static func object(_ name: String) throws -> JSONValue {
        let url = try fixtureURL(name)
        return try JSONValue.parse(Data(contentsOf: url))
    }

    private static func fixtureURL(_ name: String) throws -> URL {
        guard let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/helm") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return url
    }
}

// MARK: - Gzip and tar writers (tests only: the app only reads these formats)

enum TestGzip {
    /// Raw DEFLATE through the Compression framework (`COMPRESSION_ZLIB` is raw DEFLATE).
    static func deflate(_ data: Data) -> Data {
        guard !data.isEmpty else { return Data([0x03, 0x00]) }                     // an empty final fixed block
        let capacity = data.count + data.count / 100 + 1024
        var out = [UInt8](repeating: 0, count: capacity)
        let written = data.withUnsafeBytes { src in
            compression_encode_buffer(&out, capacity, src.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, COMPRESSION_ZLIB)
        }
        return Data(out[0..<written])
    }

    static func le32(_ v: UInt32) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 24 & 0xFF)] }

    /// A gzip member. `name`, `comment`, `extra` and `headerCRC` exercise the optional header fields.
    static func compress(_ data: Data, name: String? = nil, comment: String? = nil, extra: [UInt8]? = nil, headerCRC: Bool = false) -> Data {
        var flags: UInt8 = 0
        var header: [UInt8] = [0x1f, 0x8b, 8, 0, 0, 0, 0, 0, 0, 3]
        var optional: [UInt8] = []
        if let extra { flags |= 0x04; optional += [UInt8(extra.count & 0xFF), UInt8(extra.count >> 8)] + extra }
        if let name { flags |= 0x08; optional += Array(name.utf8) + [0] }
        if let comment { flags |= 0x10; optional += Array(comment.utf8) + [0] }
        if headerCRC { flags |= 0x02; optional += [0, 0] }
        header[3] = flags
        return Data(header + optional) + deflate(data) + Data(le32(Gzip.crc32(data)) + le32(UInt32(truncatingIfNeeded: data.count)))
    }

    /// A Helm release record: gzip, then Helm's base64.
    static func helmPayload(_ json: String) -> String { compress(Data(json.utf8)).base64EncodedString() }
}

enum TestTar {
    /// A ustar archive of regular files.
    static func archive(_ files: [(String, String)]) -> Data {
        var out = Data()
        for (path, content) in files {
            var header = [UInt8](repeating: 0, count: 512)
            func put(_ text: String, at offset: Int, max: Int) { for (i, b) in text.utf8.prefix(max).enumerated() { header[offset + i] = b } }
            put(path, at: 0, max: 100)
            put("0000644", at: 100, max: 7)
            put("0000000", at: 108, max: 7)
            put("0000000", at: 116, max: 7)
            put(String(content.utf8.count, radix: 8).leftPad(11), at: 124, max: 11)
            put("00000000000", at: 136, max: 11)
            header[156] = UInt8(ascii: "0")
            put("ustar", at: 257, max: 5)
            put("00", at: 263, max: 2)
            for i in 148..<156 { header[i] = 32 }
            let sum = header.reduce(0) { $0 + Int($1) }
            put(String(sum, radix: 8).leftPad(6), at: 148, max: 6)
            header[154] = 0
            header[155] = 32
            out += Data(header)
            out += Data(content.utf8)
            out += Data(repeating: 0, count: (512 - content.utf8.count % 512) % 512)
        }
        return out + Data(repeating: 0, count: 1024)
    }

    static func tgz(_ files: [(String, String)]) -> Data { TestGzip.compress(archive(files)) }
}

private extension String {
    func leftPad(_ width: Int) -> String { String(repeating: "0", count: max(0, width - count)) + self }
}

// MARK: - A fake API server behind LiveKubeClient

struct FakeRequest: Sendable {
    var method: String
    var path: String
    var query: [String: String]
    var accept: String?
}

struct FakeResponse: Sendable {
    var status: Int = 200
    var body: Data
    static func json(_ value: JSONValue, status: Int = 200) -> FakeResponse { FakeResponse(status: status, body: (try? value.data()) ?? Data()) }
    static func forbidden(resource: String, namespace: String?) -> FakeResponse {
        let scope = namespace.map { "in the namespace \"\($0)\"" } ?? "at the cluster scope"
        return .json(["kind": "Status", "status": "Failure", "reason": "Forbidden", "code": 403,
                      "message": .string("\(resource) is forbidden: User \"tester\" cannot list resource \"\(resource)\" in API group \"\" \(scope)"),
                      "details": ["kind": .string(resource)]], status: 403)
    }
    static func notFound() -> FakeResponse {
        .json(["kind": "Status", "status": "Failure", "reason": "NotFound", "code": 404, "message": "not found"], status: 404)
    }
}

final class FakeAPI: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (FakeRequest) -> FakeResponse
    private struct State { var handlers: [String: Handler] = [:]; var log: [String: [FakeRequest]] = [:] }
    private static let state = Mutex(State())

    static func client(environment: ClusterEnvironment = .development, handler: @escaping Handler) -> (client: LiveKubeClient, host: String) {
        let host = "fake-\(UUID().uuidString.lowercased().prefix(8)).test"
        state.withLock { $0.handlers[host] = handler }
        let config = ClusterConfig(name: "fake", server: URL(string: "https://\(host):6443")!, environment: environment)
        return (LiveKubeClient(config: config, secrets: ClusterSecrets(token: "x"), protocolClasses: [FakeAPI.self]), host)
    }

    static func requests(host: String) -> [FakeRequest] { state.withLock { $0.log[host] ?? [] } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, let host = url.host else { return }
        var query: [String: String] = [:]
        for item in URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [] { query[item.name] = item.value ?? "" }
        let fake = FakeRequest(method: request.httpMethod ?? "GET", path: url.path, query: query, accept: request.value(forHTTPHeaderField: "Accept"))
        let handler = Self.state.withLock { s -> Handler? in
            s.log[host, default: []].append(fake)
            return s.handlers[host]
        }
        let response = handler?(fake) ?? .notFound()
        let http = HTTPURLResponse(url: url, statusCode: response.status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

/// A PartialObjectMetadataList page of Helm release records.
func helmMetadataPage(_ metas: [(name: String, namespace: String, revision: Int, status: String)], continueToken: String? = nil) -> JSONValue {
    let items: [JSONValue] = metas.map { m in
        ["metadata": ["name": .string("sh.helm.release.v1.\(m.name).v\(m.revision)"), "namespace": .string(m.namespace),
                      "resourceVersion": .string("\(m.revision)00"),
                      "creationTimestamp": "2026-11-01T10:00:00Z",
                      "labels": ["owner": "helm", "name": .string(m.name), "status": .string(m.status), "version": .string(String(m.revision)),
                                 "modifiedAt": "1762000000"]]]
    }
    var metadata: [String: JSONValue] = ["resourceVersion": "42"]
    if let continueToken { metadata["continue"] = .string(continueToken) }
    return ["apiVersion": "meta.k8s.io/v1", "kind": "PartialObjectMetadataList", "metadata": .object(metadata), "items": .array(items)]
}
