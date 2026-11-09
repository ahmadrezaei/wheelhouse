#if WH_TEST_HOOKS
import Foundation
import WheelhouseDesktop

/// Development-only hook, compiled ONLY under `WH_TEST_HOOKS` (the Debug configuration): a confirmer that approves every held request, so
/// a headless run can exercise Production holds without a person. Profile, Release and Distribution contain none of this:
/// `scripts/mac-entitlement-check.sh` fails any non-Debug binary that has a `GangwayTestHooks` or `autoApprove` symbol or the launch-argument
/// literal below. It is honoured only while the safety gate is active (always true in Debug).
enum GangwayTestHooks {
    static let launchArgument = "-WHGangwayAutoApprove"

    struct AutoApprover: GangwayConfirming {
        func confirm(_ sheet: GangwaySheet) async -> Bool { true }
    }

    static func autoApprove() -> any GangwayConfirming { AutoApprover() }

    static func confirmerIfRequested() -> (any GangwayConfirming)? {
        guard DevSafety.isActive, ProcessInfo.processInfo.arguments.contains(launchArgument) else { return nil }
        return autoApprove()
    }
}
#endif
