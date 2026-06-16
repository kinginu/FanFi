import Foundation

public struct FanState: Sendable, Hashable {
    public let index: Int
    public let actual: Float
    public let target: Float
    public let minRPM: Float
    public let maxRPM: Float
    public let mode: UInt8  // 0 = auto, 1 = manual, 3 = system

    public init(index: Int, actual: Float, target: Float, minRPM: Float, maxRPM: Float, mode: UInt8) {
        self.index = index
        self.actual = actual
        self.target = target
        self.minRPM = minRPM
        self.maxRPM = maxRPM
        self.mode = mode
    }

    public var modeLabel: String {
        switch mode {
        case 0: return "auto"
        case 1: return "manual"
        case 3: return "system"
        default: return "unknown(\(mode))"
        }
    }
}

public struct TempReading: Sendable, Hashable {
    public let key: String
    public let celsius: Float

    public init(key: String, celsius: Float) {
        self.key = key
        self.celsius = celsius
    }
}

/// A human-named temperature aggregated from one or more raw SMC keys.
/// `sampleCount` is how many of the group's keys were in-band this read — a
/// CPU group on Apple Silicon exposes dozens of redundant per-core sensors,
/// half of which power-gate to ~0 °C at any instant, so the count fluctuates.
public struct NamedTemp: Sendable, Hashable {
    public let name: String
    public let celsius: Float
    public let sampleCount: Int

    public init(name: String, celsius: Float, sampleCount: Int) {
        self.name = name
        self.celsius = celsius
        self.sampleCount = sampleCount
    }
}

/// A curated display sensor: a friendly name and the SMC keys it averages.
/// CPU/GPU key lists are discovered per-chip at runtime (see
/// `FanController.displaySensorGroups()`); the rest are fixed, high-confidence
/// keys verified against Mac Fan Control on M2 Pro (Mac14,9).
public struct SensorGroup: Sendable, Hashable {
    public let name: String
    public let keys: [String]
    /// When true, average only readings within `hotClusterBand` °C of the
    /// group's hottest sensor. Apple exposes two sensors per GPU core (a ~39 °C
    /// and a ~45 °C probe); a plain mean lands between them, ~4 °C below what
    /// Mac Fan Control reports for "GPU Cluster". Biasing to the hot cluster
    /// matches MFC and is still stable. CPU cores don't need this — their full
    /// mean already equals MFC's "CPU Core Average".
    public let hotClusterOnly: Bool

    public init(name: String, keys: [String], hotClusterOnly: Bool = false) {
        self.name = name
        self.keys = keys
        self.hotClusterOnly = hotClusterOnly
    }
}

/// Hardware-specific key configuration probed at startup.
/// On M-series chips the mode key casing differs (F%dmd vs F%dMd), and
/// Ftst may or may not be exposed.
public struct HardwareConfig: Sendable, Hashable {
    public let modeKeyFormat: String   // "F%dmd" or "F%dMd"
    public let ftstAvailable: Bool

    public init(modeKeyFormat: String, ftstAvailable: Bool) {
        self.modeKeyFormat = modeKeyFormat
        self.ftstAvailable = ftstAvailable
    }
}

private let tempKeyCandidates: [String] = [
    "TC0P", "TC0E", "TC0F",
    "TG0P", "TG0D",
    "Th0H", "Th1H", "Th2H",
    "Ts0S", "Ts1S",
    "Tp01", "Tp05", "Tp09", "Tp0D",
    "Tp0X", "Tp0b",
    "Tg05", "Tg0D",
    "TaLP", "TaRF",
]

public final class FanController {
    public let smc: SMC
    public let config: HardwareConfig

    public init() throws {
        let smc = try SMC()
        self.smc = smc
        self.config = Self.detectHardware(smc)
    }

    private static func detectHardware(_ smc: SMC) -> HardwareConfig {
        var modeKey = "F%dmd"
        for candidate in ["F%dmd", "F%dMd"] {
            let probe = String(format: candidate, 0)
            if let data = try? smc.read(probe), !data.isEmpty {
                modeKey = candidate
                break
            }
        }
        let ftst = ((try? smc.read("Ftst").count) ?? 0) > 0
        return HardwareConfig(modeKeyFormat: modeKey, ftstAvailable: ftst)
    }

