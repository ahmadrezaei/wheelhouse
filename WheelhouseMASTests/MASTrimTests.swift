import Testing
import Foundation
import WheelhouseKit
import WheelhouseUI
@testable import WheelhouseMac

/// The trimmed App Store edition: features the sandbox cannot run are absent from the registry, Settings, menus and Compass, and the
/// edition owns its URL scheme.
@Suite("Mac App Store edition trim")
struct MASTrimTests {
    private static let removed: [FeatureID] = [.deckTerminal, .landfall, .beacon, .rigging]

    @Test func removedFeaturesAreOffInEveryConfiguration() {
        for id in Self.removed {
            #expect(!FeatureRegistry.isEnabled(id, gateActive: true), "\(id)")
            #expect(!FeatureRegistry.isEnabled(id, gateActive: false), "\(id)")
            #expect(!FeatureRegistry.enabled.contains { $0.id == id }, "\(id)")
        }
        for id in FeatureID.allCases where !Self.removed.contains(id) {
            #expect(FeatureRegistry.isEnabled(id, gateActive: true), "\(id)")
        }
    }

    @Test func settingsHideTheRemovedFeaturesAndKeepThePodShellPane() {
        let visible = SettingsPane.visible
        for pane in [SettingsPane.landfall, .beacon, .rigging, .updates, .chartRoom] { #expect(!visible.contains(pane), "\(pane)") }
        #expect(visible.contains(.terminal))
        #expect(visible.contains(.moorings))
    }

    @MainActor @Test func noCompassCommandOffersACloudImport() {
        let env = MacAppEnvironment.live()
        let ids = env.commandRegistry.commands.map(\.id)
        #expect(!ids.contains("file.addFromCloud"))
        #expect(ids.contains("file.addCluster"))
    }

    @Test func aSavedDestinationOfARemovedFeatureOpensAsAPlaceholder() throws {
        let cluster: ClusterID = "c1"
        let saved: [WorkspaceDestination] = [
            .deckTerminal(TerminalSpec(clusterID: cluster)),
            .landfall,
            .riggingView(RiggingViewRef(pack: "cert-manager", view: "certificates", clusterID: cluster, namespace: nil)),
        ]
        for destination in saved {
            let data = try JSONEncoder().encode(destination)
            let restored = try JSONDecoder().decode(WorkspaceDestination.self, from: data)
            #expect(restored == destination)
            #expect(FeatureRegistry.feature(for: restored) == nil, "\(restored.caseName)")
        }
        #expect(FeatureRegistry.unavailableHint == "Not available in the App Store edition.")
    }

    @Test func theEditionOwnsItsURLScheme() throws {
        #expect(DeepLink.scheme == "wheelhouse-mas")
        #expect(DeepLink.importURL.absoluteString == "wheelhouse-mas://import")
        #expect(DeepLink.accepts("wheelhouse"))
        let main = try #require(Bundle.main.infoDictionary)
        let types = try #require(main["CFBundleURLTypes"] as? [[String: Any]])
        let schemes = types.flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }
        #expect(schemes == ["wheelhouse-mas"])
        #expect(main["WHURLScheme"] as? String == "wheelhouse-mas")
        #expect(WidgetLinks.cluster("prod")?.scheme == "wheelhouse-mas")
    }

    @Test func theWidgetReadsTheSameSchemeFromItsOwnInfoPlist() throws {
        let plugins = try #require(Bundle.main.builtInPlugInsURL)
        let info = plugins.appending(path: "WheelhouseMASWidgets.appex/Contents/Info.plist")
        let dict = try #require(NSDictionary(contentsOf: info) as? [String: Any])
        #expect(dict["WHURLScheme"] as? String == "wheelhouse-mas")
    }

    @Test func theDebugProductHasItsOwnName() {
        #expect(Bundle.main.bundleURL.lastPathComponent == "WheelhouseMAS.app")
    }
}
