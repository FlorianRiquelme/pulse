import PulseCore
import SwiftUI

struct SensorsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let t = model.temperatures
        VStack(spacing: 12) {
            Card {
                HStack(spacing: 18) {
                    let soc = t.socAverage ?? 0
                    Ring(progress: soc / 105, colors: [Palette.temperature(soc), Palette.temperature(t.socMax ?? soc)],
                         label: t.socAverage.map { Fmt.celsius($0) } ?? "–", caption: "Chip avg")
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            Tile(label: "Chip max", value: t.socMax.map { Fmt.celsius($0) } ?? "–",
                                 color: t.socMax.map(Palette.temperature) ?? .primary)
                            Tile(label: "Battery", value: t.battery.map { Fmt.celsius($0) } ?? "–")
                        }
                        HStack(spacing: 8) {
                            Tile(label: "SSD", value: t.ssd.map { Fmt.celsius($0) } ?? "–")
                            Tile(label: "Thermal state", value: model.thermalLabel, color: thermalColor)
                        }
                    }
                }
            }
            Card {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        CardTitle("Temperature history")
                        RangePicker()
                    }
                    LineChart(series: [
                        ChartSeries(name: "Chip", color: .orange, points: model.points(.socTemp)),
                        ChartSeries(name: "Chip max", color: .red, points: model.range == .live ? model.points(.socMax) : [], filled: false),
                        ChartSeries(name: "Battery", color: .teal, points: model.range == .live ? model.points(.batteryTemp) : [], filled: false),
                    ], yDomain: 20...110, height: 90, format: ChartFormat.celsius)
                    HStack(spacing: 12) {
                        LegendDot(color: .orange, label: "Chip avg")
                        if model.range == .live {
                            LegendDot(color: .red, label: "Chip max")
                            LegendDot(color: .teal, label: "Battery")
                        }
                    }
                }
            }
            fans
            power
            allSensors
        }
    }

    private var thermalColor: Color {
        switch model.thermalState {
        case .nominal: .green
        case .fair: .yellow
        default: .red
        }
    }

    private var fans: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                CardTitle("Fans")
                if model.fans.isEmpty {
                    HStack(spacing: 10) {
                        Image(systemName: "wind")
                            .font(.system(size: 18))
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("No fans, passively cooled").font(.system(size: 12, weight: .medium))
                            Text("If it gets too warm, macOS lowers the clock speed. \"Thermal state\" above shows when that happens.")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                } else {
                    ForEach(model.fans) { fan in
                        VStack(alignment: .leading, spacing: 4) {
                            StatRow(label: "Fan \(fan.id + 1)", value: "\(Int(fan.rpm)) rpm", systemImage: "fanblades")
                            Meter(fraction: fan.fraction, color: .cyan)
                        }
                    }
                }
            }
        }
    }

    private var power: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                CardTitle("Power")
                HStack(spacing: 8) {
                    Tile(label: "System", value: model.systemPower.map(Fmt.watts) ?? "–", color: .yellow)
                    if let b = model.battery {
                        Tile(label: b.batteryPowerW >= 0 ? "from battery" : "into battery", value: Fmt.watts(abs(b.batteryPowerW)))
                        Tile(label: "Power adapter", value: b.adapterInputW.map(Fmt.watts) ?? "–")
                    }
                }
            }
        }
    }

    private var allSensors: some View {
        @Bindable var model = model
        return Card {
            DisclosureGroup(isExpanded: $model.showAllSensors) {
                VStack(spacing: 5) {
                    ForEach(model.temperatures.all) { sensor in
                        HStack {
                            Text(sensor.name).font(.system(size: 11))
                            Spacer()
                            Text(Fmt.celsius(sensor.celsius))
                                .font(.system(size: 11, weight: .semibold))
                                .monospacedDigit()
                                .foregroundStyle(Palette.temperature(sensor.celsius))
                        }
                    }
                }
                .padding(.top, 8)
            } label: {
                CardTitle("All sensors", trailing: "\(model.temperatures.all.count)")
            }
        }
    }
}
