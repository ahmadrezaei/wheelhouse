import Testing
import Foundation
@testable import WheelhouseMac

@Suite("FeatureRegistry")
struct FeatureRegistryTests {
    @Test func everyFeatureIDIsRegisteredExactlyOnce() {
        let ids = FeatureRegistry.all.map(\.id)
        #expect(Set(ids) == Set(FeatureID.allCases))
        #expect(ids.count == Set(ids).count)
    }

    @Test func everyDestinationCaseIsHandledByExactlyOneFeatureOrByRoute() {
        for (name, destination) in WorkspaceSamples.samples where name != "route" {
            let handlers = FeatureRegistry.all.filter { $0.handles(destination) }
            #expect(handlers.count == 1, "\(name) handled by \(handlers.map(\.id))")
        }
        let route = WorkspaceSamples.samples[0].value
        #expect(FeatureRegistry.all.allSatisfy { !$0.handles(route) })   // every iOS route stays with the shared views
    }

    @Test func developmentBuildsShowEveryFeatureAndDistributionOnlyReleasedOnes() {
        for id in FeatureID.allCases {
            #expect(FeatureRegistry.isEnabled(id, gateActive: true))
            #expect(!FeatureRegistry.isEnabled(id, gateActive: false))   // nothing is released in M1a
        }
    }

    @Test func featureGroupsSupplyTheirSidebarNodes() throws {
        let chart = try #require(FeatureRegistry.all.first { $0.id == .chartRoom })
        #expect(chart.sidebarNodes.map(\.title) == ["Releases", "Charts", "Repositories"])
        let tides = try #require(FeatureRegistry.all.first { $0.id == .tides })
        #expect(tides.sidebarNodes.map(\.title) == ["Argo CD", "Flux"])
        let survey = try #require(FeatureRegistry.all.first { $0.id == .survey })
        #expect(survey.sidebarNodes.count == 4)
        #expect(chart.sidebarNodes[0].destination("c") == .chartRoom("c", .releases))
    }
}

@MainActor @Suite("SidebarCatalog")
struct SidebarCatalogTests {
    @Test func groupOrderIsFixed() {
        #expect(SidebarCatalog.groups.map(\.id) == [.overview, .workloads, .config, .network, .storage, .namespaces, .events,
                                                     .chartRoom, .tides, .survey, .accessControl, .customResources])
    }

    @Test func workloadsListsTheDesignedKindsInOrder() {
        let names = SidebarCatalog.group(.workloads).kinds.map(\.title)
        #expect(names == ["Pods", "Deployments", "DaemonSets", "StatefulSets", "ReplicaSets", "ReplicationControllers", "Jobs", "CronJobs"])
        #expect(SidebarCatalog.group(.workloads).kinds.first { $0.kind.kind == "ReplicationController" }?.onlyWhenAnyExist == true)
    }

    @Test func featureGroupsCarryNoKindsButAFeature() {
        for id in [SidebarGroupID.chartRoom, .tides, .survey] {
            let g = SidebarCatalog.group(id)
            #expect(g.kinds.isEmpty && g.feature != nil)
        }
    }

    @Test func noKindAppearsTwice() {
        let ids = SidebarCatalog.allKinds.map(\.id)
        #expect(ids.count == Set(ids).count)
    }

    @MainActor @Test func filterMatchesShortNamesAndSingularForms() {
        let model = SidebarModel(provider: FakeSidebarProvider(clusters: []), features: { [] })
        let workloads = SidebarCatalog.group(.workloads)
        model.filter = "deploy"
        #expect(model.matchingKinds(in: workloads).map(\.title) == ["Deployments"])
        model.filter = "sts"
        #expect(model.matchingKinds(in: workloads).map(\.title) == ["StatefulSets"])
        model.filter = "CronJob"
        #expect(model.matchingKinds(in: workloads).map(\.title) == ["CronJobs"])
        model.filter = ""
        #expect(model.matchingKinds(in: workloads).count == 8)
    }

    @Test func settingsPanesMatchTheDesign() {
        #expect(SettingsPane.allCases.count == 17)
        #expect(SettingsPane.allCases.first == .general && SettingsPane.allCases.last == .advanced)
    }
}
