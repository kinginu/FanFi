import Foundation
import IOKit

// MARK: - Result codes (from VirtualSMC SDK AppleSmc.h)

public enum SMCResultCode: UInt8, CustomStringConvertible, Sendable {
    case success         = 0x00
    case error           = 0x01
    case commCollision   = 0x80
    case spuriousData    = 0x81
    case badCommand      = 0x82  // Firmware rejected (e.g., write F%dMd in Mode 3)
    case badParameter    = 0x83
    case notFound        = 0x84  // Key does not exist (or, write path: not writable from this client)
    case notReadable     = 0x85
    case notWritable     = 0x86
    case keySizeMismatch = 0x87
    case framingError    = 0x88
    case badArgument     = 0x89

    public var description: String {
        let name: String = {
            switch self {
            case .success:         return "success"
            case .error:           return "error"
            case .commCollision:   return "commCollision"
            case .spuriousData:    return "spuriousData"
            case .badCommand:      return "badCommand"
            case .badParameter:    return "badParameter"
            case .notFound:        return "notFound"
            case .notReadable:     return "notReadable"
            case .notWritable:     return "notWritable"
            case .keySizeMismatch: return "keySizeMismatch"
            case .framingError:    return "framingError"
            case .badArgument:     return "badArgument"
            }
        }()
        return "\(name) (0x\(String(rawValue, radix: 16)))"
    }
}

public enum SMCError: Error, CustomStringConvertible, Sendable {
    case serviceNotFound
    case openFailed(kern_return_t)
    case ioError(kern_return_t)
    case firmware(UInt8)         // raw byte at offset 40 of response
    case invalidKey(String)

    public var description: String {
        switch self {
        case .serviceNotFound:    return "AppleSMC service not found"
        case .openFailed(let kr): return String(format: "IOServiceOpen failed (0x%08x). Need root?", kr)
        case .ioError(let kr):    return String(format: "IOConnectCallStructMethod failed (0x%08x)", kr)
        case .firmware(let code):
            if let known = SMCResultCode(rawValue: code) { return "SMC firmware error: \(known)" }
            return String(format: "SMC firmware error: unknown (0x%02x)", code)
        case .invalidKey(let k):  return "Invalid SMC key: \(k)"
        }
    }
}

// MARK: - SMC command codes

enum SMCCommand: UInt8 {
    case kernelIndex  = 2   // IOConnectCallStructMethod selector
    case readBytes    = 5
    case writeBytes   = 6
    case readIndex    = 8
    case readKeyInfo  = 9
}

// MARK: - SMCParamStruct
//
// Swift's field-packing optimization lays this struct out to exactly 80 bytes
// with the kernel's expected offsets (verified via MemoryLayout):
//   key@0, keyInfo@28 (dataSize@28, dataType@32, attrs@36),
//   padding@38, result@40, status@41, data8@42, data32@44, bytes@48.

struct SMCParamStruct {
    struct Version {
        var major: UInt8 = 0
        var minor: UInt8 = 0
        var build: UInt8 = 0
        var reserved: UInt8 = 0
        var release: UInt16 = 0
    }
    struct PLimitData {
        var version: UInt16 = 0
        var length: UInt16 = 0
        var cpuPLimit: UInt32 = 0
        var gpuPLimit: UInt32 = 0
        var memPLimit: UInt32 = 0
    }
    struct KeyInfo {
        var dataSize: UInt32 = 0
        var dataType: UInt32 = 0
        var dataAttributes: UInt8 = 0
    }
    typealias Bytes32 = (
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
    )

    var key: UInt32 = 0
    var vers = Version()
    var pLimitData = PLimitData()
    var keyInfo = KeyInfo()
    var padding: UInt16 = 0
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: Bytes32 = (
        0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
        0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
    )
}

private func bytesToTuple(_ a: [UInt8]) -> SMCParamStruct.Bytes32 {
    var p = a + Array(repeating: UInt8(0), count: max(0, 32 - a.count))
    if p.count > 32 { p = Array(p.prefix(32)) }
    return (
        p[0],p[1],p[2],p[3],p[4],p[5],p[6],p[7],
        p[8],p[9],p[10],p[11],p[12],p[13],p[14],p[15],
        p[16],p[17],p[18],p[19],p[20],p[21],p[22],p[23],
        p[24],p[25],p[26],p[27],p[28],p[29],p[30],p[31]
    )
}

private func tupleToArray(_ t: SMCParamStruct.Bytes32, count: Int) -> [UInt8] {
    var out = [UInt8](repeating: 0, count: 32)
    withUnsafeBytes(of: t) { src in
        for i in 0..<32 { out[i] = src[i] }
    }
    return Array(out.prefix(count))
}

private func fourCC(_ s: String) throws -> UInt32 {
    let b = Array(s.utf8)
    guard b.count == 4 else { throw SMCError.invalidKey(s) }
    return (UInt32(b[0]) << 24) | (UInt32(b[1]) << 16) | (UInt32(b[2]) << 8) | UInt32(b[3])
}

// MARK: - Connection

public final class SMC {
    private var conn: io_connect_t = 0
    public var verbose: Bool = false

