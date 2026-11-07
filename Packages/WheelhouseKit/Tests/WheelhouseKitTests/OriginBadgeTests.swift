import Testing
import Foundation
import WheelhouseKit
@testable import WheelhouseUI

@Suite("OriginBadge")
struct OriginBadgeTests {
    static let allOrigins: [ChangeOrigin] = [
        .ui, .chartRoom, .tides, .survey, .firstMate(conversation: "c1"), .beacon(client: "Claude Code"),
        .terminal(session: "s1", reportedCommand: "kubectl delete pod web-1"), .terminal(session: "s2", reportedCommand: nil), .rigging(pack: "cert-manager"),
    ]

    @Test(arguments: allOrigins)
    func everyOriginHasATitleASymbolAndAnAccessibilityLabel(origin: ChangeOrigin) {
        let style = OriginBadgeStyle.style(for: origin)
        #expect(style.title == origin.badgeTitle)
        #expect(!style.symbol.isEmpty)
        #expect(style.accessibilityLabel.contains(origin.badgeTitle))
    }

    @Test func toneFollowsWhoAskedForTheChange() {
        for origin in Self.allOrigins {
            let tone = OriginBadgeStyle.style(for: origin).tone
            switch origin {
            case .ui, .chartRoom, .tides, .survey: #expect(tone == .own)
            case .terminal: #expect(tone == .terminal)
            case .firstMate, .beacon, .rigging: #expect(tone == .external)
            }
            // Every origin that gets a hardened sheet is visibly not "own".
            #expect((tone != .own) == origin.isNonUI)
        }
    }

    @Test func detailNamesTheRequesterWhenTheOriginKnowsIt() {
        #expect(OriginBadgeStyle.style(for: .beacon(client: "Claude Code")).detail == "Claude Code")
        #expect(OriginBadgeStyle.style(for: .rigging(pack: "cert-manager")).detail == "cert-manager")
        #expect(OriginBadgeStyle.style(for: .terminal(session: "s", reportedCommand: "kubectl scale deploy web --replicas=0")).detail == "kubectl scale deploy web --replicas=0")
        #expect(OriginBadgeStyle.style(for: .terminal(session: "s", reportedCommand: nil)).detail == nil)
        #expect(OriginBadgeStyle.style(for: .firstMate(conversation: "c1")).detail == nil)
        #expect(OriginBadgeStyle.style(for: .ui).detail == nil)
    }

    @Test func longDetailIsShortened() {
        let long = String(repeating: "x", count: 200)
        let detail = OriginBadgeStyle.style(for: .terminal(session: "s", reportedCommand: long)).detail ?? ""
        #expect(detail.count <= 41)
        #expect(detail.hasSuffix("…"))
    }

    @Test func accessibilityLabelSaysRequestedByForExternalOrigins() {
        #expect(OriginBadgeStyle.style(for: .firstMate(conversation: "c")).accessibilityLabel == "Requested by First Mate")
        #expect(OriginBadgeStyle.style(for: .beacon(client: "Cursor")).accessibilityLabel == "Requested by Beacon (Cursor)")
        #expect(OriginBadgeStyle.style(for: .chartRoom).accessibilityLabel == "Started in Chart Room")
    }

    @Test func controlAndFormatCharactersAreStrippedFromClientNames() {
        let evil = "Cl\u{202E}aude\u{200B} Code\u{07}"
        #expect(OriginBadgeStyle.style(for: .beacon(client: evil)).detail == "Claude Code")
        #expect(OriginBadgeStyle.style(for: .beacon(client: "\u{202E}\u{200B}")).detail == nil)
    }
}
