import Foundation
import Testing
@testable import WheelhouseKit

@Suite("Helm release codec")
struct HelmReleaseCodecTests {
    // MARK: Recorded fixtures

    @Test func helm3SecretDecodes() throws {
        let release = try HelmReleaseCodec.decodeSecret(HelmFixtures.object("helm3-secret-v2"))
        #expect(release.name == "wh-fixture")
        #expect(release.namespace == "wh-m6a")
        #expect(release.version == 2)
        #expect(release.info.status == .deployed)
        #expect(release.info.description == "Upgrade complete")
        #expect(release.info.lastDeployed != nil && release.info.firstDeployed != nil)
        #expect(release.info.deleted == nil)
        #expect(release.info.notes.contains("https://example.com/docs"))
        #expect(release.chart.metadata.name == "wh-fixture")
        #expect(release.chart.metadata.version == "0.2.0")
        #expect(release.chart.metadata.appVersion == "1.2.0")
        #expect(release.chart.metadata.maintainers.map(\.name) == ["Wheelhouse"])
        #expect(release.chart.templateCount == 4)
        #expect(release.chart.schema != nil)
        #expect(release.chart.values["replicas"]?.intValue == 2)
        #expect(release.config["replicas"]?.intValue == 2)
        #expect(release.config.value(at: "auth.password")?.stringValue == "fixture-password-2")
        #expect(release.computedValues.value(at: "image.tag")?.stringValue == "3.10")          // from the chart defaults
        #expect(release.computedValues.value(at: "auth.username")?.stringValue == "demo")     // default kept under a partly overridden map
        #expect(release.manifest.contains("kind: ConfigMap") && release.manifest.contains("kind: Service"))
        #expect(release.hooks.count == 1)
        let hook = try #require(release.hooks.first)
        #expect(hook.kind == "ConfigMap" && hook.weight == 5)
        #expect(hook.events == ["post-install", "post-upgrade"])
        #expect(hook.deletePolicies == ["before-hook-creation"])
        #expect(hook.lastRun?.phase == "Succeeded")
        #expect(hook.lastRun?.startedAt != nil)
        #expect(release.payloadBytes > 1000)
    }

    @Test func revisionOneIsAFirstInstall() throws {
        let release = try HelmReleaseCodec.decodeSecret(HelmFixtures.object("helm3-secret-v1"))
        #expect(release.version == 1)
        #expect(release.info.status == .superseded)               // Helm rewrote revision 1 when revision 2 was installed
        #expect(release.config.value(at: "auth.password")?.stringValue == "fixture-password-1")
        #expect(release.chart.metadata.version == "0.1.0")
    }

    @Test func failedReleaseKeepsItsStatus() throws {
        let release = try HelmReleaseCodec.decodeSecret(HelmFixtures.object("helm3-secret-failed"))
        #expect(release.info.status == .failed && release.info.status.needsAttention)
        #expect(release.info.description.contains("failed") || release.info.description.contains("Service"))
    }

    @Test func helm4StyleRecordKeepsUnknownFields() throws {
        let release = try HelmReleaseCodec.decodeSecret(HelmFixtures.object("helm4-style-secret-v1"))
        #expect(release.name == "wh-helm4")
        #expect(release.version == 1)
        #expect(release.info.status == .deployed)
        #expect(release.extra["future_field"]?["added"]?.stringValue == "by a newer helm")
        #expect(release.info.extra["resources"] != nil)
        #expect(release.chart.metadata.apiVersion == "v2" && release.chart.metadata.type == "application")
        #expect(release.manifest.contains("kind: Service"))
    }

    @Test func configMapHasOneBase64Layer() throws {
        let release = try HelmReleaseCodec.decodeConfigMap(HelmFixtures.object("helm3-configmap-v1"))
        #expect(release.name == "wh-cm" && release.namespace == "wh-m6a-cm" && release.version == 1)
        #expect(release.info.status == .deployed)
    }

    // MARK: Layers and edge cases

    private static let minimal = #"{"name":"app","version":3,"namespace":"ns","info":{"status":"failed","last_deployed":"2026-03-04T05:06:07.123456789+01:00","deleted":"0001-01-01T00:00:00Z"},"chart":{"metadata":{"name":"c","version":"1.0.0"}},"manifest":"kind: A"}"#

    @Test func plainJSONWithoutGzipDecodes() throws {
        let release = try HelmReleaseCodec.decode(payload: Data(Self.minimal.utf8))
        #expect(release.name == "app" && release.version == 3 && release.info.status == .failed)
        #expect(release.info.deleted == nil)                       // Go's zero time means never
        #expect(release.info.lastDeployed != nil)                  // nanosecond precision and an offset parse
    }

    @Test func gzipWithoutTheHelmBase64LayerDecodes() throws {
        let gz = TestGzip.compress(Data(Self.minimal.utf8))
        #expect(try HelmReleaseCodec.decode(payload: gz).name == "app")
    }

    @Test func secretWrapsHelmsBase64InTheAPIsBase64() throws {
        let helmText = TestGzip.helmPayload(Self.minimal)                                  // what Helm stores
        let object: JSONValue = ["metadata": ["name": "sh.helm.release.v1.app.v3", "namespace": "ns"],
                                 "data": ["release": .string(Data(helmText.utf8).base64EncodedString())]]
        #expect(try HelmReleaseCodec.decodeSecret(object).name == "app")
        let configMap: JSONValue = ["metadata": ["name": "x", "namespace": "ns"], "data": ["release": .string(helmText)]]
        #expect(try HelmReleaseCodec.decodeConfigMap(configMap).version == 3)
    }

