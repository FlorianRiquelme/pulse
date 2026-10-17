import PulseCore
import SwiftUI

struct CPUView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 12) {
            hero
            if !model.backgroundHogs.isEmpty { hogs }
            history
            cores
            Card {
                VStack(alignment: .leading, spacing: 10) {
                    CardTitle("Top CPU usage", trailing: "in cores")
                    AppList(apps: model.topApps(by: \.cpu, limit: 6), value: \.cpu,
                            format: { Fmt.percent($0) }, color: Palette.cpu[0])
                }
            }
        }
    }

    private var hero: some View {
        let cpu = model.cpu
        return Card {
            HStack(spacing: 18) {
                Ring(progress: cpu.total, colors: Palette.cpu, label: Fmt.percent(cpu.total), caption: "CPU")
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Tile(label: "User", value: Fmt.percent(cpu.user), color: Palette.user)
                        Tile(label: "System", value: Fmt.percent(cpu.system), color: Palette.system)
                    }
                    HStack(spacing: 8) {
                        Tile(label: "GPU", value: model.gpu.map { Fmt.percent($0) } ?? "–", color: Palette.gpu)
                        Tile(label: "Load 1/5/15", value: [cpu.loadAverage.0, cpu.loadAverage.1, cpu.loadAverage.2]
                            .map { Fmt.number($0, digits: 1) }.joined(separator: " "))
                    }
                }
            }
        }
    }

    private var hogs: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                CardTitle("Busy for a long time", trailing: "in the background")
                ForEach(model.backgroundHogs) { hog in hogRow(hog) }
            }
        }
    }

    private func hogRow(_ hog: BackgroundHog) -> some View {
        let u = hog.usage
        var details = ["for \(Fmt.since(Date.now.timeIntervalSince(u.since)))", "\(Fmt.duration(u.cpuTime)) CPU time"]
        if u.power >= 0.05 { details.append("~" + Fmt.watts(u.power)) }
        if u.wakeups >= 50 { details.append("\(Int(u.wakeups.rounded())) wakeups/s") }
        return HStack(alignment: .top, spacing: 8) {
            Group {
                if let icon = hog.icon {
                    Image(nsImage: icon).resizable()
                } else {
                    Image(systemName: "gearshape.2").resizable().scaledToFit().padding(2).foregroundStyle(.secondary)
                }
            }
            .frame(width: 16, height: 16)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(hog.name).font(.system(size: 11, weight: .medium)).lineLimit(1)
                    Spacer()
                    Text(Fmt.percent(u.cpu))
                        .font(.system(size: 11, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(Palette.load(u.cpu))
                }
                Text(details.joined(separator: " · "))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(2)
                HStack(spacing: 6) {
                    if model.confirmQuit == hog.id {
                        Text("Quit \(hog.name)?").font(.system(size: 10)).foregroundStyle(.secondary)
                        Spacer()
                        hogButton("Quit") { model.quit(hog.id, force: false) }
                        hogButton("Force Quit", color: .red) { model.quit(hog.id, force: true) }
                        hogButton("Cancel", color: .secondary) { model.confirmQuit = nil }
                    } else {
                        hogButton("Quit") { model.confirmQuit = hog.id }
                        hogButton("Show in Finder", color: .secondary) { model.revealInFinder(hog.id) }
                    }
                }
                .padding(.top, 1)
            }
        }
    }

    private func hogButton(_ title: String, color: Color = Palette.user, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.12)))
    }

    private var history: some View {
        let showSplit = model.range == .live
        return Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    CardTitle("History")
                    RangePicker()
                }
                LineChart(series: showSplit ? [
                    ChartSeries(name: "Total", color: Palette.user, points: model.points(.cpu)),
                    ChartSeries(name: "System", color: Palette.system, points: model.points(.cpuSystem)),
                    ChartSeries(name: "GPU", color: Palette.gpu, points: model.points(.gpu), filled: false),
                ] : [
                    ChartSeries(name: "CPU", color: Palette.user, points: model.points(.cpu)),
                    ChartSeries(name: "GPU", color: Palette.gpu, points: model.points(.gpu), filled: false),
                ], yDomain: 0...1, height: 100, format: ChartFormat.percent)
                HStack(spacing: 12) {
                    LegendDot(color: Palette.user, label: "CPU")
                    if showSplit { LegendDot(color: Palette.system, label: "of which system") }
                    LegendDot(color: Palette.gpu, label: "GPU")
                }
            }
        }
    }

    private var cores: some View {
        let perCore = model.cpu.perCore
        let e = min(model.efficiencyCores, perCore.count)
        return Card {
            VStack(alignment: .leading, spacing: 10) {
                CardTitle("Cores", trailing: "\(perCore.count) cores")
                HStack(alignment: .bottom, spacing: 14) {
                    if e > 0 { coreGroup("Efficiency", Array(perCore[..<e])) }
                    coreGroup(e > 0 ? model.performanceName : "Cores", Array(perCore[e...]))
                }
            }
        }
    }

    private func coreGroup(_ title: String, _ values: [Double]) -> some View {
        let average = values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
        return VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(Array(values.enumerated()), id: \.offset) { _, v in
                    ZStack(alignment: .bottom) {
                        RoundedRectangle(cornerRadius: 3).fill(.primary.opacity(0.07))
                        RoundedRectangle(cornerRadius: 3)
                            .fill(LinearGradient(colors: [Palette.load(v), Palette.load(v).opacity(0.6)], startPoint: .top, endPoint: .bottom))
                            .frame(height: max(2, 54 * v))
                            .animation(.spring(duration: 0.4), value: v)
                    }
                    .frame(height: 54)
                }
            }
            HStack {
                Text(title).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                Spacer()
                Text(Fmt.percent(average)).font(.system(size: 10, weight: .semibold)).monospacedDigit()
            }
        }
        .frame(maxWidth: .infinity)
    }
}
