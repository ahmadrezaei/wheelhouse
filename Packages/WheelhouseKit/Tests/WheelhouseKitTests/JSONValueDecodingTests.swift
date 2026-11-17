import Foundation
import Testing
@testable import WheelhouseKit

/// P2: `KubeJSON.decoder` decodes `JSONValue` strings and objects first (`JSONValue.typedSourceKey`). JSON keeps its types apart, so the
/// result must be exactly what the original order gives.
@Suite("JSONValue decoding")
struct JSONValueDecodingTests {
    static let sample = #"""
    {"s": "3", "t": "true", "e": "", "i": 3, "n": -42, "big": 9007199254740993, "d": 1.5, "whole": 2.0, "exp": 1e3, "b": true, "f": false,
     "z": null, "a": [1, "1", true, null, {"k": [ ]}, [2.5]], "o": {"nested": {"deep": ["x", {"y": 0}]}}, "empty": {},
     "projected": {"sources": [{"serviceAccountToken": {"expirationSeconds": 3607, "path": "token"}},
                               {"configMap": {"name": "kube-root-ca.crt", "items": [{"key": "ca.crt", "path": "ca.crt"}]}}], "defaultMode": 420}}
    """#

    @Test func kubeDecoderIsMarkedAsATypedSource() {
        #expect(KubeJSON.decoder.userInfo[JSONValue.typedSourceKey] as? Bool == true)
        #expect(JSONDecoder().userInfo[JSONValue.typedSourceKey] == nil)
    }

    @Test func typedOrderGivesTheSameValuesAsTheOriginalOrder() throws {
        let data = Data(Self.sample.utf8)
        let typed = try KubeJSON.decoder.decode(JSONValue.self, from: data)
        let original = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(typed == original)
        #expect(typed["s"] == .string("3"))
        #expect(typed["t"] == .string("true"))
        #expect(typed["e"] == .string(""))
        #expect(typed["i"] == .int(3))
        #expect(typed["n"] == .int(-42))
        #expect(typed["d"] == .double(1.5))
        #expect(typed["b"] == .bool(true))
        #expect(typed["f"] == .bool(false))
        #expect(typed["z"] == .null)
        #expect(typed["empty"] == .object([:]))
        #expect(typed["a"] == .array([1, "1", true, nil, ["k": []], [2.5]]))
        #expect(typed["o"]?["nested"]?["deep"] == .array(["x", ["y": 0]]))
        #expect(typed["projected"]?["defaultMode"] == .int(420))
        // Numbers keep Int before Double in both orders.
        #expect(typed["whole"] == original["whole"])
        #expect(typed["exp"] == original["exp"])
        #expect(typed["big"] == original["big"])
    }

    /// The one setting where the order shows: with `.convertFromString` a float name is both a String and a Double. It proves the typed
    /// order reaches nested containers (and why the key requires the default strategy).
    @Test func theTypedOrderReachesNestedValues() throws {
        func decoder(typed: Bool) -> JSONDecoder {
            let d = KubeJSON.decoder
            d.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "+Inf", negativeInfinity: "-Inf", nan: "NaN")
            d.userInfo[JSONValue.typedSourceKey] = typed
            return d
        }
        let data = Data(#"{"a": {"b": ["+Inf"]}}"#.utf8)
        #expect(try decoder(typed: true).decode(JSONValue.self, from: data)["a"]?["b"] == .array([.string("+Inf")]))
        #expect(try decoder(typed: false).decode(JSONValue.self, from: data)["a"]?["b"] == .array([.double(.infinity)]))
    }

    @Test func typedModelsDecodeTheSameWithEitherOrder() throws {
        let pod = #"""
        {"metadata": {"name": "p", "namespace": "ns", "uid": "u"},
         "spec": {"containers": [{"name": "c", "image": "i", "ports": [{"containerPort": 80}],
                                  "livenessProbe": {"httpGet": {"path": "/", "port": 8080}}, "envFrom": [{"configMapRef": {"name": "x"}}]}],
                  "volumes": [{"name": "v", "projected": {"sources": [{"serviceAccountToken": {"path": "token"}}]}}, {"name": "e", "emptyDir": {}}],
                  "imagePullSecrets": [{"name": "r"}]}}
        """#
        let data = Data(pod.utf8)
        let original = KubeJSON.decoder
        original.userInfo[JSONValue.typedSourceKey] = false
        #expect(try KubeJSON.decoder.decode(Pod.self, from: data) == original.decode(Pod.self, from: data))
        let service = Data(#"{"metadata": {"name": "s"}, "spec": {"ports": [{"port": 80, "targetPort": 8080}, {"port": 81, "targetPort": "http"}]}}"#.utf8)
        let typed = try KubeJSON.decoder.decode(Service.self, from: service)
        #expect(try original.decode(Service.self, from: service) == typed)
        #expect(typed.spec.ports.map(\.targetPort) == [.int(8080), .string("http")])
    }

    @Test func invalidJSONStillFails() {
        #expect(throws: (any Error).self) { try KubeJSON.decoder.decode(JSONValue.self, from: Data("not json".utf8)) }
    }
}
