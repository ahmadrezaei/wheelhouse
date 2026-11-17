#if os(macOS)
import Testing
@testable import WheelhouseDesktop

@Suite("Edition capabilities")
struct EditionCapabilitiesTests {
    @Test func aProcessThatIsNotSandboxedKeepsEveryCapability() {
        Edition.withEdition(Edition(isSandboxed: false)) {
            #expect(ChartRoomCapabilities.current.writes)
            #expect(SurveyCapabilities.current.localScans)
            #expect(TidesCapabilities.current.fluxDiff)
        }
    }

    @Test func aSandboxedProcessLosesEveryCapability() {
        Edition.withEdition(Edition(isSandboxed: true)) {
            #expect(!ChartRoomCapabilities.current.writes)
            #expect(!SurveyCapabilities.current.localScans)
            #expect(!TidesCapabilities.current.fluxDiff)
        }
    }

    @Test func theEditionsPageIsTheDocumentedOne() {
        #expect(EditionNotice.learnMore.absoluteString == "https://ahmadrezaei.github.io/wheelhouse/mac/editions.html")
    }
}
#endif
