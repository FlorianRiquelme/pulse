import Foundation
import IOKit

struct FanReading: Identifiable {
    var id: Int
    var rpm: Double
    var minRPM: Double
    var maxRPM: Double
    var fraction: Double { maxRPM > minRPM ? max(0, min(1, (rpm - minRPM) / (maxRPM - minRPM))) : 0 }
}

/// Reads values from the System Management Controller (without admin rights, read-only).
final class SMC {
    private struct KeyData {
        struct Version { var major: UInt8 = 0, minor: UInt8 = 0, build: UInt8 = 0, reserved: UInt8 = 0, release: UInt16 = 0 }
        struct PowerLimit { var version: UInt16 = 0, length: UInt16 = 0, cpu: UInt32 = 0, gpu: UInt32 = 0, mem: UInt32 = 0 }
        // The padding bytes mirror the layout of the C struct (80 bytes in total).
        struct KeyInfo { var size: UInt32 = 0, type: UInt32 = 0, attributes: UInt8 = 0, pad1: UInt8 = 0, pad2: UInt8 = 0, pad3: UInt8 = 0 }
        typealias Bytes = (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                           UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8)

        var key: UInt32 = 0
        var version = Version()
        var powerLimit = PowerLimit()
        var keyInfo = KeyInfo()
        var result: UInt8 = 0
        var status: UInt8 = 0
        var command: UInt8 = 0
        var data32: UInt32 = 0
        var bytes: Bytes = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    }

    private var connection: io_connect_t = 0
    private var infoCache: [UInt32: KeyData.KeyInfo] = [:]

    init() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return }
        defer { IOObjectRelease(service) }
        if IOServiceOpen(service, mach_task_self_, 0, &connection) != KERN_SUCCESS { connection = 0 }
    }

    deinit {
        if connection != 0 { IOServiceClose(connection) }
    }

    /// Numeric value of a key (supports flt, ui8/16/32, fpe2, sp78).
    func number(_ key: String) -> Double? {
        guard let (type, bytes) = read(key) else { return nil }
        switch type {
        case "flt ": return bytes.count >= 4 ? Double(bytes.withUnsafeBytes { $0.loadUnaligned(as: Float.self) }) : nil
        case "ui8 ": return bytes.first.map(Double.init)
        case "ui16": return bytes.count >= 2 ? Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1])) : nil
        case "ui32": return bytes.count >= 4 ? Double(bytes.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }) : nil
        case "fpe2": return bytes.count >= 2 ? Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1])) / 4 : nil
        case "sp78": return bytes.count >= 2 ? Double(Int16(bitPattern: UInt16(bytes[0]) << 8 | UInt16(bytes[1]))) / 256 : nil
        default: return nil
        }
    }

    var fans: [FanReading] {
        guard let count = number("FNum"), count > 0 else { return [] }
        return (0..<Int(count)).compactMap { i in
            guard let rpm = number("F\(i)Ac") else { return nil }
            return FanReading(id: i, rpm: rpm, minRPM: number("F\(i)Mn") ?? 0, maxRPM: number("F\(i)Mx") ?? 0)
        }
    }

    /// Total system power in watts.
    var systemPower: Double? { number("PSTR").flatMap { $0 > 0 ? $0 : nil } }

    private func read(_ key: String) -> (String, [UInt8])? {
        guard connection != 0 else { return nil }
        let code = Self.fourCC(key)
        let info: KeyData.KeyInfo
        if let cached = infoCache[code] {
            info = cached
        } else {
            var input = KeyData()
            input.key = code
            input.command = 9 // read key info
            guard let output = call(&input) else { return nil }
            info = output.keyInfo
            infoCache[code] = info
        }
        var input = KeyData()
        input.key = code
        input.keyInfo.size = info.size
        input.command = 5 // read value
        guard let output = call(&input) else { return nil }
        let size = min(Int(info.size), 32)
        let bytes = withUnsafeBytes(of: output.bytes) { Array($0.prefix(size)) }
        return (Self.string(info.type), bytes)
    }

    private func call(_ input: inout KeyData) -> KeyData? {
        var output = KeyData()
        var size = MemoryLayout<KeyData>.stride
        let result = IOConnectCallStructMethod(connection, 2, &input, MemoryLayout<KeyData>.stride, &output, &size)
        return result == KERN_SUCCESS && output.result == 0 ? output : nil
    }

    private static func fourCC(_ s: String) -> UInt32 { s.utf8.prefix(4).reduce(0) { $0 << 8 | UInt32($1) } }
    private static func string(_ v: UInt32) -> String {
        String(decoding: [24, 16, 8, 0].map { UInt8((v >> $0) & 0xff) }, as: UTF8.self)
    }
}
