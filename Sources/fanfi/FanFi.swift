import ArgumentParser
import Foundation
import Darwin
import FanFiCore

@main
struct FanFi: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "fanfi",
        abstract: "Manual fan control for Apple Silicon Macs (M1–M4+).",
        discussion: """
        Reads SMC fan keys and (with root) drives them via the agoodkind unlock
        sequence (Ftst=1, F%dMd=1, F%dTg=rpm). `set` blocks until Ctrl+C so the
        thermal daemon can't reclaim the fan; on exit it restores auto mode.
        """,
        version: "0.1.0",
        subcommands: [StatusCommand.self, SetCommand.self, CurveCommand.self, PresetCommand.self, AutoCommand.self, KeysCommand.self, HelperCommand.self],
        defaultSubcommand: StatusCommand.self
    )
}

// MARK: - status

struct StatusCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Show fans, target RPMs, and temperature sensors."
    )

    func run() throws {
        let ctrl: FanController
        do {
            ctrl = try FanController()
        } catch {
            FanFi.exit(withError: error)
        }

        let fans = try ctrl.fanStates()

        print("Fans (\(fans.count)):")
        for f in fans {
            let modeStr: String
            switch f.mode {
            case 0: modeStr = "auto"
            case 1: modeStr = "manual"
            case 3: modeStr = "system"
            default: modeStr = "unknown(\(f.mode))"
            }
            print(String(
                format: "  F%d  %5.0f RPM  target %5.0f  range %.0f–%.0f  mode=%@",
                f.index, f.actual, f.target, f.minRPM, f.maxRPM, modeStr
            ))
        }

        let temps = ctrl.temperatures()
        if !temps.isEmpty {
            print("\nTemperatures:")
            for t in temps {
                print(String(format: "  %@  %5.1f °C", t.key, t.celsius))
            }
        }

        print("\nHardware: modeKey=\(ctrl.config.modeKeyFormat)  Ftst=\(ctrl.config.ftstAvailable ? "available" : "absent")")
        if ctrl.config.ftstAvailable {
            let ftst = (try? ctrl.smc.readUInt8("Ftst")) ?? 0
            print("Ftst value = \(ftst)   (1 = unlocked; daemon suspended)")
        }
    }
}

// MARK: - set

/// Global handle for C signal handlers (which can't capture context).
final class SignalContext {
    static var current: SignalContext?
    let controller: FanController
    init(_ c: FanController) { self.controller = c }
}

private let signalHandler: @convention(c) (Int32) -> Void = { _ in
    if let ctx = SignalContext.current {
        ctx.controller.restoreAuto()
    }
    FileHandle.standardError.write(Data("\nfanfi: restored auto, exiting.\n".utf8))
    Darwin.exit(0)
}

struct SetCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "set",
        abstract: "Force a fan to a target RPM. Blocks until Ctrl+C."
    )

    @Argument(help: "Fan index (0-based; see `fanfi status`).")
    var fan: Int

    @Argument(help: "Target RPM. Hardware clamps to its own min/max.")
    var rpm: Float

    @Flag(name: .long, help: "Apply once and exit. thermalmonitord will reclaim within seconds.")
    var oneShot: Bool = false

    @Option(name: .long, help: "Polling interval seconds when holding (default 1.0).")
    var interval: Double = 1.0

    @Flag(name: .shortAndLong, help: "Print each SMC call to stderr.")
    var verbose: Bool = false

    func run() throws {
        let ctrl: FanController
        do {
            ctrl = try FanController()
        } catch {
            FanFi.exit(withError: error)
        }
        ctrl.smc.verbose = verbose

        let n = (try? ctrl.fanCount()) ?? 0
        guard fan >= 0 && fan < n else {
            FanFi.exit(withError: ValidationError("Fan index \(fan) out of range (have \(n) fans)."))
        }

        if verbose {
            FileHandle.standardError.write(Data("smc: hw probe → modeKey=\(ctrl.config.modeKeyFormat) ftstAvailable=\(ctrl.config.ftstAvailable)\n".utf8))
        }

        print("Racing daemon to set F\(fan) → \(Int(rpm)) RPM…")
        let strategy = try ctrl.applyManual(fan: fan, rpm: rpm)
        print("F\(fan) latched (strategy: \(strategy)).")

        if oneShot {
            print("--one-shot: exiting. Daemon will reclaim within ~seconds.")
            return
        }

        SignalContext.current = SignalContext(ctrl)
        signal(SIGINT, signalHandler)
        signal(SIGTERM, signalHandler)
        signal(SIGHUP, signalHandler)

        print("Holding F\(fan) at \(Int(rpm)) RPM. Press Ctrl+C to release.")
        while true {
            Thread.sleep(forTimeInterval: interval)
            ctrl.reassert(fan: fan, rpm: rpm)
        }
    }
}

