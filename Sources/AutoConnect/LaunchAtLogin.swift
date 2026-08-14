import Foundation
import ServiceManagement

/// Registers the app as a login item through `SMAppService`.
///
/// The modern API needs no helper bundle and no user trip to System Settings, but it does report
/// state the caller has to respect: `.requiresApproval` means macOS is waiting for the user to
/// allow it in Login Items, and no amount of re-registering will change that.
@MainActor
enum LaunchAtLogin {

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// True when macOS has the registration but the user has not approved it yet.
    static var needsApproval: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }

    /// Turns the login item on or off. Returns an explanation when it could not be done, so the UI
    /// can say why instead of silently reverting a switch the user just flipped.
    static func set(_ enabled: Bool) -> String? {
        do {
            if enabled {
                try SMAppService.mainApp.register()
                if needsApproval {
                    return "Allow MacAuth in System Settings, Login Items, to finish enabling this."
                }
            } else {
                try SMAppService.mainApp.unregister()
            }
            return nil
        } catch {
            return "Could not change the login item: \(error.localizedDescription)"
        }
    }
}
