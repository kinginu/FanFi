import Foundation

/// Convenience async wrapper around `NSXPCConnection` to the privileged
/// FanFiHelper. Shared between the CLI's `helper` subcommand and the app's
/// `PresetController`.
public final class HelperClient: @unchecked Sendable {
    private let connection: NSXPCConnection
    private(set) public var lastError: Error?

    public init() {
        let c = NSXPCConnection(machServiceName: kFanFiHelperMachService, options: .privileged)
        c.remoteObjectInterface = NSXPCInterface(with: FanFiHelperProtocol.self)
        c.resume()
        self.connection = c
    }

    deinit {
        connection.invalidate()
    }

    public enum ClientError: Error, CustomStringConvertible {
        case proxyUnavailable
        case xpc(Error)
        case decode(String)
        case helper(String)

        public var description: String {
            switch self {
            case .proxyUnavailable:    return "could not acquire XPC proxy (helper not installed?)"
            case .xpc(let e):          return "XPC error: \(e.localizedDescription)"
            case .decode(let m):       return "decode error: \(m)"
            case .helper(let m):       return "helper error: \(m)"
            }
        }
    }

    // MARK: - API

    public func ping() async throws -> String {
        try await callReturning { proxy, cont in
            proxy.ping { reply in cont.resume(returning: reply) }
        }
    }

    public func status() async throws -> HelperStatus {
        let data: Data = try await callReturning { proxy, cont in
            proxy.getStatus { data in cont.resume(returning: data) }
        }
        do {
            return try JSONDecoder().decode(HelperStatus.self, from: data)
        } catch {
            throw ClientError.decode("\(error)")
        }
    }

    public func applyPreset(_ name: String) async throws {
        try await callVoid { proxy, cont in
            proxy.applyPreset(name: name) { err in cont(err) }
        }
    }

    public func applyCurve(_ curve: FanCurve, sensor: SensorSource) async throws {
        let data = try JSONEncoder().encode(curve)
        try await callVoid { proxy, cont in
            proxy.applyCurve(curveJSON: data, sensor: sensor.label) { err in cont(err) }
        }
    }

    public func restoreAuto() async throws {
        try await callVoid { proxy, cont in
            proxy.restoreAuto { err in cont(err) }
        }
    }

    // MARK: - Continuation glue

    /// Reply returns `T`; XPC errors throw.
    private func callReturning<T>(
        _ op: (FanFiHelperProtocol, CheckedContinuation<T, Error>) -> Void
    ) async throws -> T {
        try await withCheckedThrowingContinuation { cont in
            let proxy = connection.remoteObjectProxyWithErrorHandler { err in
                cont.resume(throwing: ClientError.xpc(err))
            }
            guard let typed = proxy as? FanFiHelperProtocol else {
                cont.resume(throwing: ClientError.proxyUnavailable)
                return
            }
            op(typed, cont)
        }
    }

    /// Reply is an optional error string (nil = success). XPC errors also throw.
    private func callVoid(
        _ op: (FanFiHelperProtocol, @escaping (String?) -> Void) -> Void
    ) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let proxy = connection.remoteObjectProxyWithErrorHandler { err in
                cont.resume(throwing: ClientError.xpc(err))
            }
            guard let typed = proxy as? FanFiHelperProtocol else {
                cont.resume(throwing: ClientError.proxyUnavailable)
                return
            }
            op(typed) { errMsg in
                if let errMsg {
                    cont.resume(throwing: ClientError.helper(errMsg))
                } else {
                    cont.resume(returning: ())
                }
            }
        }
    }
}
