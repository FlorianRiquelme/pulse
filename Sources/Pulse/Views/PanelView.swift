import PulseCore
import SwiftUI

struct PanelView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 12) {
            header
            if model.showSettings {
                SettingsView()
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            } else {
                tabs
                if model.snapshotMode {
                    content
                } else {
                    ScrollView(.vertical, showsIndicators: false) {
                        content
                            .id(model.section)
                            .transition(.opacity)
                    }
                    .frame(maxHeight: 620)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            footer
        }
        .padding(16)
        .frame(width: 380)
        .animation(.spring(duration: 0.3), value: model.showSettings)
        .animation(.easeInOut(duration: 0.2), value: model.section)
    }

    @ViewBuilder
    private var content: some View {
        switch model.section {
        case .battery: BatteryView()
        case .cpu: CPUView()
        case .memory: MemoryView()
        case .sensors: SensorsView()
        case .network: NetworkView()
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(LinearGradient(colors: Palette.colors(model.section), startPoint: .topLeading, endPoint: .bottomTrailing))
                Image(systemName: "waveform.path.ecg")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 1) {
                Text("pulse").font(.system(size: 15, weight: .bold, design: .rounded))
                Text("\(model.chipName) · \(Fmt.bytes(model.memory.total))")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                model.showSettings.toggle()
            } label: {
                Image(systemName: model.showSettings ? "xmark" : "gearshape")
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(.primary.opacity(0.06)))
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .help(model.showSettings ? "Back" : "Settings")
        }
    }

    private var tabs: some View {
        HStack(spacing: 4) {
            ForEach(Section.allCases.filter { $0 != .battery || model.hasBattery }) { section in
                let selected = model.section == section
                Button {
                    model.section = section
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: section.symbol).font(.system(size: 13, weight: .medium))
                        Text(section.title).font(.system(size: 10, weight: selected ? .semibold : .regular))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .foregroundStyle(selected ? .white : .secondary)
                    .background {
                        if selected {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(LinearGradient(colors: Palette.colors(section), startPoint: .leading, endPoint: .trailing))
                                .shadow(color: Palette.colors(section)[0].opacity(0.35), radius: 6, y: 2)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.primary.opacity(0.05)))
    }

    private var footer: some View {
        HStack(spacing: 6) {
            if let uptime = model.uptime {
                Label("Uptime \(Self.days(uptime))", systemImage: "clock.arrow.circlepath")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Button("Activity Monitor") {
                NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
            }
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            Text("·").foregroundStyle(.tertiary)
            Button("Quit") { NSApp.terminate(nil) }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .keyboardShortcut("q")
        }
        .padding(.top, 2)
    }

    static func days(_ interval: TimeInterval) -> String {
        let hours = Int(interval / 3600)
        if hours < 24 { return "\(hours) h" }
        return "\(hours / 24) d \(hours % 24) h"
    }
}
