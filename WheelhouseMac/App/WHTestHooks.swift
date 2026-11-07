#if WH_TEST_HOOKS
import Foundation
import WheelhouseDesktop
import WheelhouseUI

/// Development-only test hooks, compiled ONLY under `WH_TEST_HOOKS` (the Debug configuration). Profile, Release and Distribution
/// contain none of this: `scripts/mac-entitlement-check.sh` fails any non-Debug binary that has a `WHTestHook` symbol.
enum WHTestHooks {
    /// UI tests must type into the hardened confirmation field, whose input is otherwise hardware-only. Launch argument
    /// `-WHTestHooksSyntheticInput` allows synthetic key events, and only while the safety gate is active.
    @MainActor static func installIfRequested() {
        guard DevSafety.isActive, ProcessInfo.processInfo.arguments.contains("-WHTestHooksSyntheticInput") else { return }
        ConfirmationFieldInputPolicy.shared.allowSyntheticInput()
    }
}
#endif