    private func modeKey(_ fan: Int) -> String {
        String(format: config.modeKeyFormat, fan)
    }

    // MARK: - Read

    public func fanCount() throws -> Int {
        Int(try smc.readUInt8("FNum"))
    }

    public func fanStates() throws -> [FanState] {
        let n = try fanCount()
        var out: [FanState] = []
        for i in 0..<n {
            let ac = (try? smc.readFloat32("F\(i)Ac")) ?? 0
            let tg = (try? smc.readFloat32("F\(i)Tg")) ?? 0
            let mn = (try? smc.readFloat32("F\(i)Mn")) ?? 0
            let mx = (try? smc.readFloat32("F\(i)Mx")) ?? 0
            let md = (try? smc.readUInt8(modeKey(i))) ?? 0
            out.append(FanState(index: i, actual: ac, target: tg, minRPM: mn, maxRPM: mx, mode: md))
        }
        return out
    }

    public func temperatures() -> [TempReading] {
        var out: [TempReading] = []
        for key in tempKeyCandidates {
            if let t = try? smc.readFloat32(key), t > 5, t < 150 {
                out.append(TempReading(key: key, celsius: t))
            }
        }
        return out
    }

    /// Maximum reading among the source's candidate keys. Returns nil if no
    /// sensor returns a plausible value.
    ///
    /// Band starts at 10 °C, not 5: Apple-Silicon per-core sensors pin to
    /// ~0-8 °C when the core is power-gated. `> 5` used to let those through
    /// and made curves evaluate against a phantom-cold CPU.
    public func readMaxTemp(source: SensorSource) -> (key: String, celsius: Float)? {
        var best: (String, Float)?
        for key in source.candidateKeys {
            guard let t = try? smc.readFloat32(key), t > 10, t < 150 else { continue }
            if best == nil || t > best!.1 { best = (key, t) }
        }
        return best
    }

    // MARK: - Named display sensors

    /// Build the curated, friendly-named sensor groups for the popover /
    /// menu bar. Enumerates SMC keys once to discover this chip's CPU-core
    /// (`Tp*`) and GPU (`Tg*`) sensors — these differ by generation, so we
    /// resolve them at runtime rather than hard-coding an M2-specific list.
    /// Call once at startup; it's a full ~2300-key scan.
    public func displaySensorGroups() -> [SensorGroup] {
        let all = smc.enumerateKeys()
        // Lowercase 'p'/'g' is deliberate: it selects the per-core CPU and GPU
        // cluster sensors while excluding unrelated families like `TPMP`/`TPSP`
        // (PMIC) and `TG0D` (GPU proximity, uppercase).
        let cpu = all.filter { $0.hasPrefix("Tp") }.sorted()
        let gpu = all.filter { $0.hasPrefix("Tg") }.sorted()
        var groups: [SensorGroup] = []
        if !cpu.isEmpty { groups.append(SensorGroup(name: "CPU", keys: cpu)) }
        if !gpu.isEmpty { groups.append(SensorGroup(name: "GPU", keys: gpu, hotClusterOnly: true)) }
        groups.append(SensorGroup(name: "Airflow L", keys: ["TaLP"]))
        groups.append(SensorGroup(name: "Airflow R", keys: ["TaRF"]))
        groups.append(SensorGroup(name: "Battery",   keys: ["TB0T", "TB1T", "TB2T"]))
        groups.append(SensorGroup(name: "Airport",   keys: ["TW0P"]))
        return groups
    }

    private static let hotClusterBand: Float = 5

    /// Mean of a group's in-band readings. Excludes power-gated cores that pin
    /// near 0 °C (band starts at 10 °C). When `hotClusterOnly`, first drops
    /// readings more than `hotClusterBand` °C below the group max (used for GPU,
    /// where each core exposes a hot + cold probe). Returns nil if nothing is
    /// in band.
    public func averageTemp(keys: [String],
                            band: ClosedRange<Float> = 10...120,
                            hotClusterOnly: Bool = false) -> (celsius: Float, count: Int)? {
        var vals: [Float] = []
        for k in keys {
            if let t = try? smc.readFloat32(k), band.contains(t) { vals.append(t) }
        }
        if hotClusterOnly, let hi = vals.max() {
            vals = vals.filter { $0 >= hi - Self.hotClusterBand }
        }
        guard !vals.isEmpty else { return nil }
        return (vals.reduce(0, +) / Float(vals.count), vals.count)
    }

