import Foundation
import Observation
import FanFiCore

/// UI-side enum of the four buttons in the menu bar.
/// Maps to `CurvePreset` names in `FanFiCore` so the helper can execute them.
enum MenuPreset: String, CaseIterable, Identifiable, Sendable {
    case auto  = "auto"      // restore daemon control (helper.restoreAuto)
    case quiet = "quiet"     // CurvePreset.quiet
    case boost = "boost"     // CurvePreset.boost
    case full  = "full"      // CurvePreset.fullBlast

    var id: String { rawValue }

    var label: String {
        switch self {
        case .auto:  return "Auto"
        case .quiet: return "Quiet"
        case .boost: return "Boost"
        case .full:  return "Full"
        }
    }

    var icon: String {
        switch self {
        case .auto:  return "applelogo"
        case .quiet: return "leaf"
        case .boost: return "flame"
        case .full:  return "tornado"
        }
    }
}

/// Bridges the menu bar buttons to the privileged `FanFiHelper` over XPC.
///
/// The helper is installed once via `Resources/launchd/install-helper.sh` (or
/// `SMAppService` in Phase 3) and lives as a root LaunchDaemon. The app talks
/// to it via `HelperClient` — no sudo prompts, no subprocess spawning.
@MainActor
@Observable
final class PresetController {
    enum Status: Sendable, Equatable {
        case idle                       // helper reachable, no preset active
        case applying(MenuPreset)
        case running(MenuPreset)
        case helperUnreachable(String)  // helper not installed or XPC error
        case error(String)
    }

    var status: Status = .idle
    /// Best-effort "active" preset for UI highlighting.
    var active: MenuPreset = .auto
    /// Latest helper-side snapshot. Populated by `refreshStatus()`.
    var helperSnapshot: HelperStatus?

    nonisolated private let client = HelperClient()

    init() {
        // Poll helper state so the UI tracks `active preset` even if changed
        // via the CLI. 2 s is a fine cadence; the poll itself is cheap.
        Task { [weak self] in
            while let self {
                await self.refreshStatus()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    /// Poll the helper for current state. Called periodically by the UI.
    func refreshStatus() async {
        do {
            let snap = try await client.status()
            helperSnapshot = snap
            // Reconcile UI active state with helper-reported active preset.
            if let preset = snap.activePreset, let menu = MenuPreset(rawValue: preset) {
                active = menu
                if case .applying = status { /* keep applying */ } else { status = .running(menu) }
            } else if case .applying = status {
                // still in flight
            } else {
                active = .auto
                status = .idle
            }
        } catch let err as HelperClient.ClientError {
            helperSnapshot = nil
            status = .helperUnreachable(err.description)
        } catch {
            helperSnapshot = nil
            status = .helperUnreachable("\(error)")
        }
    }

    /// Apply a preset. Non-blocking; observe `status` for progress.
    func apply(_ preset: MenuPreset) {
        if case .applying = status { return }
        status = .applying(preset)
        let client = self.client
        Task { [weak self] in
            do {
                if preset == .auto {
                    try await client.restoreAuto()
                } else {
                    try await client.applyPreset(preset.rawValue)
                }
                guard let self else { return }
                self.active = preset
                self.status = preset == .auto ? .idle : .running(preset)
                await self.refreshStatus()
            } catch let err as HelperClient.ClientError {
                guard let self else { return }
                self.status = .helperUnreachable(err.description)
            } catch {
                guard let self else { return }
                self.status = .error("\(error)")
            }
        }
    }

    /// Synchronous restore on app quit. Blocks the main thread briefly so the
    /// helper actually processes the message before we exit.
    nonisolated func restoreOnQuitSync(timeout: TimeInterval = 2.0) {
        let sem = DispatchSemaphore(value: 0)
        Task {
            try? await client.restoreAuto()
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + timeout)
    }
}
