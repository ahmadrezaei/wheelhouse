import SwiftUI
import WheelhouseKit
import WheelhouseUI

/// Decides between onboarding and the shell, and layers global banners.
/// The lock screen and the privacy cover are NOT part of this view: they live in `LockWindowManager`'s overlay windows,
/// which sit above sheets and cover every scene.
struct RootView: View {
    @Environment(ClusterRegistry.self) private var registry
    @Environment(AppPreferences.self) private var preferences
    @Environment(AppRouter.self) private var router
    @Environment(AppLockController.self) private var lock
    @Environment(NetworkMonitor.self) private var network
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        @Bindable var router = router
        ZStack {
            if registry.clusters.isEmpty && !registry.isDemoMode {
                WelcomeView()
            } else {
                shell
            }
        }
        .sheet(item: $router.sheet) {
            SheetRouteView(route: $0.route)
                .environment(registry).environment(preferences).environment(router).environment(lock).environment(network)
        }
        .onChange(of: sizeClass, initial: true) { _, new in router.isCompact = (new != .regular) }
    }

    @ViewBuilder private var shell: some View {
        Group {
            if sizeClass == .regular { PadShell() } else { PhoneShell() }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if network.isOffline { StateBanner(.offline).padding(.horizontal, Spacing.l).padding(.top, 4) }
        }
    }
}
