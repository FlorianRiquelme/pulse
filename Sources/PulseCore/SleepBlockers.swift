import Foundation

/// A power assertion as returned by `IOPMCopyAssertionsByProcess`.
public struct PowerAssertion: Equatable, Sendable {
    public var pid: Int32
    public var process: String
    public var type: String
    public var name: String
    /// Whom a service holds the assertion for (e.g. coreaudiod for the app that plays audio).
    public var onBehalfOf: Int32?
    public var started: Date
    public var resources: [String]
    public var level: Int

    public init(pid: Int32, process: String, type: String, name: String, onBehalfOf: Int32? = nil,
                started: Date, resources: [String] = [], level: Int = 255) {
        self.pid = pid
        self.process = process
        self.type = type
        self.name = name
        self.onBehalfOf = onBehalfOf
        self.started = started
        self.resources = resources
        self.level = level
    }
}

/// What keeps an app awake.
public enum SleepReason: Hashable, Comparable, Sendable {
    case speaker, audioOut, microphone, display, other

    /// "Zen keeps … active"
    public var phrase: String {
        switch self {
        case .speaker: "keeps the speaker active"
        case .audioOut: "keeps audio output active"
        case .microphone: "keeps the microphone active"
        case .display: "keeps the display on"
        case .other: "prevents sleep"
        }
    }
}

/// An app that is currently keeping the Mac awake (all its assertions combined).
public struct SleepBlocker: Equatable, Sendable {
    public var pid: Int32
    public var reasons: [SleepReason]
    public var since: Date
    /// Name of the assertion when nothing more specific is known.
    public var detail: String?

    public var phrase: String {
        let phrases = reasons.map(\.phrase)
        guard phrases.count > 1 else { return phrases.first ?? SleepReason.other.phrase }
        // "keeps the speaker active and the microphone active" would be clumsy; merge the objects.
        let objects = reasons.compactMap { r -> String? in
            switch r {
            case .speaker: "the speaker"
            case .audioOut: "audio output"
            case .microphone: "the microphone"
            default: nil
            }
        }
        if objects.count == reasons.count {
            return "keeps " + objects.dropLast().joined(separator: ", ") + " and " + objects.last! + " active"
        }
        return phrases.joined(separator: " and ")
    }
}

public enum SleepBlockers {
    /// Shorter assertions are usually normal (video, download, call) and are not shown.
    public static let minimumAge: TimeInterval = 10 * 60
    /// From this duration on battery, the battery icon in the menu bar gets a hint.
    public static let menuBarAge: TimeInterval = 30 * 60

    private static let systemTypes: Set<String> = [
        "PreventUserIdleSystemSleep", "PreventSystemSleep", "NoIdleSleepAssertion", "DenySystemSleep",
    ]
    private static let displayTypes: Set<String> = ["PreventUserIdleDisplaySleep", "NoDisplaySleepAssertion"]

    /// Combines the assertions per app. `owner` maps a process to its app
    /// (helper processes like WebKit.GPU count toward the app), `ownPID` is left out.
    public static func summarize(_ assertions: [PowerAssertion], now: Date, minimumAge: TimeInterval = minimumAge,
                                 ownPID: Int32? = nil, owner: (Int32) -> Int32 = { $0 }) -> [SleepBlocker] {
        var byOwner: [Int32: SleepBlocker] = [:]
        for a in assertions where a.level > 0 && now.timeIntervalSince(a.started) >= minimumAge {
            let display = displayTypes.contains(a.type)
            guard display || systemTypes.contains(a.type) else { continue }
            // powerd keeps the Mac awake on its own while the display is on; that is normal.
            if a.process == "powerd" && a.onBehalfOf == nil { continue }
            let key = owner(a.onBehalfOf.flatMap { $0 > 0 ? $0 : nil } ?? a.pid)
            if key == ownPID { continue }

            let reason = display ? .display : reason(for: a.resources)
            var blocker = byOwner[key] ?? SleepBlocker(pid: key, reasons: [], since: a.started)
            if !blocker.reasons.contains(reason) { blocker.reasons.append(reason) }
            blocker.reasons.sort()
            blocker.since = min(blocker.since, a.started)
            if reason == .other, blocker.detail == nil { blocker.detail = a.name }
            byOwner[key] = blocker
        }
        return byOwner.values.sorted { ($0.since, $0.pid) < ($1.since, $1.pid) }
    }

    static func reason(for resources: [String]) -> SleepReason {
        if resources.contains("audio-in") { return .microphone }
        if resources.contains("audio-out") {
            return resources.contains { $0.localizedCaseInsensitiveContains("Speaker") } ? .speaker : .audioOut
        }
        return .other
    }
}
