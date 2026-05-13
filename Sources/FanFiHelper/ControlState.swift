import Foundation
import FanFiCore

/// Serial ownership of the SMC connection + active curve.
///
/// All fan reads and writes happen through this actor, so XPC method calls,
/// the periodic control loop, and shutdown cleanup never race each other.
actor ControlState {
    private let ctrl: FanController

    private var loopTask: Task<Void, Never>?
    private(set) var activePreset: String?
    private(set) var activeCurve: FanCurve?
    private(set) var activeSensor: SensorSource = .cpu
    private(set) var lastError: String?

    /// Hardware config, exposed for diagnostic logging only.
    var hardware: HardwareConfig { ctrl.config }

    init() throws {
        self.ctrl = try FanController()
    }

    // MARK: - Public API (called from FanFiHelperService)

    func applyPreset(_ name: String) async throws {
        guard let preset = CurvePreset.byName(name) else {
            throw HelperError.unknownPreset(name)
        }
        guard let curve = preset.curve else {
            // whisper = restore auto
            await stopAndRestoreInternal()
            return
        }
        startCurveInternal(curve, sensor: preset.sensor, presetName: name)
    }

    func applyCurve(_ curve: FanCurve, sensor: SensorSource) {
        startCurveInternal(curve, sensor: sensor, presetName: nil)
    }

    func restoreAuto() async {
        await stopAndRestoreInternal()
    }

    func snapshot() -> HelperStatus {
        HelperStatus(
            pid: getpid(),
            activePreset: activePreset,
            activeCurveShorthand: activeCurve?.shorthand,
            lastError: lastError
        )
    }

    // MARK: - Internal

    private func startCurveInternal(_ curve: FanCurve, sensor: SensorSource, presetName: String?) {
        loopTask?.cancel()
        activeCurve = curve
        activeSensor = sensor
        activePreset = presetName
        lastError = nil

        loopTask = Task { [weak self] in
            await self?.initialLatch(curve: curve, sensor: sensor)
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 2_000_000_000) }
                catch { break }
                await self?.tick(curve: curve, sensor: sensor)
            }
            // NB: do NOT call restoreInternal() here. Cancellation can mean
            // "switch to a different preset" — the new loop's initialLatch
            // will overwrite SMC values within milliseconds. Restoring auto
            // between presets causes a brief 0-RPM gap on M-series chassis
            // (Tg=0 + Md=0 → daemon allows fans to stop completely).
            // Explicit restore is handled by `stopAndRestoreInternal()`.
        }
    }

    private func initialLatch(curve: FanCurve, sensor: SensorSource) {
        guard let t = ctrl.readMaxTemp(source: sensor) else { return }
        let rpm = curve.rpm(at: t.celsius)
        do {
            let n = try ctrl.fanCount()
            for i in 0..<n {
                _ = try ctrl.applyManual(fan: i, rpm: rpm)
            }
        } catch {
            lastError = "\(error)"
        }
    }

    private func tick(curve: FanCurve, sensor: SensorSource) {
        guard let t = ctrl.readMaxTemp(source: sensor) else { return }
        let rpm = curve.rpm(at: t.celsius)
        if let n = try? ctrl.fanCount() {
            for i in 0..<n {
                ctrl.reassert(fan: i, rpm: rpm)
            }
        }
    }

    private func stopAndRestoreInternal() async {
        loopTask?.cancel()
        // Wait for the loop's own restore to run, so we don't race it.
        _ = await loopTask?.value
        loopTask = nil
        activePreset = nil
        activeCurve = nil
        ctrl.restoreAuto()
    }
}

enum HelperError: Error, CustomStringConvertible {
    case unknownPreset(String)
    case curveDecodeFailed(String)
    case invalidSensor(String)

    var description: String {
        switch self {
        case .unknownPreset(let n): return "unknown preset '\(n)'"
        case .curveDecodeFailed(let m): return "curve decode failed: \(m)"
        case .invalidSensor(let s): return "invalid sensor: \(s)"
        }
    }
}
