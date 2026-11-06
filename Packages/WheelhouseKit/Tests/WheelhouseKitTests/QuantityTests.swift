import Foundation
import Testing
@testable import WheelhouseKit

@Suite struct QuantityTests {
    @Test func cpu() {
        #expect(Quantity("250m").millicores == 250)
        #expect(Quantity("2").cores == 2)
        #expect(Quantity("1.5").millicores == 1500)
        #expect(abs(Quantity("100u").cores - 0.0001) < 1e-12)
        #expect(abs(Quantity("500000000n").cores - 0.5) < 1e-9)
    }

    @Test func memory() {
        #expect(Quantity("128Mi").bytes == 128 * 1_048_576)
        #expect(Quantity("1Gi").bytes == 1_073_741_824)
        #expect(Quantity("512Ki").bytes == 524_288)
        #expect(Quantity("2G").bytes == 2_000_000_000)
        #expect(Quantity("100M").bytes == 100_000_000)
        #expect(Quantity("5k").bytes == 5000)
        #expect(Quantity("1Ti").bytes == 1_099_511_627_776)
    }

    @Test func exponent() {
        #expect(Quantity("1e3").value == 1000)
        #expect(Quantity("12E6").value == 12_000_000)
        #expect(Quantity("129e-3").value == 0.129)
        #expect(Quantity("1E").value == 1e18) // exa suffix, not an exponent
    }

    @Test func invalid() {
        #expect(Quantity("").value == nil)
        #expect(Quantity("abc").value == nil)
        #expect(Quantity("12Xi").value == nil)
    }

    @Test func formatting() {
        #expect(Quantity.formatBytes(268_435_456) == "256Mi")
        #expect(Quantity.formatCPU(cores: 0.25) == "250m")
        #expect(Quantity.formatCPU(cores: 2) == "2")
    }

    @Test func decodesFromJSONNumberAndString() throws {
        let q = try KubeJSON.decoder.decode([String: Quantity].self, from: Data(#"{"a":"1Gi","b":4}"#.utf8))
        #expect(q["a"]?.bytes == 1_073_741_824)
        #expect(q["b"]?.cores == 4)
    }
}
