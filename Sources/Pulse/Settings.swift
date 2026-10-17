import Foundation
import Observation

/// What can appear in the menu bar. Each kind is its own icon (movable with ⌘).
/// `compact` combines battery, CPU, temperature and RAM into one icon (the "Compact" layout).
enum MenuItemKind: String, CaseIterable, Identifiable {
    case cpu, gpu, memory, temperature, power, network, battery, compact

    /// The icons that can be turned on and off individually.
    static let separate = allCases.filter { $0 != .compact }

    var id: String { rawValue }

    var label: String {
        switch self {
        case .cpu: "CPU"
        case .gpu: "GPU"
        case .memory: "Memory"
        case .temperature: "Temperature"
        case .power: "Power (watts)"
        case .network: "Network"
        case .battery: "Battery"
        case .compact: "Pulse compact"
        }
    }

    var symbol: String {
        switch self {
        case .cpu: "cpu"
        case .gpu: "square.stack.3d.up"
        case .memory: "memorychip"
        case .temperature: "thermometer.medium"
        case .power: "bolt"
        case .network: "arrow.up.arrow.down"
        case .battery: "battery.75percent"
        case .compact: "rectangle.grid.1x2"
        }
    }

    /// Which section opens on click.
    var section: Section {
        switch self {
        case .cpu, .gpu: .cpu
        case .memory: .memory
        case .temperature: .sensors
        case .power, .battery, .compact: .battery
        case .network: .network
        }
    }
}

enum BatteryDisplay: String, CaseIterable, Identifiable {
    case percent, time, until, both
    var id: String { rawValue }
    var label: String {
        switch self {
        case .percent: "Percent"
        case .time: "Time left"
        case .until: "Empty at"
        case .both: "Both"
        }
    }
}

enum MenuBarLayout: String, CaseIterable, Identifiable {
    case compact, separate
    var id: String { rawValue }
    var label: String {
        switch self {
        case .compact: "Compact"
        case .separate: "Separate"
        }
    }
}

/// Calm: monochrome like the system icons, color only when action is needed. Colorful: always in color. Monochrome: never color.
enum MenuBarColor: String, CaseIterable, Identifiable {
    case calm, colorful, mono
    var id: String { rawValue }
    var label: String {
        switch self {
        case .calm: "Calm"
        case .colorful: "Colorful"
        case .mono: "Monochrome"
        }
    }
}

@MainActor
@Observable
final class Settings {
    @ObservationIgnored private let defaults = UserDefaults.standard

    var enabledItems: Set<MenuItemKind> {
        didSet { defaults.set(enabledItems.map(\.rawValue).sorted(), forKey: "enabledItems") }
    }
    var batteryDisplay: BatteryDisplay { didSet { defaults.set(batteryDisplay.rawValue, forKey: "batteryDisplay") } }
    var sampleInterval: Double { didSet { defaults.set(sampleInterval, forKey: "sampleInterval") } }
    var menuBarColor: MenuBarColor { didSet { defaults.set(menuBarColor.rawValue, forKey: "menuBarColor") } }
    var menuBarLayout: MenuBarLayout { didSet { defaults.set(menuBarLayout.rawValue, forKey: "menuBarLayout") } }
    var menuBarGraphs: Bool { didSet { defaults.set(menuBarGraphs, forKey: "menuBarGraphs") } }
    /// Battery as a mini history of the last hour instead of the battery icon.
    var batteryGraph: Bool { didSet { defaults.set(batteryGraph, forKey: "batteryGraph") } }

    init() {
        // Formerly a "Colorful menu bar" switch: whoever turned it off stays monochrome.
        if defaults.object(forKey: "menuBarColor") == nil, defaults.object(forKey: "colorfulMenuBar") as? Bool == false {
            defaults.set(MenuBarColor.mono.rawValue, forKey: "menuBarColor")
        }
        defaults.register(defaults: [
            "enabledItems": [MenuItemKind.cpu, .memory, .temperature, .battery].map(\.rawValue),
            "batteryDisplay": BatteryDisplay.both.rawValue,
            "sampleInterval": 2.0,
            "menuBarColor": MenuBarColor.calm.rawValue,
            "menuBarLayout": MenuBarLayout.separate.rawValue,
            "menuBarGraphs": true,
            "batteryGraph": false,
        ])
        enabledItems = Set((defaults.stringArray(forKey: "enabledItems") ?? []).compactMap(MenuItemKind.init).filter { $0 != .compact })
        batteryDisplay = BatteryDisplay(rawValue: defaults.string(forKey: "batteryDisplay") ?? "") ?? .both
        sampleInterval = defaults.double(forKey: "sampleInterval")
        menuBarColor = MenuBarColor(rawValue: defaults.string(forKey: "menuBarColor") ?? "") ?? .calm
        menuBarLayout = MenuBarLayout(rawValue: defaults.string(forKey: "menuBarLayout") ?? "") ?? .separate
        menuBarGraphs = defaults.bool(forKey: "menuBarGraphs")
        batteryGraph = defaults.bool(forKey: "batteryGraph")
    }

    func isEnabled(_ kind: MenuItemKind) -> Bool { enabledItems.contains(kind) }

    /// Whether an icon is currently in the menu bar (compact replaces the separate ones).
    func isVisible(_ kind: MenuItemKind) -> Bool {
        menuBarLayout == .compact ? kind == .compact : enabledItems.contains(kind)
    }

    func setEnabled(_ kind: MenuItemKind, _ on: Bool) {
        if on { enabledItems.insert(kind) } else { enabledItems.remove(kind) }
    }
}
