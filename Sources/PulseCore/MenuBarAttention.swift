import Foundation

/// How urgent a value in the menu bar is. The calm style only shows color from `warning` on.
public enum Attention: Int, Comparable, Sendable {
    case none, warning, critical

    public static func < (a: Attention, b: Attention) -> Bool { a.rawValue < b.rawValue }
}

/// Thresholds at which the menu bar shows color.
public enum MenuBarAttention {
    /// Battery: below 20 % or less than 1 h left (warning), below 10 % or 20 min (critical). Never on power adapter.
    public static func battery(percent: Double, remaining: TimeInterval?, plugged: Bool) -> Attention {
        if plugged { return .none }
        if percent < 10 || (remaining.map { $0 < 20 * 60 } ?? false) { return .critical }
        if percent < 20 || (remaining.map { $0 < 3600 } ?? false) { return .warning }
        return .none
    }

    /// Chip: throttled (thermal state serious/critical) or 90 °C and above.
    public static func temperature(celsius: Double?, thermal: ProcessInfo.ThermalState) -> Attention {
        if thermal == .critical { return .critical }
        if thermal == .serious || (celsius ?? 0) >= 90 { return .warning }
        return .none
    }

    /// Memory pressure as in `kern.memorystatus_vm_pressure_level`: 1 normal, 2 warning, 4 critical.
    public static func memory(pressureLevel: Int) -> Attention {
        switch pressureLevel {
        case ..<2: .none
        case 2: .warning
        default: .critical
        }
    }
}

/// Does Pulse fit next to the notch? To its right, all icons share the space (MacBook Air: 645 pt).
public enum MenuBarFit {
    /// Extra spacing macOS needs per icon (measured: 4 icons with 228 pt of image take up ~292 pt).
    public static let spacing: Double = 16

    public static func width(of imageWidths: [Double]) -> Double {
        imageWidths.reduce(0) { $0 + $1 + spacing }
    }

    /// Suggest compact when the separate icons take up more than a third of the free space
    /// and the compact icon actually saves space.
    public static func suggestsCompact(separate: Double, compact: Double, available: Double?) -> Bool {
        guard let available, available > 0 else { return false }
        return separate > available / 3 && compact + spacing < separate
    }
}
