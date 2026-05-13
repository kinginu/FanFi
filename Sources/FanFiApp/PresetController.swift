import Foundation
import Observation
import FanFiCore

/// UI-side enum of the four buttons in the menu bar.
/// Maps to `CurvePreset` names in `FanFiCore` so the helper can execute them.
enum MenuPreset: String, CaseIterable, Identifiable, Sendable {
    case auto   = "auto"      // restore daemon control (helper.restoreAuto)
    case quiet  = "quiet"     // CurvePreset.quiet
    case boost  = "boost"     // CurvePreset.boost
    case full   = "full"      // CurvePreset.fullBlast
    case manual = "manual"    // CurvePreset.manual (user-tunable curve)

    var id: String { rawValue }

    var label: String {
        switch self {
        case .auto:   return "Auto"
        case .quiet:  return "Quiet"
        case .boost:  return "Boost"
        case .full:   return "Full"
        case .manual: return "Manual"
        }
    }

    var icon: String {
        switch self {
        case .auto:   return "applelogo"
        case .quiet:  return "leaf"
        case .boost:  return "flame"
        case .full:   return "tornado"
        case .manual: return "slider.horizontal.3"
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
    /// User-editable curve for the Manual preset. Persisted in
    /// UserDefaults; restored at app launch.
    var manualCurve: FanCurve = CurvePreset.manual.curve!

    nonisolated private let client = HelperClient()
    private static let manualCurveDefaultsKey = "fanfi.manualCurve.v1"

    init() {
        // Restore the Manual curve from UserDefaults if the user edited it
        // in a previous session.
        if let data = UserDefaults.standard.data(forKey: Self.manualCurveDefaultsKey),
           let saved = try? JSONDecoder().decode(FanCurve.self, from: data) {
            self.manualCurve = saved
        }

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
            // Reconcile UI active state with helper-reported state.
            if let preset = snap.activePreset, let menu = MenuPreset(rawValue: preset) {
                // Helper reports a named preset.
                active = menu
                if case .applying = status { /* keep applying */ } else { status = .running(menu) }
            } else if snap.activeCurveShorthand != nil {
                // A custom curve is running with no preset name attached.
                // That's how the app applies Manual (via applyCurve). Keep
                // whatever `active` we set when the user clicked the button
                // — usually .manual — rather than reverting to .auto.
                if case .applying = status {
                    /* keep applying */
                } else if case .error = status {
                    /* keep error */
                } else {
                    status = .running(active)
                }
            } else if case .applying = status {
                // applying, helper hasn't acknowledged yet
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
        let manualCurve = self.manualCurve
        Task { [weak self] in
            do {
                switch preset {
                case .auto:
                    try await client.restoreAuto()
                case .manual:
                    // Send the user-edited curve directly so the helper runs
                    // whatever has been dragged in the UI, not the hardcoded
                    // FanFiCore default.
                    try await client.applyCurve(manualCurve, sensor: .cpu)
                default:
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

    /// Update the RPM at a fixed point in the Manual curve, persist it, and
    /// (if Manual is currently active) push the new curve to the helper.
    func setManualRPM(at index: Int, rpm: Float) {
        guard index >= 0 && index < manualCurve.points.count else { return }
        let clamped = max(0, min(7000, rpm))
        var pts = manualCurve.points
        guard pts[index].rpm != clamped else { return }
        pts[index].rpm = clamped
        manualCurve = FanCurve(points: pts)
        if let data = try? JSONEncoder().encode(manualCurve) {
            UserDefaults.standard.set(data, forKey: Self.manualCurveDefaultsKey)
        }
        if active == .manual {
            let curve = manualCurve
            let client = self.client
            Task { try? await client.applyCurve(curve, sensor: .cpu) }
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
