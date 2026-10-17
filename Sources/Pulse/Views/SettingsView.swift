import AppKit
import PulseCore
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings

        VStack(spacing: 12) {
            Card {
                VStack(alignment: .leading, spacing: 8) {
                    CardTitle("Menu bar")
                    picker("Icons", selection: $settings.menuBarLayout) {
                        ForEach(MenuBarLayout.allCases) { Text($0.label).tag($0) }
                    }
                    if settings.menuBarLayout == .compact {
                        Text(model.hasBattery
                             ? "One icon: battery time remaining with the charge level as a bar below it, next to CPU, temperature and memory."
                             : "One icon with CPU, temperature and memory.")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        ForEach(MenuItemKind.separate.filter { $0 != .battery || model.hasBattery }) { kind in
                            Toggle(isOn: Binding(get: { settings.isEnabled(kind) }, set: { settings.setEnabled(kind, $0) })) {
                                Label(kind.label, systemImage: kind.symbol).font(.system(size: 12))
                            }
                            .toggleStyle(.switch)
                            .controlSize(.mini)
                        }
                        notchHint
                    }
                    if model.hasBattery, systemBatteryVisible {
                        Text("The macOS battery icon is visible too. You can hide it in System Settings under Menu Bar.")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text("Hold ⌘ to drag the icons to a new position.")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }
            Card {
                VStack(alignment: .leading, spacing: 10) {
                    CardTitle("Appearance")
                    if model.hasBattery {
                        picker("Battery shows", selection: $settings.batteryDisplay, width: 240) {
                            ForEach(BatteryDisplay.allCases) { Text($0.label).tag($0) }
                        }
                        toggle("Battery history instead of icon", isOn: $settings.batteryGraph)
                    }
                    picker("Update every", selection: $settings.sampleInterval) {
                        Text("1 s").tag(1.0)
                        Text("2 s").tag(2.0)
                        Text("5 s").tag(5.0)
                    }
                    toggle("Mini graphs", isOn: $settings.menuBarGraphs)
                    picker("Colors", selection: $settings.menuBarColor) {
                        ForEach(MenuBarColor.allCases) { Text($0.label).tag($0) }
                    }
                    if settings.menuBarColor == .calm {
                        Text("Color only when action is needed: memory pressure, throttling, battery below 20% or less than 1 h left.")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    toggle("Launch at login",
                           isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                    if let error = model.launchError {
                        Text(error).font(.system(size: 10)).foregroundStyle(.red)
                    }
                }
            }
            Text("History: ~/Library/Application Support/Pulse/minutes.jsonl (8 days, per minute)")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Space next to the notch is limited; whatever doesn't fit, macOS hides without notice.
    @ViewBuilder private var notchHint: some View {
        // The menu bar is on every screen; the one with the notch is what counts (even if a monitor is the main display).
        let available = NSScreen.screens.compactMap { $0.auxiliaryTopRightArea?.width }.min()
        let separate = MenuBarFit.width(of: MenuItemKind.separate
            .filter { model.settings.isEnabled($0) && ($0 != .battery || model.hasBattery) }
            .map { MenuBarRenderer.content(for: $0, model: model).image.size.width })
        let compact = MenuBarFit.width(of: [MenuBarRenderer.content(for: .compact, model: model).image.size.width])
        if let available, MenuBarFit.suggestsCompact(separate: separate, compact: compact, available: available) {
            VStack(alignment: .leading, spacing: 6) {
                Text("There are \(Int(available)) pt free to the right of the notch, and Pulse's icons take up about \(Int(separate)) pt of it. Whatever no longer fits disappears behind the notch without notice. Compact needs about \(Int(compact)) pt.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Use Compact") { model.settings.menuBarLayout = .compact }
                    .controlSize(.small)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
        }
    }

    private var systemBatteryVisible: Bool {
        UserDefaults(suiteName: "com.apple.controlcenter")?.bool(forKey: "NSStatusItem VisibleCC Battery") ?? false
    }

    private func toggle(_ label: String, isOn: Binding<Bool>) -> some View {
        Toggle(label, isOn: isOn)
            .toggleStyle(.switch)
            .controlSize(.mini)
            .font(.system(size: 12))
    }

    private func picker<V: Hashable, C: View>(_ label: String, selection: Binding<V>, width: CGFloat = 170,
                                              @ViewBuilder content: () -> C) -> some View {
        HStack {
            Text(label).font(.system(size: 12))
            Spacer()
            Picker("", selection: selection, content: content)
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: width)
        }
    }
}
