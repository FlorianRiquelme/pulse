import PulseCore
import SwiftUI

struct MemoryView: View {
    @Environment(AppModel.self) private var model

    private static let appColor = Color(red: 0.75, green: 0.45, blue: 1.00)
    private static let wiredColor = Color(red: 1.00, green: 0.45, blue: 0.65)
    private static let compressedColor = Color(red: 1.00, green: 0.70, blue: 0.30)
    private static let cachedColor = Color(red: 0.45, green: 0.65, blue: 1.00)
    private static let swapColor = Color(red: 1.00, green: 0.55, blue: 0.35)

    var body: some View {
        let m = model.memory
        VStack(spacing: 12) {
            Card {
                HStack(spacing: 18) {
                    Ring(progress: m.usedFraction, colors: Palette.memory, label: Fmt.percent(m.usedFraction), caption: "used")
                    VStack(alignment: .leading, spacing: 5) {
                        Text("\(Fmt.bytes(m.used)) of \(Fmt.bytes(m.total))")
                            .font(.system(size: 17, weight: .bold, design: .rounded))
                            .monospacedDigit()
                        HStack(spacing: 6) {
                            Chip(text: "Pressure: \(m.pressure.label)", color: Palette.pressure(m.pressure), systemImage: "gauge.medium")
                        }
                        Text(pressureHint(m))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
            }
            if !model.growingApps.isEmpty { growing }
            breakdown(m)
            Card {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        CardTitle("History")
                        RangePicker()
                    }
                    LineChart(series: [
                        ChartSeries(name: "Used", color: Self.appColor, points: model.points(.memory)),
                        ChartSeries(name: "Pressure", color: .orange, points: model.range == .live ? model.points(.memoryPressure) : [], filled: false),
                    ], yDomain: 0...1, height: 90, format: ChartFormat.percent)
                    HStack(spacing: 12) {
                        LegendDot(color: Self.appColor, label: "Used")
                        if model.range == .live { LegendDot(color: .orange, label: "Memory pressure") }
                    }
                }
            }
            swapHistory
            outOfRAM
            Card {
                VStack(alignment: .leading, spacing: 10) {
                    CardTitle("Largest memory footprint")
                    AppList(apps: model.topApps(by: \.memory, limit: 6), value: \.memory, format: Fmt.bytes, color: Self.appColor)
                }
            }
        }
    }