// MARK: - auto

// MARK: - curve / preset (temperature-linked)

/// Shared body for curve-driven control. Holds fans until SIGINT/SIGTERM and
/// restores auto on exit. The future SwiftUI app will reuse FanCurve and
/// SensorSource directly; only this loop is CLI-specific.
private func runCurveLoop(
    ctrl: FanController,
    curve: FanCurve,
    sensor: SensorSource,
    fans: [Int],
    pollInterval: TimeInterval,
    verbose: Bool
) throws -> Never {
    func currentTarget() -> (rpm: Float, temp: Float, key: String) {
        if let t = ctrl.readMaxTemp(source: sensor) {
            return (curve.rpm(at: t.celsius), t.celsius, t.key)
        }
        // No sensors readable; use first curve point as a safe fallback.
        return (curve.points.first?.rpm ?? 0, .nan, "n/a")
    }

    let initial = currentTarget()
    print(String(format: "Initial: %@=%.1f°C → %.0f RPM (curve: %@)",
                 initial.key, initial.temp, initial.rpm, curve.shorthand))

    for fan in fans {
        _ = try ctrl.applyManual(fan: fan, rpm: initial.rpm)
    }

    SignalContext.current = SignalContext(ctrl)
    signal(SIGINT, signalHandler)
    signal(SIGTERM, signalHandler)
    signal(SIGHUP, signalHandler)

    print("Holding curve. Press Ctrl+C to release.")
    while true {
        Thread.sleep(forTimeInterval: pollInterval)
        let t = currentTarget()
        if verbose {
            FileHandle.standardError.write(Data(
                String(format: "curve: %@=%.1f°C → %.0f RPM\n", t.key, t.temp, t.rpm).utf8
            ))
        }
        for fan in fans {
            ctrl.reassert(fan: fan, rpm: t.rpm)
        }
    }
}

private func resolveFans(_ spec: String?, fanCount: Int) throws -> [Int] {
    guard let spec = spec, !spec.isEmpty else { return Array(0..<fanCount) }
    let parts = spec.split(separator: ",")
    var fans: [Int] = []
    for p in parts {
        guard let n = Int(p.trimmingCharacters(in: .whitespaces)), n >= 0, n < fanCount else {
            throw ValidationError("invalid fan index '\(p)' (must be 0..<\(fanCount))")
        }
        fans.append(n)
    }
    return fans
}

private func resolveSensor(_ spec: String?) throws -> SensorSource {
    guard let s = spec?.lowercased(), !s.isEmpty else { return .cpu }
    switch s {
    case "cpu":     return .cpu
    case "ambient": return .ambient
    case "hottest": return .hottest
    default:
        // Treat as comma-separated raw SMC keys.
        let keys = s.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
        guard keys.allSatisfy({ $0.count == 4 }) else {
            throw ValidationError("invalid sensor '\(s)' — expected 'cpu', 'ambient', 'hottest', or comma-separated 4-char SMC keys")
        }
        return .keys(keys)
    }
}

