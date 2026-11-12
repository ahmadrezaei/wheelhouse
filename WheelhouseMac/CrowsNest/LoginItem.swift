import Foundation
import ServiceManagement
import WheelhouseDesktop

/// The "Open at login" item (DESIGN-MAC section 12, General). Behind a protocol so nothing but the shipped app ever talks to
/// ServiceManagement: development builds (the safety gate is active: Debug, Profile and local Release) and every test get
/// ``InertLoginItem``, which records the request and registers nothing. The owner's real login items are never touched.
enum LoginItemStatus: Equatable, Sendable {
    case enabled, disabled
    /// macOS wants the person to approve the item in System Settings.
    case requiresApproval
    /// Development builds and tests.
    case unavailable
}

@MainActor
protocol LoginItemService: AnyObject {
    var status: LoginItemStatus { get }
    func setEnabled(_ enabled: Bool) throws
}

/// `SMAppService.mainApp`. Constructed only by ``LoginItems/make(gateActive:)`` when the gate is off.
@MainActor
final class SMLoginItem: LoginItemService {
    private let service = SMAppService.mainApp

    var status: LoginItemStatus {
        switch service.status {
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        default: .disabled
        }
    }

    func setEnabled(_ enabled: Bool) throws {
        if enabled { try service.register() } else { try service.unregister() }
    }
}

/// Registers nothing, ever. Remembers what was asked, so the Settings pane and the tests can show it.
@MainActor
final class InertLoginItem: LoginItemService {
    private(set) var requested = false
    private(set) var requests = 0
    var status: LoginItemStatus { .unavailable }
    func setEnabled(_ enabled: Bool) throws { requested = enabled; requests += 1 }
}

enum LoginItems {
    /// The service for this process. `gateActive` is `DevSafety.isActive`; a test process (XCTest) is inert whatever the gate says.
    @MainActor
    static func make(gateActive: Bool = DevSafety.isActive, environment: [String: String] = ProcessInfo.processInfo.environment) -> any LoginItemService {
        if gateActive || environment["XCTestConfigurationFilePath"] != nil || environment["XCTestBundlePath"] != nil { return InertLoginItem() }
        return SMLoginItem()
    }
}
