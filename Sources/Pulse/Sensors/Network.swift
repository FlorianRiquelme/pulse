import AppKit

struct NetworkReading {
    var inRate: Double = 0
    var outRate: Double = 0
    /// Since Pulse started.
    var totalIn: Double = 0
    var totalOut: Double = 0
    var interfaceName: String?
    var localIP: String?
    /// Data rate per app (bytes/s).
    var apps: [NetworkApp] = []
    /// nettop returned no data.
    var unavailable = false
}

struct NetworkApp: Identifiable {
    var id: pid_t
    var name: String
    var icon: NSImage?
    var inRate: Double
    var outRate: Double
    var total: Double { inRate + outRate }
}

/// Data rate from the per-process network statistics (the same source as Activity Monitor).
/// The Wi-Fi interface counters miss incoming traffic on current macOS versions,
/// so Pulse queries `nettop` once per reading (about 10 ms) and takes the differences.
final class NetworkSensor {
    struct Counter { var name: String; var inBytes: Double; var outBytes: Double }
    private var previous: [pid_t: Counter] = [:]
    private var previousDate: Date?
    private var totals = (inBytes: 0.0, outBytes: 0.0)
    private var running = false
    private let queue = DispatchQueue(label: "pulse.nettop", qos: .utility)

    /// Measures in the background; `completion` runs on the main thread.
    func sample(identify: @escaping (pid_t, String) -> (owner: pid_t, name: String, icon: NSImage?),
                completion: @escaping (NetworkReading) -> Void) {
        guard !running else { return }
        running = true
        queue.async { [self] in
            let counters = Self.readNettop()
            let date = Date.now
            let (interface, ip) = Self.primaryAddress()
            DispatchQueue.main.async { [self] in
                running = false
                completion(reading(from: counters, at: date, interface: interface, ip: ip, identify: identify))
            }
        }
    }

    private func reading(from counters: [pid_t: Counter]?, at date: Date,
                         interface: String?, ip: String?,
                         identify: (pid_t, String) -> (owner: pid_t, name: String, icon: NSImage?)) -> NetworkReading {
        var r = NetworkReading(interfaceName: interface, localIP: ip)
        guard let counters else {
            r.unavailable = true
            return r
        }
        defer {
            previous = counters
            previousDate = date
        }
        guard let previousDate, date.timeIntervalSince(previousDate) > 0.2 else { return r }
        let dt = date.timeIntervalSince(previousDate)

        var perApp: [pid_t: NetworkApp] = [:]
        for (pid, now) in counters {
            // New processes count from now on; quit ones drop out (no negative jump).
            guard let before = previous[pid] else { continue }
            let dIn = max(0, now.inBytes - before.inBytes), dOut = max(0, now.outBytes - before.outBytes)
            guard dIn + dOut > 0 else { continue }
            r.inRate += dIn / dt
            r.outRate += dOut / dt
            totals.inBytes += dIn
            totals.outBytes += dOut
            let who = identify(pid, now.name)
            var app = perApp[who.owner] ?? NetworkApp(id: who.owner, name: who.name, icon: who.icon, inRate: 0, outRate: 0)
            app.inRate += dIn / dt
            app.outRate += dOut / dt
            perApp[who.owner] = app
        }
        r.totalIn = totals.inBytes
        r.totalOut = totals.outBytes
        r.apps = perApp.values.sorted { $0.total > $1.total }
        return r
    }

    /// Bytes per process since process start: lines "Name.PID,bytes_in,bytes_out,".
    private static func readNettop() -> [pid_t: Counter]? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/nettop")
        process.arguments = ["-P", "-L", "1", "-n", "-x", "-J", "bytes_in,bytes_out"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0, let text = String(data: data, encoding: .utf8) else { return nil }

        var result: [pid_t: Counter] = [:]
        for line in text.split(separator: "\n").dropFirst() {
            let fields = line.split(separator: ",", omittingEmptySubsequences: false)
            guard fields.count >= 3, let dot = fields[0].lastIndex(of: "."),
                  let pid = pid_t(fields[0][fields[0].index(after: dot)...]),
                  let inBytes = Double(fields[1]), let outBytes = Double(fields[2]) else { continue }
            result[pid] = Counter(name: String(fields[0][..<dot]), inBytes: inBytes, outBytes: outBytes)
        }
        return result
    }

    /// First IPv4 address on an en* interface.
    private static func primaryAddress() -> (String?, String?) {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return (nil, nil) }
        defer { freeifaddrs(list) }
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            let name = String(cString: entry.ifa_name)
            guard name.hasPrefix("en"), let addr = entry.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  entry.ifa_flags & UInt32(IFF_UP) != 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                return (name, String(cString: host))
            }
        }
        return (nil, nil)
    }
}
