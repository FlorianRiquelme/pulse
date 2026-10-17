import AppKit
import Observation
import PulseCore
import ServiceManagement

enum Section: String, CaseIterable, Identifiable {
    case battery, cpu, memory, sensors, network

    var id: String { rawValue }

    var title: String {
        switch self {
        case .battery: "Battery"
        case .cpu: "CPU"
        case .memory: "Memory"
        case .sensors: "Sensors"
        case .network: "Network"
        }
    }

    var symbol: String {
        switch self {
        case .battery: "battery.75percent"
        case .cpu: "cpu"
        case .memory: "memorychip"
        case .sensors: "thermometer.medium"
        case .network: "network"
        }
    }
}

enum ChartRange: String, CaseIterable, Identifiable {
    case live, hour, day
    var id: String { rawValue }
    var label: String {
        switch self {
        case .live: "10 min"
        case .hour: "1 h"
        case .day: "24 h"
        }
    }
    var duration: TimeInterval {
        switch self {
        case .live: 10 * 60
        case .hour: 3600
        case .day: 24 * 3600
        }
    }
}

/// Time series recorded continuously.
enum Metric: CaseIterable {
    case cpu, cpuUser, cpuSystem, gpu, memory, memoryPressure, batteryPercent, batteryPower, systemPower,
         socTemp, socMax, batteryTemp, netIn, netOut, diskRead, diskWrite, swapUsed, swapIn, swapOut
}

/// An app whose memory footprint has been rising steadily for hours.
struct AppGrowth: Identifiable {
    var id: pid_t
    var name: String
    var icon: NSImage?
    var growth: GrowthTracker<pid_t>.Growth
}

/// An app that keeps computing in the background.
struct BackgroundHog: Identifiable {
    var usage: BackgroundWatch.Entry
    var name: String
    var icon: NSImage?
    var id: pid_t { usage.id }
}

@MainActor
@Observable
final class AppModel {
    let settings = Settings()

    // Current readings
    private(set) var cpu = CPUReading()
    private(set) var memory = MemoryReading()
    private(set) var battery: BatteryReading?
    private(set) var temperatures = TemperatureReading()
    private(set) var fans: [FanReading] = []
    private(set) var gpu: Double?
    private(set) var network = NetworkReading()
    private(set) var disk = DiskReading()
    private(set) var systemPower: Double?
    private(set) var apps: [AppUsage] = []
    /// Apps that have kept the Mac awake for at least 10 min.
    private(set) var keepAwake: [KeepAwakeApp] = []
    private(set) var growingApps: [AppGrowth] = []
    /// Apps that have been computing or waking the chip conspicuously in the background for at least 10 min.
    private(set) var backgroundHogs: [BackgroundHog] = []
    private(set) var thermalState = ProcessInfo.processInfo.thermalState
    private(set) var lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
    private(set) var estimate = BatteryEstimate()
    private(set) var lastSession: DischargeSession?
    /// Forecast by time of day with a band (battery only).
    private(set) var rhythm: RhythmForecast?
    /// The most recent sleeps (oldest first).
    private(set) var sleeps: [SleepRecord] = []
    private(set) var lastUpdate = Date.distantPast
    /// Stempeluhr's time tracking (`nil`: not installed).
    private(set) var workLedger: WorkLedger?
    private(set) var workRules = WorkRules()

    // UI state (no @State with the Command Line Tools)
    var section: Section = .battery
    var showSettings = false
    var range: ChartRange = .live
    var showAllSensors = false
    /// App whose quit is waiting for confirmation.
    var confirmQuit: pid_t?
    /// For `--snapshot`: draw the panel without a ScrollView.
    var snapshotMode = false
    var panelVisible = false {
        didSet {
            if panelVisible && !oldValue {
                sampleProcesses()
                updateRhythm()
                sampleSleepBlockers()
                stempeluhr.reload() // Stempeluhr's settings are not observed
                refreshAppEnergy()
            }
        }
    }
    /// Energy per app from powerlog (only read when the panel opens).
    private(set) var appEnergy: PowerlogReader.Result?
    var energyRange: EnergyRange = .today
    var energyBatteryOnly = false
    var launchAtLogin = SMAppService.mainApp.status == .enabled
    var launchError: String?

    let chipName: String
    let efficiencyCores: Int
    let performanceName: String
    let hasFans: Bool
    let hasBattery: Bool
    let bootTime = Sysctl.bootTime

    /// Called after every reading (redraws the menu bar).
    @ObservationIgnored var onSample: (() -> Void)?

