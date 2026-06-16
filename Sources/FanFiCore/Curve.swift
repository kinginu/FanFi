import Foundation

// MARK: - Fan curve
//
// A piecewise-linear mapping from temperature (°C) to fan RPM.
//
// Designed to be shared verbatim with the SwiftUI app:
//   * `Codable` so curves can persist as JSON in
//     ~/Library/Application Support/FanFi/ or sync via XPC payloads.
//   * `Hashable` for SwiftUI list identity.
//   * Pure evaluation (no I/O) so previews and unit tests are trivial.
//
// Points are kept sorted by temperature on construction; evaluation clamps
// outside the defined range. Endpoints behave like horizontal lines.

public struct FanCurve: Codable, Hashable, Sendable {
    public struct Point: Codable, Hashable, Sendable {
        public var tempC: Float
        public var rpm: Float

        public init(tempC: Float, rpm: Float) {
            self.tempC = tempC
            self.rpm = rpm
        }
    }

    /// Sorted ascending by `tempC`. Always non-empty.
    public private(set) var points: [Point]

    public init(points: [Point]) {
        precondition(!points.isEmpty, "FanCurve requires at least one point")
        self.points = points.sorted { $0.tempC < $1.tempC }
    }

    public init(_ shorthand: [(Float, Float)]) {
        self.init(points: shorthand.map { Point(tempC: $0.0, rpm: $0.1) })
    }

    /// Evaluate the curve at `tempC`. Linear interpolation between adjacent
    /// points; clamps to the first/last RPM outside the defined range.
    public func rpm(at tempC: Float) -> Float {
        if tempC <= points.first!.tempC { return points.first!.rpm }
        if tempC >= points.last!.tempC  { return points.last!.rpm }
        for i in 1..<points.count {
            let a = points[i - 1], b = points[i]
            if tempC <= b.tempC {
                let t = (tempC - a.tempC) / (b.tempC - a.tempC)
                return a.rpm + (b.rpm - a.rpm) * t
            }
        }
        return points.last!.rpm
    }

    // MARK: Shorthand parser
    //
    // `"40:3500,60:4500,80:6800"` → curve. Used by the CLI; the GUI editor
    // will build curves directly, but the same string form is round-trippable
    // for sharing/import.

    public static func parse(_ s: String) throws -> FanCurve {
        let parts = s.split(separator: ",")
        guard !parts.isEmpty else { throw CurveParseError.empty }
        var pts: [Point] = []
        for p in parts {
            let kv = p.split(separator: ":")
            guard kv.count == 2,
                  let t = Float(kv[0].trimmingCharacters(in: .whitespaces)),
                  let r = Float(kv[1].trimmingCharacters(in: .whitespaces))
            else { throw CurveParseError.invalidPoint(String(p)) }
            pts.append(Point(tempC: t, rpm: r))
        }
        return FanCurve(points: pts)
    }

    public var shorthand: String {
        points.map { "\(Int($0.tempC)):\(Int($0.rpm))" }.joined(separator: ",")
    }
}

public enum CurveParseError: Error, CustomStringConvertible, Sendable {
    case empty
    case invalidPoint(String)
    public var description: String {
        switch self {
        case .empty: return "curve string is empty"
        case .invalidPoint(let p): return "invalid curve point: '\(p)' (expected 'tempC:rpm')"
        }
    }
}

// MARK: - Sensor source
//
// Curves run against a *scalar* temperature derived from one or more sensors.
// The GUI will let the user choose a named source or pick raw keys; the CLI
// exposes the same enumeration.

public enum SensorSource: Codable, Hashable, Sendable {
    /// Hottest CPU-core sensor. The control loop takes the *max* over the
    /// `Tp*` core cluster so the curve reacts to the hottest core under load.
    ///
    /// Note: Apple Silicon exposes redundant per-core sensors that power-gate
    /// to ~0-8 °C when their core is parked — `readMaxTemp`'s 10 °C floor
    /// filters those out so the max lands on a live core. (The earlier list,
    /// `Tp01/05/09/0D/0X/0b`, happened to be exactly the gate-prone sub-keys,
    /// so curves often saw a phantom-cold CPU and never ramped.)
    case cpu
    /// Hottest of ambient/chassis sensors (TaLP/TaRF). Best proxy for
    /// palm-rest temperature on MacBook Pro chassis.
    case ambient
    /// Hottest of all known temperature keys.
    case hottest
    /// Explicit list of SMC keys. The hottest reading wins.
    case keys([String])

