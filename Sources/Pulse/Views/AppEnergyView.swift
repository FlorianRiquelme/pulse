import AppKit
import Charts
import PulseCore
import SwiftUI

enum EnergyRange: String, CaseIterable, Identifiable {
    case today, week
    var id: String { rawValue }
    var label: String { self == .today ? "Today" : "7 days" }
}

/// Name and icon for a powerlog key (bundle ID or launchd name).
@MainActor
enum AppNames {
    struct Label {
        var name: String
        var icon: NSImage?
        /// A real app that can be quit (not a system service).
        var isApp: Bool
    }

    private static var cache: [String: Label] = [:]

    static func label(_ key: String) -> Label {
        if let known = cache[key] { return known }
        let label: Label
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: key) {
            var name = FileManager.default.displayName(atPath: url.path)
            if name.hasSuffix(".app") { name.removeLast(4) }
            let system = url.path.hasPrefix("/System/Library/") && !url.path.hasPrefix("/System/Library/CoreServices/Finder")
            label = Label(name: name, icon: ProcessSampler.thumbnail(NSWorkspace.shared.icon(forFile: url.path)),
                          isApp: url.pathExtension == "app" && !system)
        } else if let app = daemonApp(key) {
            // An app's service, e.g. "com.microsoft.fresno" → Microsoft Defender
            var name = FileManager.default.displayName(atPath: app.path)
            if name.hasSuffix(".app") { name.removeLast(4) }
            label = Label(name: name, icon: ProcessSampler.thumbnail(NSWorkspace.shared.icon(forFile: app.path)), isApp: false)
        } else {
            // System processes: "com.apple.audio.coreaudiod" → "coreaudiod"
            label = Label(name: key.split(separator: ".").last.map(String.init) ?? key, icon: nil, isApp: false)
        }
        cache[key] = label
        return label
    }

    /// The app a launchd service is started from (program path from its plist).
    private static func daemonApp(_ label: String) -> URL? {
        let folders = ["/Library/LaunchDaemons", "/Library/LaunchAgents", NSHomeDirectory() + "/Library/LaunchAgents"]
        for folder in folders {
            guard let plist = NSDictionary(contentsOfFile: "\(folder)/\(label).plist") else { continue }
            let program = plist["Program"] as? String ?? (plist["ProgramArguments"] as? [String])?.first
            guard let program, let range = program.range(of: ".app/") else { return nil }
            return URL(fileURLWithPath: String(program[..<range.lowerBound]) + ".app")
        }
        return nil
    }
}

private let energyColors = [
    Color(red: 0.10, green: 0.70, blue: 0.85), Color(red: 0.20, green: 0.85, blue: 0.55), Color(red: 1.00, green: 0.65, blue: 0.25),
    Color(red: 0.75, green: 0.45, blue: 1.00), Color(red: 1.00, green: 0.42, blue: 0.55),
]
private let restColor = Color.gray.opacity(0.45)

private func wh(_ v: Double) -> String { "\(Fmt.number(v, digits: v < 10 ? (v < 0.1 ? 2 : 1) : 0)) Wh" }

/// Small toggle in the style of the range picker.
private struct Segmented<Value: Hashable>: View {
    var options: [(Value, String)]
    var selection: Value
    var select: (Value) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.0) { value, label in
                let selected = value == selection
                Button { select(value) } label: {
                    Text(label)
                        .font(.system(size: 10, weight: selected ? .semibold : .regular))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(selected ? Color.primary.opacity(0.12) : .clear))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .foregroundStyle(selected ? .primary : .secondary)
            }
        }
    }
}

// MARK: Energy per app (day/week)

struct AppEnergyCard: View {
    @Environment(AppModel.self) private var model

    private struct Bar: Identifiable {
        var key: String
        var name: String
        var wh: Double
        var color: Color
        var id: String { key }
    }

    private struct DayBar: Identifiable {
        var day: Date
        var name: String
        var wh: Double
        var id: String { "\(day.timeIntervalSinceReferenceDate)-\(name)" }
    }

