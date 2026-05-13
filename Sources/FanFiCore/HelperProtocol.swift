import Foundation

/// Mach service name the privileged helper publishes. Both the app's
/// NSXPCConnection and the launchd plist must reference this exact string.
public let kFanFiHelperMachService = "com.fanfi.helper"

/// Bump when the wire protocol changes incompatibly. The app should compare
/// against `HelperStatus.protocolVersion` and refuse to talk to mismatched
/// helpers (prompt for reinstall instead).
public let kFanFiHelperProtocolVersion: Int = 1

/// NSXPC protocol exposed by `FanFiHelper`.
///
/// Conventions:
/// - All methods are async-by-callback. Replies must be invoked exactly once.
/// - Success replies have `nil` as the (optional) error string. Failures
///   pass a human-readable description.
/// - `FanCurve` and other structured payloads are serialized as JSON `Data`
///   so the protocol stays NSXPCSecureCoding-friendly without manual
///   `NSSecureCoding` plumbing on Codable types.
@objc public protocol FanFiHelperProtocol {
    /// Liveness check. Reply contains the helper's PID + protocol version.
    func ping(reply: @escaping (String) -> Void)

    /// JSON-encoded `HelperStatus`.
    func getStatus(reply: @escaping (Data) -> Void)

    /// Apply a named preset (whisper/quiet/balanced/boost/full).
    /// Pass an unknown name to receive an error.
    func applyPreset(name: String, reply: @escaping (String?) -> Void)

    /// Apply a custom curve. `curveJSON` is a `JSONEncoder().encode(FanCurve)`
    /// payload; `sensor` is `cpu` / `ambient` / `hottest` / comma-separated
    /// 4-char SMC keys.
    func applyCurve(curveJSON: Data, sensor: String, reply: @escaping (String?) -> Void)

    /// Stop any active curve and hand control back to thermalmonitord.
    func restoreAuto(reply: @escaping (String?) -> Void)
}

/// Helper-side snapshot the app polls via `getStatus`.
public struct HelperStatus: Codable, Sendable, Equatable {
    public let protocolVersion: Int
    public let pid: Int32
    /// Name of the currently-applied preset, or nil if idle (daemon in
    /// control) or running a custom curve.
    public let activePreset: String?
    /// Shorthand of the active curve (e.g. `40:3500,80:6800`) if one is
    /// running, otherwise nil.
    public let activeCurveShorthand: String?
    /// Last error message recorded by the control loop, if any.
    public let lastError: String?

    public init(
        protocolVersion: Int = kFanFiHelperProtocolVersion,
        pid: Int32 = 0,
        activePreset: String? = nil,
        activeCurveShorthand: String? = nil,
        lastError: String? = nil
    ) {
        self.protocolVersion = protocolVersion
        self.pid = pid
        self.activePreset = activePreset
        self.activeCurveShorthand = activeCurveShorthand
        self.lastError = lastError
    }
}