    @Test func versionAndNamespaceFallBackToTheObject() throws {
        let json = #"{"name":"app","chart":{"metadata":{"name":"c","version":"1"}},"manifest":""}"#
        let object: JSONValue = ["metadata": ["name": "n", "namespace": "from-object", "labels": ["version": "7"]]]
        let release = try HelmReleaseCodec.decode(payload: Data(json.utf8), object: object)
        #expect(release.namespace == "from-object" && release.version == 7)
    }

    @Test func gzipHeaderFieldsAreSkipped() throws {
        let data = Data("hello helm".utf8)
        for gz in [TestGzip.compress(data, name: "release.json"),
                   TestGzip.compress(data, comment: "made by a test"),
                   TestGzip.compress(data, extra: [1, 2, 3, 4, 5]),
                   TestGzip.compress(data, headerCRC: true),
                   TestGzip.compress(data, name: "n", comment: "c", extra: [9, 9], headerCRC: true)] {
            #expect(try Gzip.decompress(gz) == data)
        }
        #expect(try Gzip.decompress(TestGzip.compress(Data())) == Data())
    }

    @Test func gzipErrors() throws {
        let good = TestGzip.compress(Data(repeating: 0x41, count: 10_000))
        #expect(throws: GzipError.notGzip) { try Gzip.decompress(Data("plain".utf8)) }
        #expect(throws: GzipError.truncated) { try Gzip.decompress(good.prefix(12)) }
        var badCRC = good
        badCRC[badCRC.count - 8] ^= 0xFF
        #expect(throws: GzipError.checksumMismatch) { try Gzip.decompress(badCRC) }
        var badSize = good
        badSize[badSize.count - 1] ^= 0x01
        #expect(throws: GzipError.sizeMismatch) { try Gzip.decompress(badSize) }
        var badMethod = good
        badMethod[2] = 7
        #expect(throws: GzipError.unsupportedMethod(7)) { try Gzip.decompress(badMethod) }
        // A DEFLATE body cut short but with a valid-looking trailer is truncated or corrupt, never accepted.
        var cut = Data(good.prefix(10)) + Data(good[10..<good.count / 2]) + Data(good.suffix(8))
        cut[cut.count - 1] = good[good.count - 1]
        #expect(throws: (any Error).self) { try Gzip.decompress(cut) }
    }

    @Test func zipBombIsStoppedWhileStreaming() throws {
        let zeros = Data(count: 8 * 1024 * 1024)
        let bomb = TestGzip.compress(zeros)
        #expect(bomb.count < 100_000)                                                  // 8 MB squeezed into well under 100 KB
        #expect(throws: GzipError.tooLarge(limit: 1024 * 1024)) { try Gzip.decompress(bomb, limit: 1024 * 1024) }
        #expect(try Gzip.decompress(bomb, limit: 8 * 1024 * 1024) == zeros)
    }

    @Test func defaultLimitIs64MB() throws {
        #expect(Gzip.defaultLimit == 64 * 1024 * 1024)
        let bomb = TestGzip.compress(Data(count: Gzip.defaultLimit + 1))
        #expect(throws: GzipError.tooLarge(limit: Gzip.defaultLimit)) { try Gzip.decompress(bomb) }
        #expect(throws: HelmDecodeError.gzip(.tooLarge(limit: Gzip.defaultLimit))) { try HelmReleaseCodec.decode(payload: bomb) }
    }

    @Test func malformedPayloadsFailCleanly() throws {
        #expect(throws: HelmDecodeError.missingPayload) { try HelmReleaseCodec.decodeSecret(["data": [:]]) }
        #expect(throws: HelmDecodeError.notBase64) { try HelmReleaseCodec.decodeSecret(["data": ["release": "@@@@"]]) }
        #expect(throws: HelmDecodeError.notJSON) { try HelmReleaseCodec.decode(payload: TestGzip.compress(Data("not json".utf8))) }
        #expect(throws: HelmDecodeError.notARelease) { try HelmReleaseCodec.decode(payload: Data(#"{"kind":"Pod"}"#.utf8)) }
    }

    // MARK: Values masking

    @Test func sensitiveKeysAreMaskedUntilRevealed() throws {
        let release = try HelmReleaseCodec.decodeSecret(HelmFixtures.object("helm3-secret-v2"))
        let masked = HelmValuesMask.yaml(release.config, revealed: false)
        #expect(!masked.contains("fixture-password-2") && !masked.contains("fixture-token-2"))
        #expect(masked.contains(HelmValuesMask.placeholder) && masked.contains("replicas"))
        #expect(HelmValuesMask.yaml(release.config, revealed: true).contains("fixture-password-2"))
        #expect(HelmValuesMask.containsSensitiveValues(release.config))
        #expect(!HelmValuesMask.containsSensitiveValues(["replicas": 2, "image": ["tag": "1"]]))
    }

    @Test func everyDocumentedKeyPatternMasksNestedValues() {
        for key in ["password", "dbSecret", "apiToken", "tlsKey", "credentials", "sentryDsn", "passwd", "apikey", "API_KEY"] {
            let masked = HelmValuesMask.masked(.object([key: ["inner": "value", "list": ["a", 1]]]))
            #expect(masked.jsonString().contains("value") == false, "\(key)")
        }
        #expect(HelmValuesMask.masked(["name": "visible", "empty-password": ""]) == ["name": "visible", "empty-password": ""])
    }
}