    @ObservationIgnored private var series: [Metric: Series] = [:]
    @ObservationIgnored private let cpuSensor = CPUSensor()
    @ObservationIgnored private let memorySensor = MemorySensor()
    @ObservationIgnored private let batterySensor = BatterySensor()
    @ObservationIgnored private let thermalSensor = ThermalSensor()
    @ObservationIgnored private let smc = SMC()
    @ObservationIgnored private let networkSensor = NetworkSensor()
    @ObservationIgnored private let diskSensor = DiskSensor()
    @ObservationIgnored private let processSampler = ProcessSampler()
    @ObservationIgnored private var growth = GrowthTracker<pid_t>()
    @ObservationIgnored private let powerlog = PowerlogReader()
    @ObservationIgnored private var lastEnergyQuery = Date.distantPast
    @ObservationIgnored private var backgroundWatch = BackgroundWatch()
    @ObservationIgnored private var dischargePower = Smoothed(tau: 90)
    @ObservationIgnored private var accumulator = MinuteAccumulator()
    @ObservationIgnored let log: MinuteLog
    @ObservationIgnored let sleepLog: SleepLog
    @ObservationIgnored private var fellAsleep: (t: Date, percent: Double?, plugged: Bool)?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var lastProcessSample = Date.distantPast
    @ObservationIgnored private var lastThermalSample = Date.distantPast
    @ObservationIgnored private var lastSleepSample = Date.distantPast
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var profile: DischargeProfile?
    @ObservationIgnored private var profileDate = Date.distantPast
    @ObservationIgnored private var backfilling = false
    @ObservationIgnored private let stempeluhr = StempeluhrSource()

    /// Counter so charts redraw on every reading.
    private(set) var revision = 0

    init() {
        chipName = cpuSensor.chipName
        efficiencyCores = cpuSensor.efficiencyCores
        performanceName = cpuSensor.performanceName
        hasFans = !smc.fans.isEmpty
        hasBattery = batterySensor.available
        for metric in Metric.allCases { series[metric] = Series(capacity: 900) }

        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Pulse", isDirectory: true)
        log = MinuteLog(url: support.appendingPathComponent("minutes.jsonl"))
        sleepLog = SleepLog(url: support.appendingPathComponent("sleeps.jsonl"))
        sleeps = sleepLog.records
    }

