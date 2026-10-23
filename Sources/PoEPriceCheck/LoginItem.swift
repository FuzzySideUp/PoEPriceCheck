import Foundation
import ServiceManagement

/// "Open at Login": registers the app with macOS as a login item (System Settings › General › Login Items).
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    /// Turns the login item on or off and remembers the choice, so a reinstalled copy re-registers itself.
    static func set(_ on: Bool) {
        Settings.openAtLogin = on
        do {
            if on, !isEnabled { try SMAppService.mainApp.register() }
            if !on, SMAppService.mainApp.status != .notRegistered { try SMAppService.mainApp.unregister() }
        } catch {
            Log.info("login item \(on ? "register" : "unregister") failed: \(error)")
        }
        Log.info("login item: \(statusText)")
    }

    /// At launch: keep macOS in step with the setting (a rebuilt or moved app can drop its registration).
    static func sync() {
        if Settings.openAtLogin, !isEnabled { set(true) }
    }

    static var statusText: String {
        switch SMAppService.mainApp.status {
        case .enabled: return "enabled"
        case .requiresApproval: return "needs approval in System Settings › Login Items"
        case .notRegistered: return "off"
        case .notFound: return "not found"
        @unknown default: return "unknown"
        }
    }
}
