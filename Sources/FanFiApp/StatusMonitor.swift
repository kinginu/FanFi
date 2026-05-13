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

    /// History samples retained. 600 samples × 1 s = 10 minutes.
    private let historyLimit = 600

    init() { startPolling() }

    func startPolling() {
        do {
            controller = try FanController()
            hardware = controller?.config
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

        let now = Date()
        let avgRpm = fans.isEmpty ? 0 : fans.map { $0.actual }.reduce(0, +) / Float(fans.count)
        let avgTgt = fans.isEmpty ? 0 : fans.map { $0.target }.reduce(0, +) / Float(fans.count)
        let maxTemp = temps.map { $0.celsius }.max() ?? 0
        rpmHistory.append(TimedSample(date: now, value: avgRpm))
        targetHistory.append(TimedSample(date: now, value: avgTgt))
        tempHistory.append(TimedSample(date: now, value: maxTemp))
        if rpmHistory.count    > historyLimit { rpmHistory.removeFirst(rpmHistory.count       - historyLimit) }
        if targetHistory.count > historyLimit { targetHistory.removeFirst(targetHistory.count - historyLimit) }
        if tempHistory.count   > historyLimit { tempHistory.removeFirst(tempHistory.count     - historyLimit) }
    }

    var hottestSensor: TempReading? {
        temps.max(by: { $0.celsius < $1.celsius })
    }

    var averageFanRPM: Float {
        fans.isEmpty ? 0 : fans.map { $0.actual }.reduce(0, +) / Float(fans.count)
    }
}