    /// Averaged readings for the given groups, in order. Groups with no in-band
    /// sensor this tick are dropped.
    public func namedTemperatures(_ groups: [SensorGroup]) -> [NamedTemp] {
        groups.compactMap { g in
            guard let r = averageTemp(keys: g.keys, hotClusterOnly: g.hotClusterOnly) else { return nil }
            return NamedTemp(name: g.name, celsius: r.celsius, sampleCount: r.count)
        }
    }

    // MARK: - Write / unlock

    public enum UnlockStrategy: Sendable { case direct, ftst }

    /// Force fan into manual mode with the given target.
    ///
    /// On Macs with Ftst (M1–M3 era): writes Ftst=1 to suspend `thermalmonitord`,
    /// then sets F%dMd=1 and F%dTg=rpm. Daemon stays parked.
    ///
    /// On Macs without Ftst (M4 era and macOS 26+): there's no firmware-level
    /// suspend, so we race the daemon. Each iteration writes both Md=1 and
    /// Tg=rpm; we exit as soon as a readback observes Md=1. The hold loop in
    /// SetCommand keeps re-asserting after this.
    @discardableResult
    public func applyManual(fan: Int, rpm: Float, timeout: TimeInterval = 3.0) throws -> UnlockStrategy {
        let mk = modeKey(fan)
        let tk = "F\(fan)Tg"

        // Plan A: direct write race.
        do {
            try race(modeKey: mk, targetKey: tk, rpm: rpm, timeout: timeout)
            return .direct
        } catch {
            if !config.ftstAvailable { throw error }
        }

        // Plan B: Ftst unlock.
        try smc.writeUInt8("Ftst", 1)
        Thread.sleep(forTimeInterval: 0.5)
        try race(modeKey: mk, targetKey: tk, rpm: rpm, timeout: 10.0)
        return .ftst
    }

    /// Write Md=1 and Tg=rpm repeatedly until we observe Md=1 on readback, or timeout.
    private func race(modeKey mk: String, targetKey tk: String, rpm: Float, timeout: TimeInterval) throws {
        let deadline = Date().addingTimeInterval(timeout)
        var lastError: Error?
        while Date() < deadline {
            do {
                try smc.writeUInt8(mk, 1)
                try smc.writeFloat32(tk, rpm)
            } catch { lastError = error }
            Thread.sleep(forTimeInterval: 0.05)
            if (try? smc.readUInt8(mk)) == 1 { return }
        }
        throw lastError ?? SMCError.firmware(SMCResultCode.badCommand.rawValue)
    }

    /// Re-assert manual mode and target if daemon reclaimed.
    public func reassert(fan: Int, rpm: Float) {
        let mk = modeKey(fan)
        if let md = try? smc.readUInt8(mk), md != 1 {
            if config.ftstAvailable {
                _ = try? smc.writeUInt8("Ftst", 1)
            }
            _ = try? smc.writeUInt8(mk, 1)
            _ = try? smc.writeFloat32("F\(fan)Tg", rpm)
        }
    }

    /// Hand control back to `thermalmonitord` ("Auto" = Mac's normal fan policy).
    ///
    /// Just writes `F%dMd = 0`. The firmware briefly retains the last manual
    /// `F%dTg`, then the daemon overwrites it within its next polling cycle
    /// (~1 s typical). This avoids the visible 0-RPM dip you'd get if we
    /// explicitly zeroed `F%dTg` ourselves.
    ///
    /// `Ftst=0` clears the diagnostic flag on Macs that have it (M1–M3 era).
    /// On Ftst-absent hardware (M4+/macOS 26) this is a no-op.
    public func restoreAuto() {
        let n = (try? fanCount()) ?? 4
        for i in 0..<n {
            _ = try? smc.writeUInt8(modeKey(i), 0)
        }
        if config.ftstAvailable {
            _ = try? smc.writeUInt8("Ftst", 0)
        }
    }
}