    public var candidateKeys: [String] {
        switch self {
        case .cpu:
            // Broad P/E-core sensor set (M2 Pro, Mac14,9). Max-aggregated, so
            // gated-low duplicates are harmless; the live cores win.
            return [
                "Tp01", "Tp02", "Tp05", "Tp06", "Tp09", "Tp0A",
                "Tp0D", "Tp0E", "Tp0X", "Tp0Y", "Tp0b", "Tp0c",
                "Tp0f", "Tp0g", "Tp0j", "Tp0k",
                "Tp1A", "Tp1E", "Tp1I", "Tp1M",
                "Tp1h", "Tp1l", "Tp1p", "Tp1t",
            ]
        case .ambient: return ["TaLP", "TaRF"]
        case .hottest:
            return [
                "Tp02", "Tp0A", "Tp0Y",         // hot CPU cores
                "Tg0X", "Tg0f", "Tg0j",         // GPU cluster
                "Th0H", "Th0I",                 // heatpipe
                "TaLP", "TaRF",                 // chassis ambient
            ]
        case .keys(let ks): return ks
        }
    }

    public var label: String {
        switch self {
        case .cpu:           return "cpu"
        case .ambient:       return "ambient"
        case .hottest:       return "hottest"
        case .keys(let ks):  return ks.joined(separator: "+")
        }
    }
}

// MARK: - Presets
//
// Names and breakpoints follow the CLAUDE.md spec. They're plain values so
// the GUI can show them in a picker without duplicating the math.

public struct CurvePreset: Identifiable, Hashable, Sendable {
    public var id: String { name }
    public let name: String
    public let summary: String
    public let curve: FanCurve?       // nil means "let the daemon run", i.e. `auto`
    public let sensor: SensorSource

    public init(name: String, summary: String, curve: FanCurve?, sensor: SensorSource) {
        self.name = name
        self.summary = summary
        self.curve = curve
        self.sensor = sensor
    }
}

extension CurvePreset {
    public static let whisper = CurvePreset(
        name: "whisper",
        summary: "System auto. No manual control; fans may drop to 0 RPM.",
        curve: nil,
        sensor: .cpu
    )

    /// Always-spinning at the firmware's recommended minimum RPM (~2317 on
    /// most M-series chassis). Firmware clamps if the chosen value is below
    /// its actual min, so this is safe across hardware variants.
    public static let quiet = CurvePreset(
        name: "quiet",
        summary: "Pinned at min manual RPM (~2317). Quiet but always cooling.",
        curve: FanCurve([(0, 2317)]),
        sensor: .cpu
    )

    public static let balanced = CurvePreset(
        name: "balanced",
        summary: "Idle below 50°C; ramps to max by 85°C.",
        curve: FanCurve([(50, 2500), (85, 6800)]),
        sensor: .cpu
    )

    public static let boost = CurvePreset(
        name: "boost",
        summary: "Engages at 40°C; max by 65°C. Pre-empts spikes under load.",
        curve: FanCurve([(40, 2500), (65, 6800)]),
        sensor: .cpu
    )

    public static let fullBlast = CurvePreset(
        name: "full",
        summary: "Pinned at max RPM regardless of temperature.",
        curve: FanCurve([(0, 6800)]),
        sensor: .cpu
    )

    /// User-tunable curve. Six fixed-X breakpoints (30…80°C at 10°C steps)
    /// so the menu bar's drag editor can offer a stable grid. Defaults to a
    /// 3500-RPM-baseline palm-rest comfort profile that ramps hard past
    /// 60°C; the app persists user edits in UserDefaults and sends them
    /// over XPC via `applyCurve(_:sensor:)`, so this struct is only the
    /// fallback if the user has never edited the curve.
    public static let manual = CurvePreset(
        name: "manual",
        summary: "Custom curve (drag the points to edit).",
        curve: FanCurve([
            (30, 3500),
            (40, 3700),
            (50, 4000),
            (60, 4800),
            (70, 5800),
            (80, 6800),
        ]),
        sensor: .cpu
    )

    public static let all: [CurvePreset] = [.whisper, .quiet, .balanced, .boost, .fullBlast, .manual]

    public static func byName(_ n: String) -> CurvePreset? {
        all.first { $0.name == n.lowercased() }
    }
}