    var body: some View {
        let week = model.energyRange == .week
        let days = model.appEnergy.map { week ? $0.days : $0.days.filter { Calendar.current.isDateInToday($0.day) } } ?? []
        let ranking = AppEnergyLedger.ranking(days, batteryOnly: model.energyBatteryOnly)
        let total = ranking.reduce(0) { $0 + $1.wh }
        let top = Array(ranking.prefix(5))
        let rest = total - top.reduce(0) { $0 + $1.wh }
        var bars = top.enumerated().map { i, entry in
            Bar(key: entry.key, name: AppNames.label(entry.key).name, wh: entry.wh, color: energyColors[i])
        }
        if rest > 0.005 { bars.append(Bar(key: "", name: "Other", wh: rest, color: restColor)) }

        return Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    CardTitle(week ? "Energy use this week" : "Energy use today")
                    Segmented(options: EnergyRange.allCases.map { ($0, $0.label) }, selection: model.energyRange) {
                        model.energyRange = $0
                    }
                }
                if model.appEnergy == nil {
                    Text("Reading powerlog …").font(.system(size: 10)).foregroundStyle(.tertiary)
                } else if bars.isEmpty {
                    Text(model.energyBatteryOnly ? "The Mac did not run on battery in this period." : "No data in powerlog yet.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                } else {
                    Text(sentence(top: top.first, total: total, days: days.count, week: week))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    barChart(bars)
                    if week { weekChart(days, top: top) }
                }
                HStack {
                    Text("Includes system processes and time without Pulse. CPU, GPU and Neural Engine only.")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    Segmented(options: [(false, "All"), (true, "Battery")], selection: model.energyBatteryOnly) {
                        model.energyBatteryOnly = $0
                    }
                }
            }
        }
    }

    private func sentence(top: (key: String, wh: Double)?, total: Double, days: Int, week: Bool) -> String {
        let span = week ? "Over \(days == 1 ? "1 day" : "\(days) days")," : "Today,"
        let where_ = model.energyBatteryOnly ? " on battery" : ""
        var text = "\(span) apps used \(wh(total))\(where_)."
        if let top, total > 0 {
            text += " Most was \(AppNames.label(top.key).name) with \(wh(top.wh)) (\(Fmt.percent(top.wh / total)))."
        }
        return text
    }

    private func barChart(_ bars: [Bar]) -> some View {
        let maxWh = bars.map(\.wh).max() ?? 1
        return Chart(bars) { bar in
            BarMark(x: .value("Wh", bar.wh), y: .value("App", bar.name), height: .fixed(10))
                .foregroundStyle(bar.color)
                .clipShape(Capsule())
                .annotation(position: .trailing, spacing: 4) {
                    Text(wh(bar.wh)).font(.system(size: 9, weight: .medium)).monospacedDigit().foregroundStyle(.secondary)
                }
        }
        .chartXScale(domain: 0...(maxWh * 1.3))
        .chartXAxis(.hidden)
        .chartYAxis {
            AxisMarks(preset: .aligned, position: .leading) { value in
                AxisValueLabel(horizontalSpacing: 6) {
                    if let name = value.as(String.self) { Text(name).font(.system(size: 10)) }
                }
            }
        }
        .chartLegend(.hidden)
        .frame(height: CGFloat(bars.count) * 20)
    }

    private func weekChart(_ days: [DayEnergy], top: [(key: String, wh: Double)]) -> some View {
        let names = top.map { AppNames.label($0.key).name }
        var points: [DayBar] = []
        for day in days {
            let apps = day.apps(batteryOnly: model.energyBatteryOnly)
            var rest = apps.values.reduce(0, +)
            for (i, entry) in top.enumerated() {
                let v = apps[entry.key] ?? 0
                rest -= v
                points.append(DayBar(day: day.day, name: names[i], wh: v))
            }
            points.append(DayBar(day: day.day, name: "Other", wh: max(0, rest)))
        }
        return VStack(alignment: .leading, spacing: 4) {
            Text("Per day").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
            Chart(points) { p in
                BarMark(x: .value("Day", p.day, unit: .day), y: .value("Wh", p.wh))
                    .foregroundStyle(by: .value("App", p.name))
            }
            .chartForegroundStyleScale(domain: names + ["Other"], range: Array(energyColors.prefix(names.count)) + [restColor])
            .chartLegend(.hidden)
            .chartXAxis {
                AxisMarks(values: .stride(by: .day)) { value in
                    AxisValueLabel {
                        if let d = value.as(Date.self) {
                            Text(Fmt.weekday(d)).font(.system(size: 8))
                        }
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { value in
                    AxisGridLine().foregroundStyle(.primary.opacity(0.06))
                    AxisValueLabel { if let v = value.as(Double.self) { Text(wh(v)).font(.system(size: 8)) } }
                }
            }
            .frame(height: 90)
        }
    }
}

// MARK: Quitting saves …

struct WhatIfCard: View {
    @Environment(AppModel.self) private var model
    var battery: BatteryReading

    private struct Gain: Identifiable {
        var key: String
        var name: String
        var icon: NSImage?
        var watts: Double
        var gain: TimeInterval
        var id: String { key }
    }

    var body: some View {
        if let systemW = model.estimate.recentPowerW ?? model.estimate.nowPowerW, let recent = model.appEnergy?.recentW,
           let runtime = model.estimate.best {
            let remaining = battery.remainingWh
            let gains = recent.sorted { $0.value > $1.value }.compactMap { key, w -> Gain? in
                let label = AppNames.label(key)
                guard label.isApp, let gain = BatteryEstimator.whatIf(remainingWh: remaining, systemPowerW: systemW, appPowerW: w),
                      gain >= 5 * 60 else { return nil }
                return Gain(key: key, name: label.name, icon: label.icon, watts: w, gain: gain)
            }.prefix(4)
            let share = recent.values.reduce(0, +) / systemW
            if !gains.isEmpty {
                card(Array(gains), systemW: systemW, runtime: runtime, share: share)
            }
        }
    }

    private func card(_ gains: [Gain], systemW: Double, runtime: TimeInterval, share: Double) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                CardTitle("Quitting saves …", trailing: "estimated")
                ForEach(gains) { g in
                    HStack(spacing: 8) {
                        Group {
                            if let icon = g.icon { Image(nsImage: icon).resizable() } else { Image(systemName: "app").resizable() }
                        }
                        .frame(width: 16, height: 16)
                        Text("Quit \(g.name)").font(.system(size: 12)).lineLimit(1)
                        Text(Fmt.watts(g.watts)).font(.system(size: 10)).foregroundStyle(.tertiary).monospacedDigit()
                        Spacer()
                        Text("+\(Fmt.duration(g.gain))").font(.system(size: 12, weight: .semibold)).monospacedDigit()
                            .foregroundStyle(Palette.battery[0])
                    }
                }
                if gains.count >= 2,
                   let both = BatteryEstimator.whatIf(remainingWh: battery.remainingWh, systemPowerW: systemW,
                                                      appPowerW: gains[0].watts + gains[1].watts) {
                    Text("Without \(gains[0].name) + \(gains[1].name): until \(Fmt.clock(.now.addingTimeInterval(runtime + both))) instead of \(Fmt.clock(.now.addingTimeInterval(runtime)))")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Text("Based on the apps' usage in the last hour. CPU/GPU share only: apps account for \(Fmt.percent(min(1, share))) of your \(Fmt.watts(systemW)); the display and radios keep running.")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
