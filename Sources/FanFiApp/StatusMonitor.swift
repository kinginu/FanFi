import Foundation
import Observation
import FanFiCore

/// Live fan/temperature state for the menu bar UI.
/// All mutation happens on the main actor; the SMC reads are blocking but
/// fast (~1 ms per key), so we just do them on @MainActor for v0 simplicity.
/// If polling ever shows up in Instruments, hop reads to a detached Task.
@MainActor
@Observable
final class StatusMonitor {
    var fans: [FanState] = []
    var temps: [TempReading] = []
    /// Curated, friendly-named sensor readings shown in the popover.
    var displayTemps: [NamedTemp] = []
    /// Averaged CPU-core temperature, updated every poll. Drives the popover
    /// and the history chart.
    var cpuTemp: Float?
    /// Throttled copy of `cpuTemp` for the menu-bar chip. Updated at half the
    /// poll rate so the number doesn't churn every second.
    var menuBarTemp: Float?
    var hardware: HardwareConfig?
    var initError: String?

    var rpmHistory: [TimedSample] = []
    var targetHistory: [TimedSample] = []
    var tempHistory: [TimedSample] = []

    struct TimedSample: Identifiable, Hashable {
        var id: Date { date }
        let date: Date
        let value: Float
    }

    private var controller: FanController?
    private var pollTask: Task<Void, Never>?
    /// Resolved once at startup — the per-chip CPU/GPU key lists are discovered
    /// via a full SMC key scan, too expensive to repeat every tick.
    private var sensorGroups: [SensorGroup] = []
    private var tickCount = 0
    /// Refresh the menu-bar chip every Nth poll (2 → every 2 s at a 1 s poll).
    private let menuBarStride = 2

    /// History samples retained. 600 samples × 1 s = 10 minutes.
    private let historyLimit = 600

    init() { startPolling() }

    func startPolling() {
        do {
            controller = try FanController()
            hardware = controller?.config
            sensorGroups = controller?.displaySensorGroups() ?? []
        } catch {
            initError = "\(error)"
            return
        }
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.tick()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    // No deinit: StatusMonitor lives for the whole app process; the polling
    // task holds [weak self] so it no-ops if we ever do tear it down before
    // process exit.

    private func tick() {
        guard let controller else { return }
        if let states = try? controller.fanStates() { fans = states }
        temps = controller.temperatures()
        displayTemps = controller.namedTemperatures(sensorGroups)
        // The CPU's per-core sensors can ALL power-gate on the same tick, so
        // `averageTemp` occasionally yields no CPU reading. Hold the last good
        // value instead of letting it (and the menu-bar number) blink out —
        // a vanishing digit changes the chip width and reads as a flicker.
        if let cpu = displayTemps.first(where: { $0.name == "CPU" })?.celsius {
            cpuTemp = cpu
        } else if let last = cpuTemp {
            displayTemps.insert(NamedTemp(name: "CPU", celsius: last, sampleCount: 0), at: 0)
        }
        // Update the menu-bar number at half the poll rate (first reading shows
        // immediately so the chip isn't blank on launch).
        tickCount += 1
        if menuBarTemp == nil || tickCount % menuBarStride == 0 {
            menuBarTemp = cpuTemp
        }

        let now = Date()
        let avgRpm = fans.isEmpty ? 0 : fans.map { $0.actual }.reduce(0, +) / Float(fans.count)
        let avgTgt = fans.isEmpty ? 0 : fans.map { $0.target }.reduce(0, +) / Float(fans.count)
        // History tracks the same CPU value the menu bar shows, so the
        // sparkline and the chip agree.
        let histTemp = cpuTemp ?? temps.map { $0.celsius }.max() ?? 0
        rpmHistory.append(TimedSample(date: now, value: avgRpm))
        targetHistory.append(TimedSample(date: now, value: avgTgt))
        tempHistory.append(TimedSample(date: now, value: histTemp))
        if rpmHistory.count    > historyLimit { rpmHistory.removeFirst(rpmHistory.count       - historyLimit) }
        if targetHistory.count > historyLimit { targetHistory.removeFirst(targetHistory.count - historyLimit) }
        if tempHistory.count   > historyLimit { tempHistory.removeFirst(tempHistory.count     - historyLimit) }
    }

    var averageFanRPM: Float {
        fans.isEmpty ? 0 : fans.map { $0.actual }.reduce(0, +) / Float(fans.count)
    }
}