struct CurveCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "curve",
        abstract: "Run a temperature-linked fan curve. Blocks until Ctrl+C."
    )

    @Argument(help: "Curve points 'tempC:rpm,…', e.g. '40:3500,60:4500,80:6800'.")
    var spec: String

    @Option(name: .long, help: "Sensor source: cpu | ambient | hottest | comma-separated SMC keys.")
    var sensor: String?

    @Option(name: .long, help: "Comma-separated fan indices. Default: all fans.")
    var fans: String?

    @Option(name: .long, help: "Polling interval seconds (default 2.0).")
    var interval: Double = 2.0

    @Flag(name: .shortAndLong, help: "Print each tick to stderr.")
    var verbose: Bool = false

    func run() throws {
        let ctrl = try FanController()
        ctrl.smc.verbose = verbose
        let curve = try FanCurve.parse(spec)
        let source = try resolveSensor(sensor)
        let n = try ctrl.fanCount()
        let targets = try resolveFans(fans, fanCount: n)
        if verbose {
            FileHandle.standardError.write(Data(
                "smc: hw probe → modeKey=\(ctrl.config.modeKeyFormat) ftstAvailable=\(ctrl.config.ftstAvailable)  sensor=\(source.label) fans=\(targets)\n".utf8
            ))
        }
        try runCurveLoop(ctrl: ctrl, curve: curve, sensor: source,
                         fans: targets, pollInterval: interval, verbose: verbose)
    }
}

struct PresetCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "preset",
        abstract: "Apply a named preset. Blocks until Ctrl+C (except 'whisper' which is one-shot)."
    )

    @Argument(help: "Preset name: \(CurvePreset.all.map { $0.name }.joined(separator: " | ")).")
    var name: String

    @Option(name: .long, help: "Comma-separated fan indices. Default: all fans.")
    var fans: String?

    @Option(name: .long, help: "Override the sensor source: cpu | ambient | hottest | SMC keys.")
    var sensor: String?

    @Option(name: .long, help: "Polling interval seconds (default 2.0).")
    var interval: Double = 2.0

    @Flag(name: .shortAndLong, help: "Print each tick to stderr.")
    var verbose: Bool = false

    func run() throws {
        guard let preset = CurvePreset.byName(name) else {
            throw ValidationError("unknown preset '\(name)'. Available: \(CurvePreset.all.map { $0.name }.joined(separator: ", "))")
        }
        let ctrl = try FanController()
        ctrl.smc.verbose = verbose
        let n = try ctrl.fanCount()
        let targets = try resolveFans(fans, fanCount: n)
        let source = try (sensor != nil ? resolveSensor(sensor) : preset.sensor)

        // whisper = restore auto and exit.
        guard let curve = preset.curve else {
            ctrl.restoreAuto()
            print("Preset 'whisper': restored auto.")
            return
        }

        if verbose {
            FileHandle.standardError.write(Data(
                "preset=\(preset.name) curve=\(curve.shorthand) sensor=\(source.label) fans=\(targets)\n".utf8
            ))
        }
        print("Preset '\(preset.name)': \(preset.summary)")
        try runCurveLoop(ctrl: ctrl, curve: curve, sensor: source,
                         fans: targets, pollInterval: interval, verbose: verbose)
    }
}

// MARK: - helper (test driver for FanFiHelper XPC)

struct HelperCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "helper",
        abstract: "Talk to the privileged FanFiHelper daemon (XPC). Requires the helper to be installed via Resources/launchd/install-helper.sh.",
        subcommands: [HelperPingCommand.self, HelperStatusCommand.self, HelperPresetCommand.self, HelperCurveCommand.self, HelperAutoCommand.self],
        defaultSubcommand: HelperPingCommand.self
    )
}

struct HelperPingCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "ping", abstract: "Round-trip a liveness check to the helper.")

    func run() async throws {
        let client = HelperClient()
        let reply = try await client.ping()
        print(reply)
    }
}

struct HelperStatusCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "status", abstract: "Show helper-side state (active preset/curve).")

    func run() async throws {
        let client = HelperClient()
        let s = try await client.status()
        print("protocol: \(s.protocolVersion)")
        print("pid:      \(s.pid)")
        print("preset:   \(s.activePreset ?? "—")")
        print("curve:    \(s.activeCurveShorthand ?? "—")")
        if let e = s.lastError { print("error:    \(e)") }
    }
}

