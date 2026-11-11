import Testing
import Foundation
import WheelhouseKit
@testable import WheelhouseUI

@Suite("Confirmation input delay")
struct ConfirmationInputDelayTests {
    private func request(_ origin: ChangeOrigin?) -> ConfirmRequest {
        ConfirmRequest(title: "t", message: "m", verb: "v", cluster: ClusterConfig(name: "c", server: URL(string: "https://c.example.com")!),
                       resource: "r", confirmationText: "x", origin: origin) {}
    }

    @Test func onlyNonUIOriginsGetTheOneSecondDelay() {
        #expect(request(nil).inputDelay == 0)
        #expect(request(.ui).inputDelay == 0)
        #expect(request(.chartRoom).inputDelay == 0)
        for o in [ChangeOrigin.firstMate(conversation: "c"), .beacon(client: "b"), .terminal(session: "s", reportedCommand: nil), .rigging(pack: "p")] {
            #expect(request(o).inputDelay == 1.0)
        }
    }

    @Test func onlyNonUIOriginsLoseTheDefaultButton() {
        #expect(request(nil).hasDefaultButton)
        #expect(request(.ui).hasDefaultButton)
        #expect(request(.chartRoom).hasDefaultButton && request(.tides).hasDefaultButton && request(.survey).hasDefaultButton)
        for o in [ChangeOrigin.firstMate(conversation: "c"), .beacon(client: "b"), .terminal(session: "s", reportedCommand: nil), .rigging(pack: "p")] {
            #expect(!request(o).hasDefaultButton)
        }
    }
}
