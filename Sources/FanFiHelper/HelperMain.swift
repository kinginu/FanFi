import Foundation
import FanFiCore

@main
struct HelperMain {
    static func main() {
        FileHandle.standardError.write(Data("FanFiHelper: starting (pid=\(getpid()))\n".utf8))

        let state: ControlState
        do {
            state = try ControlState()
        } catch {
            FileHandle.standardError.write(Data(
                "FanFiHelper: init failed: \(error)\n".utf8
            ))
            exit(1)
        }

        let delegate = ListenerDelegate(state: state)
        let listener = NSXPCListener(machServiceName: kFanFiHelperMachService)
        listener.delegate = delegate
        listener.resume()

        FileHandle.standardError.write(Data(
            "FanFiHelper: listening on \(kFanFiHelperMachService)\n".utf8
        ))

        installSignalHandlers()
        RunLoop.main.run()
    }

    private static func installSignalHandlers() {
        // Can't make actor calls from a C signal handler; just exit cleanly.
        // The control loop's `defer`/Task cancellation handlers run during
        // normal process teardown.
        let handler: @convention(c) (Int32) -> Void = { sig in
            FileHandle.standardError.write(Data(
                "FanFiHelper: signal \(sig), exiting\n".utf8
            ))
            // Best-effort: ask FanController directly via a brand-new connection.
            // We're about to die, so we accept that this isn't actor-safe.
            if let ctrl = try? FanController() {
                ctrl.restoreAuto()
            }
            Darwin.exit(0)
        }
        signal(SIGTERM, handler)
        signal(SIGINT, handler)
        signal(SIGHUP, handler)
    }
}

/// One delegate; spins up a fresh `FanFiHelperService` per connection but all
/// share the singleton `ControlState`.
final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    let state: ControlState
    init(state: ControlState) {
        self.state = state
        super.init()
    }

    func listener(_ listener: NSXPCListener,
                  shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        let service = FanFiHelperService(state: state)
        newConnection.exportedInterface = NSXPCInterface(with: FanFiHelperProtocol.self)
        newConnection.exportedObject = service
        newConnection.invalidationHandler = {
            FileHandle.standardError.write(Data("FanFiHelper: connection invalidated\n".utf8))
        }
        newConnection.interruptionHandler = {
            FileHandle.standardError.write(Data("FanFiHelper: connection interrupted\n".utf8))
        }
        newConnection.resume()
        FileHandle.standardError.write(Data(
            "FanFiHelper: accepted connection from pid=\(newConnection.processIdentifier)\n".utf8
        ))
        return true
    }
}