struct HelperPresetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "preset", abstract: "Apply a named preset via the helper.")

    @Argument(help: "Preset name: \(CurvePreset.all.map { $0.name }.joined(separator: " | ")).")
    var name: String

    func run() async throws {
        let client = HelperClient()
        try await client.applyPreset(name)
        print("applied '\(name)'")
    }
}

struct HelperCurveCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "curve", abstract: "Apply a custom curve via the helper.")

    @Argument(help: "Curve points 'tempC:rpm,…'.")
    var spec: String

    @Option(name: .long, help: "Sensor source: cpu | ambient | hottest | comma-separated SMC keys.")
    var sensor: String = "cpu"

    func run() async throws {
        let curve = try FanCurve.parse(spec)
        let source: SensorSource
        switch sensor.lowercased() {
        case "cpu": source = .cpu
        case "ambient": source = .ambient
        case "hottest": source = .hottest
        default:
            let keys = sensor.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
            source = .keys(keys)
        }
        let client = HelperClient()
        try await client.applyCurve(curve, sensor: source)
        print("applied curve \(curve.shorthand) (sensor: \(source.label))")
    }
}

struct HelperAutoCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "auto", abstract: "Tell the helper to release manual control.")

    func run() async throws {
        let client = HelperClient()
        try await client.restoreAuto()
        print("restored auto")
    }
}

// MARK: - keys

struct KeysCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "keys",
        abstract: "Enumerate SMC keys. Use --filter to grep names."
    )

    @Option(name: .long, help: "Substring filter (case-sensitive).")
    var filter: String?

    @Flag(name: .long, help: "Also read each key's size, type, raw bytes, and decoded float/sp78/ioft value.")
    var values = false

    func run() throws {
        let smc = try SMC()
        let keys = smc.enumerateKeys()
        let filtered = filter.map { f in keys.filter { $0.contains(f) } } ?? keys
        for k in filtered {
            if values {
                print(decodeLine(smc, k))
            } else {
                print(k)
            }
        }
        FileHandle.standardError.write(Data("total: \(keys.count), shown: \(filtered.count)\n".utf8))
    }

    /// "key  size  type  rawhex  flt=.. sp78=.. ioft=.." — for sensor mapping.
    private func decodeLine(_ smc: SMC, _ key: String) -> String {
        guard let info = try? smc.keyInfo(key), let raw = try? smc.read(key) else {
            return "\(key)  <unreadable>"
        }
        let typeStr = fourCCString(info.type)
        let hex = raw.map { String(format: "%02x", $0) }.joined()
        var decs: [String] = []
        if raw.count >= 4 {
            let f = raw.withUnsafeBytes { $0.loadUnaligned(as: Float.self) }
            decs.append(String(format: "flt=%.2f", f))
        }
        if raw.count >= 2 {
            // sp78: signed 8.8 fixed point, big-endian.
            let i = Int16(bitPattern: (UInt16(raw[0]) << 8) | UInt16(raw[1]))
            decs.append(String(format: "sp78=%.2f", Float(i) / 256.0))
            // ioft: unsigned fixed point, big-endian, fractional bits = (size*8 - intbits).
            // Apple Silicon temps commonly use ioft with 16 fractional bits over 4 bytes,
            // but 2-byte variants exist; show the 8.8 reading as a probe.
            let u = (UInt16(raw[0]) << 8) | UInt16(raw[1])
            decs.append(String(format: "u8.8=%.2f", Float(u) / 256.0))
        }
        return "\(key)  size=\(info.size)  type=\(typeStr)  raw=\(hex)  \(decs.joined(separator: " "))"
    }

    private func fourCCString(_ v: UInt32) -> String {
        let b: [UInt8] = [UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF),
                          UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
        return String(bytes: b, encoding: .ascii)?.replacingOccurrences(of: "\0", with: " ") ?? "????"
    }
}

struct AutoCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "auto",
        abstract: "Restore all fans to auto and clear Ftst. Use as recovery."
    )

    func run() throws {
        let ctrl: FanController
        do {
            ctrl = try FanController()
        } catch {
            FanFi.exit(withError: error)
        }
        ctrl.restoreAuto()
        print("All fans → auto, Ftst=0.")
    }
}
