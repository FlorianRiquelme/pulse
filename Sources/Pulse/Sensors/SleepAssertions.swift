import AppKit
import IOKit.pwr_mgt
import PulseCore

/// Reads the power assertions of all processes (like `pmset -g assertions`, without admin rights).
enum SleepAssertions {
    static func read() -> [PowerAssertion] {
        var unmanaged: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&unmanaged) == kIOReturnSuccess,
              let byProcess = unmanaged?.takeRetainedValue() as? [NSNumber: [[String: Any]]] else { return [] }
        var result: [PowerAssertion] = []
        for (pid, list) in byProcess {
            for a in list {
                guard let type = a["AssertType"] as? String else { continue }
                result.append(PowerAssertion(
                    pid: pid.int32Value,
                    process: a["Process Name"] as? String ?? "",
                    type: type,
                    name: a["AssertName"] as? String ?? "",
                    onBehalfOf: (a["AssertionOnBehalfOfPID"] as? NSNumber)?.int32Value,
                    started: a["AssertStartWhen"] as? Date ?? .now,
                    resources: a["ResourcesUsed"] as? [String] ?? [],
                    level: (a["AssertLevel"] as? NSNumber)?.intValue ?? 255))
            }
        }
        return result
    }
}

/// An app that keeps the Mac awake, with name and icon for display.
struct KeepAwakeApp: Identifiable {
    var blocker: SleepBlocker
    var name: String
    var icon: NSImage?
    /// Only real apps can be brought to the front.
    var canActivate: Bool

    var id: pid_t { blocker.pid }
}
