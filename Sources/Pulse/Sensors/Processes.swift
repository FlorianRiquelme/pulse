import AppKit
import Darwin
import PulseCore

/// Usage of one app (all helper processes combined under the responsible process).
struct AppUsage: Identifiable {
    var id: pid_t
    var name: String
    var icon: NSImage?
    /// CPU time in cores (1 = one core fully busy).
    var cpu: Double
    var memory: Double
    /// Footprint minus the resident part: roughly compressed or swapped out. Counts other things too, only good for ordering.
    var outOfRAM: Double = 0
    /// Smoothed power draw in watts (from the kernel's energy counters).
    var power: Double
    /// Wakeups (interrupts) per second.
    var wakeups: Double = 0
    /// Total CPU time of all running processes of the app in seconds.
    var cpuTime: Double = 0
    /// Time spent awake since the app started (excluding sleep).
    var awake: TimeInterval?
}

/// Reads CPU time, memory and energy of all of the user's own processes.
/// Other users' processes (root) cannot be read without admin rights and are missing.
final class ProcessSampler {
    private struct Previous { var cpuTime: UInt64; var energy: UInt64; var wakeups: UInt64 }
    private typealias Responsible = @convention(c) (pid_t) -> pid_t

    private var previous: [pid_t: Previous] = [:]
    private var lastDate: Date?
    private var power: [pid_t: Smoothed] = [:]
    private var names: [pid_t: (String, NSImage?)] = [:]
    private var starts: [pid_t: Date] = [:]
    private let ticksToNanos: Double
    /// Time since the previous reading (0 on the first).
    private(set) var interval: TimeInterval = 0
    private let responsible: Responsible?

    init() {
        var timebase = mach_timebase_info()
        mach_timebase_info(&timebase)
        ticksToNanos = Double(timebase.numer) / Double(timebase.denom)
        let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)
        responsible = dlsym(rtldDefault, "responsibility_get_pid_responsible_for_pid")
            .map { unsafeBitCast($0, to: Responsible.self) }
    }

    /// `outOfRAM` costs a second system call per process and is only needed while the panel is open.
    func sample(at date: Date = .now, outOfRAM: Bool = true) -> [AppUsage] {
        var pids = [pid_t](repeating: 0, count: 4096)
        let count = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
        guard count > 0 else { return [] }
        let dt = lastDate.map { date.timeIntervalSince($0) } ?? 0
        lastDate = date
        interval = dt
        let machNow = mach_absolute_time()

        var current: [pid_t: Previous] = [:]
        var apps: [pid_t: AppUsage] = [:]
        var instantPower: [pid_t: Double] = [:]

        for pid in pids.prefix(count) where pid > 0 {
            var info = rusage_info_v6()
            let ok = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(pid, RUSAGE_INFO_V6, $0) == 0
                }
            }
            guard ok else { continue }
            let now = Previous(cpuTime: info.ri_user_time + info.ri_system_time, energy: info.ri_energy_nj,
                               wakeups: info.ri_interrupt_wkups)
            current[pid] = now

            let key = owner(of: pid)
            var app = apps[key] ?? AppUsage(id: key, name: "", icon: nil, cpu: 0, memory: 0, power: 0)
            app.memory += Double(info.ri_phys_footprint)
            var task = proc_taskinfo()
            if outOfRAM, proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &task, Int32(MemoryLayout<proc_taskinfo>.size)) > 0 {
                app.outOfRAM += max(0, Double(info.ri_phys_footprint) - Double(task.pti_resident_size))
            }
            app.cpuTime += Double(now.cpuTime) * ticksToNanos / 1e9
            if pid == key, machNow > info.ri_proc_start_abstime {
                app.awake = Double(machNow - info.ri_proc_start_abstime) * ticksToNanos / 1e9
            }
            if let before = previous[pid], dt > 0 {
                let cpuNanos = Double(now.cpuTime &- before.cpuTime) * ticksToNanos
                if now.cpuTime >= before.cpuTime { app.cpu += cpuNanos / 1e9 / dt }
                if now.wakeups >= before.wakeups { app.wakeups += Double(now.wakeups - before.wakeups) / dt }
                if now.energy >= before.energy {
                    instantPower[key, default: 0] += Double(now.energy - before.energy) / 1e9 / dt
                }
            }
            apps[key] = app
        }
        previous = current

        for key in apps.keys {
            var smoothed = power[key] ?? Smoothed(tau: 30)
            if dt > 0 { smoothed.add(instantPower[key] ?? 0, at: date) }
            power[key] = smoothed
            apps[key]?.power = smoothed.value ?? 0
            let (name, icon) = describe(key)
            apps[key]?.name = name
            apps[key]?.icon = icon
        }
        // Forget apps that have quit.
        power = power.filter { apps[$0.key] != nil }
        starts = starts.filter { apps[$0.key] != nil }
        if names.count > 2000 { names = names.filter { apps[$0.key] != nil } }
        return Array(apps.values)
    }

    /// Store app icons once as a small bitmap instead of scaling the large icon on every draw.
    static func thumbnail(_ icon: NSImage) -> NSImage {
        let pixels = 32
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return icon }
        rep.size = NSSize(width: 16, height: 16)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        icon.draw(in: NSRect(x: 0, y: 0, width: 16, height: 16))
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }

    /// The app a process belongs to (helper processes count toward the app).
    func owner(of pid: pid_t) -> pid_t {
        let owner = responsible?(pid) ?? pid
        return owner > 0 ? owner : pid
    }

    /// Start time of a process (wall clock, including sleep).
    func started(_ pid: pid_t) -> Date? {
        if let known = starts[pid] { return known }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        let date = Date(timeIntervalSince1970: Double(info.pbi_start_tvsec) + Double(info.pbi_start_tvusec) / 1e6)
        starts[pid] = date
        return date
    }

    func describe(_ pid: pid_t) -> (String, NSImage?) {
        if let known = names[pid] { return known }
        let result: (String, NSImage?)
        if let app = NSRunningApplication(processIdentifier: pid), let name = app.localizedName {
            result = (name, app.icon.map(Self.thumbnail))
        } else {
            var buffer = [CChar](repeating: 0, count: 256)
            proc_name(pid, &buffer, UInt32(buffer.count))
            let name = String(cString: buffer)
            result = (name.isEmpty ? "PID \(pid)" : name, nil)
        }
        names[pid] = result
        return result
    }
}