    func start() {
        stempeluhr.onChange = { [weak self] in
            guard let self else { return }
            workLedger = stempeluhr.ledger
            workRules = stempeluhr.rules
        }
        stempeluhr.reload()
        sample()
        schedule()
        backfill(archives: true)
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.thermalState = ProcessInfo.processInfo.thermalState }
        })
        observers.append(center.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled }
        })
        // After waking up, fresh values right away instead of a gap until the next tick.
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.stempeluhr.reload()
                self?.sample()
                self?.didWake()
                self?.backfill(archives: false)
            }
        })
        observers.append(workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.willSleep() }
        })
        // On the very first launch, backfill the sleeps of the last few days once from `pmset -g log`.
        if hasBattery, !sleepLog.existed {
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                self?.readPowerLog({ PowerLog.sleeps(in: $0).filter { $0.duration >= 5 * 60 } }) { found in
                    guard let self, !self.sleepLog.existed else { return }
                    self.sleepLog.replace(with: found)
                    self.sleeps = self.sleepLog.records
                }
            }
        }
    }

    func shutdown() {
        if let last = accumulator.flush() { log.append(last) }
    }

    private func schedule() {
        timer?.invalidate()
        let interval = max(1, settings.sampleInterval)
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
        timer.tolerance = interval * 0.1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        withObservationTracking { _ = settings.sampleInterval } onChange: { [weak self] in
            Task { @MainActor in self?.schedule() }
        }
    }

    // MARK: Sampling

    private func sample() {
        let now = Date.now
        cpu = cpuSensor.sample()
        memory = memorySensor.sample(at: now)
        battery = batterySensor.sample()
        // Querying the sensors is the most expensive part of a reading; with the panel closed, 10 s is enough.
        if panelVisible || now.timeIntervalSince(lastThermalSample) >= 10 {
            temperatures = thermalSensor.sample()
            lastThermalSample = now
        }
        gpu = GPUSensor.utilization()
        // nettop runs in the background; only needed when network is visible.
        if panelVisible || settings.isVisible(.network) {
            let processes = processSampler
            networkSensor.sample(identify: { pid, fallback in
                let owner = processes.owner(of: pid)
                let (name, icon) = processes.describe(owner)
                // Pulse cannot name other users' processes; take the name from nettop instead.
                return (owner, name.hasPrefix("PID ") ? fallback : name, icon)
            }, completion: { [weak self] reading in
                guard let self else { return }
                network = reading
                record(.netIn, reading.inRate, .now)
                record(.netOut, reading.outRate, .now)
            })
        }
        disk = diskSensor.sample(at: now)
        systemPower = smc.systemPower ?? battery?.systemLoadW
        if hasFans { fans = smc.fans }

        // Processes cost the most; without an open panel every 15 s is enough (the energy counters keep running anyway).
        if panelVisible || now.timeIntervalSince(lastProcessSample) >= 15 { sampleProcesses(at: now) }
        // Keep-awake apps at most once a minute; when closed, only if the battery icon can show a hint on battery.
        let hintVisible = (settings.menuBarLayout == .compact || settings.isEnabled(.battery)) && battery?.plugged == false
        if (panelVisible || hintVisible) && now.timeIntervalSince(lastSleepSample) >= 60 { sampleSleepBlockers(at: now) }

        record(.cpu, cpu.total, now)
        record(.cpuUser, cpu.user, now)
        record(.cpuSystem, cpu.system, now)
        record(.gpu, gpu, now)
        record(.memory, memory.usedFraction, now)
        record(.memoryPressure, 1 - memory.availableLevel, now)
        record(.swapUsed, memory.swapUsed, now)
        record(.swapIn, memory.swapIn, now)
        record(.swapOut, memory.swapOut, now)
        record(.systemPower, systemPower, now)
        record(.socTemp, temperatures.socAverage, now)
        record(.socMax, temperatures.socMax, now)
        record(.batteryTemp, temperatures.battery ?? battery?.temperature, now)
        record(.diskRead, disk.readRate, now)
        record(.diskWrite, disk.writeRate, now)

        if let battery {
            record(.batteryPercent, battery.percent, now)
            record(.batteryPower, battery.batteryPowerW, now)
            if battery.plugged { dischargePower.reset() } else { dischargePower.add(battery.batteryPowerW, at: now) }
        }

        let minute = MinuteSample(
            t: now, battery: battery?.percent, plugged: battery?.plugged ?? true, charging: battery?.charging ?? false,
            batteryW: battery?.batteryPowerW, systemW: systemPower, cpu: cpu.total, gpu: gpu,
            mem: memory.usedFraction, socTemp: temperatures.socAverage,
            swap: memory.swapUsed, swapIn: memory.swapIn, swapOut: memory.swapOut)
        let finished = accumulator.add(minute)
        if let finished { log.append(finished) }

        if let battery {
            let recent = log.since(now.addingTimeInterval(-BatteryEstimator.typicalWindow))
            estimate = BatteryEstimator.estimate(
                remainingWh: battery.remainingWh, fullWh: battery.fullWh,
                nowPowerW: battery.plugged ? nil : dischargePower.value, log: recent, now: now)
            lastSession = BatteryEstimator.lastSession(in: log.since(now.addingTimeInterval(-48 * 3600)), pluggedNow: battery.plugged)
            // The time-of-day forecast only changes with the minute log.
            if battery.plugged != (rhythm == nil) || finished != nil { updateRhythm(at: now) }
        }

        lastUpdate = now
        revision &+= 1
        onSample?()
    }

    /// Backfills the battery history from the powerlog for minutes when Pulse was not running.
    private func backfill(archives: Bool) {
        guard hasBattery, !backfilling else { return }
        backfilling = true
        let since = Date.now.addingTimeInterval(-MinuteLog.retention)
        Task { [weak self] in
            let samples = await Task.detached(priority: .utility) {
                PowerlogBackfill.load(since: since, archives: archives)
            }.value
            guard let self else { return }
            backfilling = false
            // Pulse writes the current minute itself.
            if log.merge(samples, before: MinuteAccumulator.minuteStart(.now)) > 0 {
                profile = nil
                updateRhythm()
                revision &+= 1
            }
        }
    }

    private func updateRhythm(at now: Date = .now) {
        guard let battery, !battery.plugged else {
            rhythm = nil
            return
        }
        // Recomputing the 7-day profile hourly is enough.
        if profile == nil || now.timeIntervalSince(profileDate) > 3600 {
            profile = BatteryEstimator.profile(log: log.since(now.addingTimeInterval(-BatteryEstimator.typicalWindow)), now: now)
            profileDate = now
        }
        guard let profile else { return }
        rhythm = BatteryEstimator.rhythmForecast(
            remainingWh: battery.remainingWh, fullWh: battery.fullWh, percent: battery.percent,
            recentPowerW: estimate.recentPowerW ?? estimate.nowPowerW, profile: profile, now: now)
    }

    private func sampleProcesses(at date: Date = .now) {
        apps = processSampler.sample(at: date, outOfRAM: panelVisible)
        lastProcessSample = date
        growth.add(Dictionary(uniqueKeysWithValues: apps.map { ($0.id, $0.memory) }), at: date)
        let byID = Dictionary(apps.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        growingApps = growth.growing().compactMap { g in
            byID[g.key].map { AppGrowth(id: g.key, name: $0.name, icon: $0.icon, growth: g) }
        }
        guard processSampler.interval > 0 else { return }
        let own = ProcessInfo.processInfo.processIdentifier
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let inputs = apps.filter { $0.id != own }.map { app in
            BackgroundWatch.Input(id: app.id, cpu: app.cpu, wakeups: app.wakeups, power: app.power, cpuTime: app.cpuTime,
                                  awake: app.awake, started: processSampler.started(app.id), frontmost: app.id == front)
        }
        backgroundHogs = backgroundWatch.update(inputs, at: date).compactMap { entry in
            byID[entry.id].map { BackgroundHog(usage: entry, name: $0.name, icon: $0.icon) }
        }
    }

    func refreshAppEnergy() {
        guard hasBattery, Date.now.timeIntervalSince(lastEnergyQuery) >= 60 else { return }
        lastEnergyQuery = .now
        powerlog.load { result in
            Task { @MainActor [weak self] in
                if let result { self?.appEnergy = result }
            }
        }
    }

    private func sampleSleepBlockers(at date: Date = .now) {
        let sampler = processSampler
        let blockers = SleepBlockers.summarize(SleepAssertions.read(), now: date, ownPID: getpid(), owner: sampler.owner)
        keepAwake = blockers.map { blocker in
            let (name, icon) = sampler.describe(blocker.pid)
            return KeepAwakeApp(blocker: blocker, name: name, icon: icon,
                                canActivate: NSRunningApplication(processIdentifier: blocker.pid)?.activationPolicy == .regular)
        }
        lastSleepSample = date
    }

    private func record(_ metric: Metric, _ value: Double?, _ date: Date) {
        guard let value else { return }
        series[metric]?.append(value, at: date)
    }

    // MARK: Queries for views and the menu bar

    func tail(_ metric: Metric, _ count: Int) -> [Double] { series[metric]?.tail(count) ?? [] }

    /// Points for a chart in the selected range: live from memory, otherwise from the minute log.
    func points(_ metric: Metric, range: ChartRange? = nil) -> [Point] {
        let range = range ?? self.range
        let cutoff = Date.now.addingTimeInterval(-range.duration)
        if range != .live, let key = Self.logValue(metric) {
            // Minutes backfilled from the powerlog only have battery values.
            let imported = Self.importedValue(metric)
            var points = log.since(cutoff).compactMap { s in
                (s.isImported && !imported) ? nil : key(s).map { Point(t: s.t, v: $0) }
            }
            // Append the current minute from the live values so the chart reaches up to now.
            if let last = series[metric]?.points.last, last.t > (points.last?.t ?? .distantPast) { points.append(last) }
            return points
        }
        return series[metric]?.points.filter { $0.t >= cutoff } ?? []
    }

    /// Whether long ranges are available for a metric.
    static func logValue(_ metric: Metric) -> ((MinuteSample) -> Double?)? {
        switch metric {
        case .cpu: { $0.cpu }
        case .gpu: { $0.gpu }
        case .memory: { $0.mem }
        case .batteryPercent: { $0.battery }
        case .batteryPower: { $0.batteryW }
        case .systemPower: { $0.systemW }
        case .socTemp: { $0.socTemp }
        case .swapUsed: { $0.swap }
        case .swapIn: { $0.swapIn }
        case .swapOut: { $0.swapOut }
        default: nil
        }
    }

    static func importedValue(_ metric: Metric) -> Bool {
        metric == .batteryPercent || metric == .batteryPower
    }

    /// Stretches on power adapter within the range (for the shading in the battery chart).
    func pluggedSpans(since start: Date) -> [ClosedRange<Date>] {
        var spans: [ClosedRange<Date>] = []
        var spanStart: Date?
        var previous: Date?
        let samples = log.since(start)
        for s in samples {
            if s.plugged, spanStart == nil { spanStart = s.t }
            if !s.plugged, let begin = spanStart {
                spans.append(begin...(previous ?? s.t))
                spanStart = nil
            }
            previous = s.t
        }
        if let begin = spanStart { spans.append(begin...(battery?.plugged == true ? .now : previous ?? .now)) }
        return spans
    }

    /// End of the workday according to Stempeluhr and whether the battery lasts until then (battery only).
    func workdayRunway(now: Date = .now) -> WorkdayRunway? {
        guard let battery, !battery.plugged, let ledger = workLedger, let remaining = estimate.best,
              let end = Workday.endOfDay(ledger: ledger, rules: workRules, now: now) else { return nil }
        let short = now.addingTimeInterval(remaining) < end
        let chargePower = short
            ? BatteryEstimator.typicalChargePower(log: log.since(now.addingTimeInterval(-BatteryEstimator.typicalWindow)))
            : nil
        return WorkdayRunway(endOfDay: end, remaining: remaining, typical: estimate.typical,
                             powerW: estimate.recentPowerW ?? estimate.nowPowerW, chargePowerW: chargePower, now: now)
    }

    // MARK: Sleep

    private func willSleep() {
        let b = batterySensor.sample()
        fellAsleep = (.now, b.map(Self.precisePercent), b?.plugged ?? true)
    }

    private func didWake() {
        guard let asleep = fellAsleep else { return }
        fellAsleep = nil
        guard hasBattery, Date.now.timeIntervalSince(asleep.t) >= 60 else { return }
        let record = sleepLog.add(SleepRecord(
            start: asleep.t, end: .now, startPercent: asleep.percent, endPercent: battery.map(Self.precisePercent),
            plugged: asleep.plugged || battery?.plugged != false))
        sleeps = sleepLog.records
        // Only `pmset -g log` counts brief wakeups (~0.8 s CPU): once per wake, slightly delayed, never on the tick.
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
            self?.readPowerLog({ PowerLog.details(in: $0, start: record.start, end: record.end) }) { details in
                guard let self, let details else { return }
                self.sleepLog.update(start: record.start, with: details)
                self.sleeps = self.sleepLog.records
            }
        }
    }

    /// Charge level from mAh instead of whole percent, so small drops become visible too.
    private static func precisePercent(_ b: BatteryReading) -> Double {
        b.fullCapacity > 0 ? min(100, b.remainingCapacity / b.fullCapacity * 100) : b.percent
    }

    /// Runs `pmset -g log` in the background and parses the output there.
    private func readPowerLog<T: Sendable>(_ parse: @escaping @Sendable (String) -> T,
                                           completion: @escaping @MainActor (T) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
            process.arguments = ["-g", "log"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let result = parse(String(decoding: data, as: UTF8.self))
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(result) } }
        }
    }

    func topApps(by key: KeyPath<AppUsage, Double>, limit: Int = 5) -> [AppUsage] {
        Array(apps.sorted { $0[keyPath: key] > $1[keyPath: key] }.prefix(limit))
    }

    /// Has something been keeping the Mac awake on battery for a long time? (hint on the battery icon)
    var longKeepAwake: KeepAwakeApp? {
        guard battery?.plugged == false else { return nil }
        return keepAwake.first { Date.now.timeIntervalSince($0.blocker.since) >= SleepBlockers.menuBarAge }
    }

    func activate(_ app: KeepAwakeApp) {
        NSRunningApplication(processIdentifier: app.blocker.pid)?.activate()
    }

    var totalAppPower: Double { apps.reduce(0) { $0 + $1.power } }

    var uptime: TimeInterval? { bootTime.map { Date.now.timeIntervalSince($0) } }

    var thermalLabel: String {
        switch thermalState {
        case .nominal: "Normal"
        case .fair: "Warm"
        case .serious: "Throttled"
        case .critical: "Heavily throttled"
        @unknown default: "Unknown"
        }
    }

    // MARK: Long-running apps

    /// Quits an app gracefully or immediately; helper processes without an app get a signal.
    func quit(_ pid: pid_t, force: Bool) {
        if let app = NSRunningApplication(processIdentifier: pid) {
            _ = force ? app.forceTerminate() : app.terminate()
        } else {
            kill(pid, force ? SIGKILL : SIGTERM)
        }
        confirmQuit = nil
        backgroundWatch.forget(pid)
        backgroundHogs.removeAll { $0.id == pid }
    }

    func revealInFinder(_ pid: pid_t) {
        let app = NSRunningApplication(processIdentifier: pid)
        var url = app?.bundleURL ?? app?.executableURL
        if url == nil {
            var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
            if proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 { url = URL(fileURLWithPath: String(cString: buffer)) }
        }
        if let url { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            launchError = nil
        } catch {
            launchError = error.localizedDescription
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}