    /// Apps that have been growing steadily for hours (e.g. a memory leak).
    private var growing: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                CardTitle("Growing steadily")
                ForEach(model.growingApps.prefix(3)) { app in
                    let g = app.growth
                    HStack(alignment: .top, spacing: 8) {
                        AppIcon(icon: app.icon)
                        Text("**\(app.name)** has grown by \(Fmt.bytes(g.perHour))/h for \(max(1, Int(g.duration / 3600))) h. Restarting it would free ~\(Fmt.bytes(g.gained))")
                            .font(.system(size: 11))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private var swapHistory: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    CardTitle("Swap")
                    RangePicker()
                }
                LineChart(series: [ChartSeries(name: "Swap", color: Self.swapColor, points: model.points(.swapUsed))],
                          height: 60, format: { $0 > 0 ? Fmt.bytes($0) : "0" })
                LineChart(series: [
                    ChartSeries(name: "In", color: Palette.download, points: model.points(.swapIn), filled: false),
                    ChartSeries(name: "Out", color: Palette.upload, points: model.points(.swapOut), filled: false),
                ], height: 50, format: ChartFormat.rate)
                HStack(spacing: 12) {
                    LegendDot(color: Self.swapColor, label: "Used")
                    LegendDot(color: Palette.download, label: "Swapped in/s")
                    LegendDot(color: Palette.upload, label: "Swapped out/s")
                }
            }
        }
    }

    /// Who is being pushed out of RAM? Footprint minus the resident part, for ordering.
    private var outOfRAM: some View {
        let apps = model.topApps(by: \.outOfRAM, limit: 5).filter { $0.outOfRAM >= 10_000_000 }
        let top = apps.first?.outOfRAM ?? 1
        return Card {
            VStack(alignment: .leading, spacing: 10) {
                CardTitle("Not in RAM")
                VStack(spacing: 7) {
                    ForEach(apps) { app in
                        HStack(spacing: 8) {
                            AppIcon(icon: app.icon)
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text(app.name).font(.system(size: 11)).lineLimit(1)
                                    Spacer()
                                    Text("~\(Fmt.bytes(app.outOfRAM))")
                                        .font(.system(size: 11, weight: .semibold))
                                        .monospacedDigit()
                                    Text("of \(Fmt.bytes(app.memory))")
                                        .font(.system(size: 10))
                                        .foregroundStyle(.tertiary)
                                        .monospacedDigit()
                                }
                                Meter(fraction: app.outOfRAM / top, color: Self.swapColor, height: 3)
                            }
                        }
                    }
                    if apps.isEmpty {
                        Text("Nothing notable right now").font(.system(size: 10)).foregroundStyle(.tertiary)
                    }
                }
                Text("Compressed or swapped out, roughly estimated (footprint minus the resident part). Good for comparison, not as an exact number.")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func pressureHint(_ m: MemoryReading) -> String {
        let swap = m.swapUsed > 0 ? "Swap \(Fmt.bytes(m.swapUsed))." : "No swap."
        switch m.pressure {
        case .normal: return "All good. \(swap)"
        case .warning: return "macOS is compressing and swapping. \(swap)"
        case .critical: return "Memory is running low, closing apps helps. \(swap)"
        }
    }

    private func breakdown(_ m: MemoryReading) -> some View {
        let parts: [(String, Double, Color)] = [
            ("Apps", m.app, Self.appColor),
            ("Wired", m.wired, Self.wiredColor),
            ("Compressed", m.compressed, Self.compressedColor),
            ("Cached", m.cached, Self.cachedColor),
        ]
        let total = max(m.total, 1)
        return Card {
            VStack(alignment: .leading, spacing: 10) {
                CardTitle("Breakdown")
                GeometryReader { geo in
                    HStack(spacing: 2) {
                        ForEach(parts, id: \.0) { part in
                            RoundedRectangle(cornerRadius: 3)
                                .fill(part.2)
                                .frame(width: max(2, (geo.size.width - 8) * part.1 / total))
                        }
                        RoundedRectangle(cornerRadius: 3).fill(.primary.opacity(0.08))
                    }
                }
                .frame(height: 12)
                .animation(.spring(duration: 0.5), value: m.used)
                VStack(spacing: 6) {
                    ForEach(parts, id: \.0) { part in
                        HStack {
                            LegendDot(color: part.2, label: part.0)
                            Spacer()
                            Text(Fmt.bytes(part.1)).font(.system(size: 11, weight: .semibold)).monospacedDigit()
                        }
                    }
                    HStack {
                        LegendDot(color: .primary.opacity(0.2), label: "Free")
                        Spacer()
                        Text(Fmt.bytes(m.free)).font(.system(size: 11, weight: .semibold)).monospacedDigit()
                    }
                    Divider().opacity(0.5)
                    StatRow(label: "Swap used", value: Fmt.bytes(m.swapUsed), systemImage: "arrow.triangle.swap",
                            detail: m.swapTotal > 0 ? "of \(Fmt.bytes(m.swapTotal))" : nil)
                }
            }
        }
    }
}

private struct AppIcon: View {
    var icon: NSImage?

    var body: some View {
        Group {
            if let icon {
                Image(nsImage: icon).resizable()
            } else {
                Image(systemName: "gearshape.2").resizable().scaledToFit().padding(2).foregroundStyle(.secondary)
            }
        }
        .frame(width: 16, height: 16)
    }
}
