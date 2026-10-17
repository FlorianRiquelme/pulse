import Foundation

/// Finds apps that keep computing in the background or keep waking the chip.
/// Piggybacks on the process readings taken every 15 s anyway, so it costs no extra measurement.
public struct BackgroundWatch: Sendable {
    /// Readings of one app (all helper processes combined).
    public struct Input: Sendable {
        public var id: Int32
        /// CPU time in cores since the last reading.
        public var cpu: Double
        /// Wakeups (interrupts) per second.
        public var wakeups: Double
        public var power: Double
        /// Total CPU time of all running processes of the app in seconds.
        public var cpuTime: Double
        /// Time spent awake since the app started (excluding sleep).
        public var awake: TimeInterval?
        public var started: Date?
        public var frontmost: Bool

        public init(id: Int32, cpu: Double, wakeups: Double = 0, power: Double = 0, cpuTime: Double = 0,
                    awake: TimeInterval? = nil, started: Date? = nil, frontmost: Bool = false) {
            self.id = id
            self.cpu = cpu
            self.wakeups = wakeups
            self.power = power
            self.cpuTime = cpuTime
            self.awake = awake
            self.started = started
            self.frontmost = frontmost
        }
    }

    public struct Entry: Identifiable, Equatable, Sendable {
        public var id: Int32
        /// Smoothed load in cores.
        public var cpu: Double
        public var wakeups: Double
        public var power: Double
        public var cpuTime: Double
        /// Since when the app has been standing out.
        public var since: Date
    }

    private struct State: Sendable {
        var cpu: Double
        var wakeups: Double
        var power: Double
        var last: Date
        var since: Date?
    }

    public var cpuThreshold = 0.08
    public var wakeupThreshold = 250.0
    public var minimumDuration: TimeInterval = 10 * 60
    public var tau: TimeInterval = 10 * 60
    /// Only from this runtime on does the average since launch count (otherwise startup skews the number).
    public var lifetimeAge: TimeInterval = 3600
    /// Longer gaps (sleep) do not count as a reading.
    public var maximumGap: TimeInterval = 5 * 60

    private var states: [Int32: State] = [:]

    public init() {}

    public mutating func update(_ inputs: [Input], at date: Date) -> [Entry] {
        var entries: [Entry] = []
        var next: [Int32: State] = [:]
        for input in inputs {
            var state: State
            if var known = states[input.id] {
                let dt = date.timeIntervalSince(known.last)
                if dt > 0 && dt <= maximumGap {
                    let alpha = 1 - exp(-dt / tau)
                    known.cpu += alpha * (input.cpu - known.cpu)
                    known.wakeups += alpha * (input.wakeups - known.wakeups)
                    known.power += alpha * (input.power - known.power)
                }
                known.last = date
                state = known
            } else {
                state = State(cpu: input.cpu, wakeups: input.wakeups, power: input.power, last: date)
                // If the app has been running for a while, its average since launch is the better starting value.
                if let awake = input.awake, awake >= lifetimeAge {
                    let average = input.cpuTime / awake
                    state.cpu = average
                    if average >= cpuThreshold { state.since = input.started ?? date.addingTimeInterval(-awake) }
                }
            }

            let busy = state.cpu >= cpuThreshold || state.wakeups >= wakeupThreshold
            let calm = state.cpu < cpuThreshold * 0.7 && state.wakeups < wakeupThreshold * 0.7
            if busy, state.since == nil { state.since = date }
            if calm { state.since = nil }
            next[input.id] = state

            if busy, !input.frontmost, let since = state.since, date.timeIntervalSince(since) >= minimumDuration {
                entries.append(Entry(id: input.id, cpu: state.cpu, wakeups: state.wakeups, power: state.power,
                                     cpuTime: input.cpuTime, since: since))
            }
        }
        // Forget apps that have quit.
        states = next
        return entries.sorted { ($0.cpu, $0.wakeups) > ($1.cpu, $1.wakeups) }
    }

    public mutating func forget(_ id: Int32) {
        states[id] = nil
    }
}
