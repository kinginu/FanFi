import Foundation
import Observation
import ServiceManagement
import AppKit

/// Wraps `SMAppService.daemon(...)` registration for FanFiHelper.
///
/// The first time the user runs FanFi.app, they need to approve the helper
/// in System Settings > General > Login Items & Extensions. After that,
/// launchd keeps the helper available on demand for the lifetime of the
/// install. Uninstalling the app or calling `unregister()` removes it.
@MainActor
@Observable
final class HelperInstaller {
    /// Mirrors `SMAppService.Status` but stays Swift-friendly for UI use.
    enum InstallStatus: Equatable {
        case notRegistered
        case requiresApproval
        case enabled
        case notFound
        case error(String)

        var humanReadable: String {
            switch self {
            case .notRegistered:    return "Not installed"
            case .requiresApproval: return "Approval required"
            case .enabled:          return "Enabled"
            case .notFound:         return "Plist missing in bundle"
            case .error(let m):     return "Error: \(m)"
            }
        }
    }

    var status: InstallStatus = .notRegistered

    private let service = SMAppService.daemon(plistName: "com.fanfi.helper.plist")
    private var pollTask: Task<Void, Never>?

    init() {
        refresh()
        // Poll every 2 s so the menu bar reflects approval changes without
        // the user having to re-open the popover.
        pollTask = Task { [weak self] in
            while let self {
                self.refresh()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    func refresh() {
        switch service.status {
        case .notRegistered:    status = .notRegistered
        case .enabled:          status = .enabled
        case .requiresApproval: status = .requiresApproval
        case .notFound:         status = .notFound
        @unknown default:       status = .error("unknown SMAppService status")
        }
    }

    /// Synchronously register the daemon. Triggers macOS's approval flow on
    /// first call. Subsequent calls are idempotent.
    func install() {
        do {
            try service.register()
            refresh()
        } catch {
            status = .error(describeRegistrationError(error))
        }
    }

    /// Unregister the daemon. Removes it from the user's Login Items.
    func uninstall() async {
        do {
            try await service.unregister()
            refresh()
        } catch {
            status = .error(describeRegistrationError(error))
        }
    }

    /// Open System Settings > Login Items & Extensions so the user can flip
    /// the approval toggle.
    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    /// Provide a slightly friendlier error message — the raw NSError from
    /// ServiceManagement is hostile to non-experts.
    private func describeRegistrationError(_ error: Error) -> String {
        let ns = error as NSError
        let code = ns.code
        switch code {
        case 1:    return "registration failed (operation not permitted — code-signing issue?)"
        case 108:  return "service not found in bundle (Contents/Library/LaunchDaemons/com.fanfi.helper.plist missing?)"
        default:   return "\(ns.localizedDescription) (code \(code))"
        }
    }
}
