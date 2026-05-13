import Foundation
import FanFiCore

/// XPC-exposed service. Each NSXPCConnection gets its own instance, but they
/// all forward to the shared `ControlState` actor passed in at init.
final class FanFiHelperService: NSObject, FanFiHelperProtocol {
    let state: ControlState

    init(state: ControlState) {
        self.state = state
        super.init()
    }

    func ping(reply: @escaping (String) -> Void) {
        reply("FanFiHelper pid=\(getpid()) protocol=\(kFanFiHelperProtocolVersion)")
    }

    func getStatus(reply: @escaping (Data) -> Void) {
        Task { [state] in
            let snap = await state.snapshot()
            let data = (try? JSONEncoder().encode(snap)) ?? Data()
            reply(data)
        }
    }

    func applyPreset(name: String, reply: @escaping (String?) -> Void) {
        Task { [state] in
            do {
                try await state.applyPreset(name)
                reply(nil)
            } catch {
                reply("\(error)")
            }
        }
    }

    func applyCurve(curveJSON: Data, sensor: String, reply: @escaping (String?) -> Void) {
        Task { [state] in
            do {
                let curve = try JSONDecoder().decode(FanCurve.self, from: curveJSON)
                let src = try parseSensor(sensor)
                await state.applyCurve(curve, sensor: src)
                reply(nil)
            } catch let err as HelperError {
                reply(err.description)
            } catch {
                reply("\(error)")
            }
        }
    }

    func restoreAuto(reply: @escaping (String?) -> Void) {
        Task { [state] in
            await state.restoreAuto()
            reply(nil)
        }
    }

    private func parseSensor(_ s: String) throws -> SensorSource {
        switch s.lowercased() {
        case "", "cpu":  return .cpu
        case "ambient":  return .ambient
        case "hottest":  return .hottest
        default:
            let keys = s.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
            guard keys.allSatisfy({ $0.count == 4 }) else {
                throw HelperError.invalidSensor(s)
            }
            return .keys(keys)
        }
    }
}