    public init() throws {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { throw SMCError.serviceNotFound }
        defer { IOObjectRelease(service) }
        let kr = IOServiceOpen(service, mach_task_self_, 0, &conn)
        guard kr == kIOReturnSuccess else { throw SMCError.openFailed(kr) }
    }

    deinit { if conn != 0 { IOServiceClose(conn) } }

    private func call(_ input: SMCParamStruct) throws -> SMCParamStruct {
        var inp = input
        var out = SMCParamStruct()
        var outSize: size_t = MemoryLayout<SMCParamStruct>.stride
        let kr = IOConnectCallStructMethod(
            conn,
            UInt32(SMCCommand.kernelIndex.rawValue),
            &inp,
            MemoryLayout<SMCParamStruct>.stride,
            &out,
            &outSize
        )
        if verbose {
            let keyStr = withUnsafeBytes(of: inp.key.bigEndian) { ptr in
                String(bytes: ptr, encoding: .ascii) ?? "????"
            }
            let cmdName: String = {
                switch SMCCommand(rawValue: inp.data8) {
                case .readKeyInfo: return "keyInfo"
                case .readBytes:   return "read"
                case .writeBytes:  return "write"
                case .readIndex:   return "readIndex"
                default:           return "cmd=\(inp.data8)"
                }
            }()
            let sizeStr = "size=\(inp.keyInfo.dataSize)"
            let krStr = kr == kIOReturnSuccess ? "ok" : String(format: "kIO=0x%08x", kr)
            let resStr = String(format: "result=0x%02x", out.result)
            FileHandle.standardError.write(Data("smc: \(cmdName) key=\(keyStr) \(sizeStr) -> \(krStr) \(resStr)\n".utf8))
        }
        guard kr == kIOReturnSuccess else { throw SMCError.ioError(kr) }
        if out.result != 0 { throw SMCError.firmware(out.result) }
        return out
    }

    public func keyInfo(_ key: String) throws -> (size: UInt32, type: UInt32) {
        var inp = SMCParamStruct()
        inp.key = try fourCC(key)
        inp.data8 = SMCCommand.readKeyInfo.rawValue
        let out = try call(inp)
        return (out.keyInfo.dataSize, out.keyInfo.dataType)
    }

    public func read(_ key: String) throws -> [UInt8] {
        var inp = SMCParamStruct()
        inp.key = try fourCC(key)
        inp.data8 = SMCCommand.readKeyInfo.rawValue
        let info = try call(inp)

        inp.keyInfo.dataSize = info.keyInfo.dataSize
        inp.data8 = SMCCommand.readBytes.rawValue
        let out = try call(inp)
        return tupleToArray(out.bytes, count: Int(info.keyInfo.dataSize))
    }

    public func write(_ key: String, _ bytes: [UInt8]) throws {
        var inp = SMCParamStruct()
        inp.key = try fourCC(key)
        inp.data8 = SMCCommand.readKeyInfo.rawValue
        let info = try call(inp)

        precondition(Int(info.keyInfo.dataSize) == bytes.count,
                     "SMC key \(key): expected \(info.keyInfo.dataSize) bytes, got \(bytes.count)")

        inp.keyInfo.dataSize = info.keyInfo.dataSize
        inp.data8 = SMCCommand.writeBytes.rawValue
        inp.bytes = bytesToTuple(bytes)
        _ = try call(inp)
    }

    // MARK: Typed accessors

    public func readUInt8(_ key: String) throws -> UInt8 {
        let b = try read(key)
        return b.first ?? 0
    }

    public func readFloat32(_ key: String) throws -> Float {
        let b = try read(key)
        guard b.count >= 4 else { return 0 }
        return b.withUnsafeBytes { $0.loadUnaligned(as: Float.self) }
    }

    public func writeUInt8(_ key: String, _ v: UInt8) throws {
        try write(key, [v])
    }

    public func writeFloat32(_ key: String, _ v: Float) throws {
        var f = v
        var bytes = [UInt8](repeating: 0, count: 4)
        withUnsafeBytes(of: &f) { src in
            for i in 0..<4 { bytes[i] = src[i] }
        }
        try write(key, bytes)
    }

    // MARK: - Enumeration (diagnostics)

    private func readUInt32BE(_ key: String) throws -> UInt32 {
        let b = try read(key)
        guard b.count >= 4 else { return 0 }
        return (UInt32(b[0]) << 24) | (UInt32(b[1]) << 16) | (UInt32(b[2]) << 8) | UInt32(b[3])
    }

    /// Enumerate every SMC key registered on this machine. Uses #KEY for the
    /// count, then readIndex (cmd 8) with data32=i to fetch each key name.
    public func enumerateKeys() -> [String] {
        guard let total = try? readUInt32BE("#KEY") else { return [] }
        var keys: [String] = []
        for i in 0..<total {
            var inp = SMCParamStruct()
            inp.data8 = SMCCommand.readIndex.rawValue
            inp.data32 = i
            guard let out = try? call(inp) else { continue }
            let k = out.key
            let buf: [UInt8] = [
                UInt8((k >> 24) & 0xFF),
                UInt8((k >> 16) & 0xFF),
                UInt8((k >> 8) & 0xFF),
                UInt8(k & 0xFF),
            ]
            keys.append(String(bytes: buf, encoding: .ascii) ?? "????")
        }
        return keys
    }
}
