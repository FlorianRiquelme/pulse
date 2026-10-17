import Charts
import PulseCore
import SwiftUI

enum Palette {
    static let battery = [Color(red: 0.20, green: 0.90, blue: 0.55), Color(red: 0.10, green: 0.70, blue: 0.85)]
    static let cpu = [Color(red: 0.30, green: 0.75, blue: 1.00), Color(red: 0.40, green: 0.45, blue: 1.00)]
    static let memory = [Color(red: 0.75, green: 0.45, blue: 1.00), Color(red: 1.00, green: 0.40, blue: 0.70)]
    static let sensors = [Color(red: 1.00, green: 0.65, blue: 0.25), Color(red: 1.00, green: 0.35, blue: 0.35)]
    static let network = [Color(red: 0.25, green: 0.85, blue: 0.85), Color(red: 0.30, green: 0.55, blue: 1.00)]

    static let user = Color(red: 0.30, green: 0.65, blue: 1.00)
    static let system = Color(red: 1.00, green: 0.42, blue: 0.40)
    static let gpu = Color(red: 0.70, green: 0.45, blue: 1.00)
    static let download = Color(red: 0.30, green: 0.60, blue: 1.00)
    static let upload = Color(red: 1.00, green: 0.45, blue: 0.40)

    static func colors(_ section: Section) -> [Color] {
        switch section {
        case .battery: battery
        case .cpu: cpu
        case .memory: memory
        case .sensors: sensors
        case .network: network
        }
    }

    static func battery(level: Double, charging: Bool) -> [Color] {
        if charging { return battery }
        switch level {
        case ..<0.1: return [Color(red: 1.00, green: 0.35, blue: 0.35), Color(red: 0.95, green: 0.20, blue: 0.50)]
        case ..<0.2: return [Color(red: 1.00, green: 0.75, blue: 0.25), Color(red: 1.00, green: 0.45, blue: 0.20)]
        default: return battery
        }
    }

    static func load(_ v: Double) -> Color {
        switch v {
        case ..<0.5: Color(red: 0.30, green: 0.75, blue: 1.00)
        case ..<0.8: .orange
        default: .red
        }
    }

    static func temperature(_ c: Double) -> Color {
        switch c {
        case ..<50: Color(red: 0.30, green: 0.80, blue: 0.60)
        case ..<70: Color(red: 1.00, green: 0.75, blue: 0.25)
        case ..<90: .orange
        default: .red
        }
    }

    static func pressure(_ p: MemoryPressure) -> Color {
        switch p {
        case .normal: .green
        case .warning: .orange
        case .critical: .red
        }
    }
}

struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.primary.opacity(0.045))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(.primary.opacity(0.07), lineWidth: 1)
            )
    }
}

/// Small uppercase heading, optionally with a value on the right.
struct CardTitle: View {
    var title: String
    var trailing: String?

    init(_ title: String, trailing: String? = nil) {
        self.title = title
        self.trailing = trailing
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .kerning(0.6)
            Spacer()
            if let trailing {
                Text(trailing)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }
}

/// Large value with a ring, like the Activity rings.
struct Ring: View {
    var progress: Double
    var colors: [Color]
    var lineWidth: CGFloat = 9
    var size: CGFloat = 86
    var label: String
    var caption: String?

    var body: some View {
        ZStack {
            Circle().stroke(.primary.opacity(0.08), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.001, min(1, progress)))
                .stroke(LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .shadow(color: colors[0].opacity(0.45), radius: 6)
                .padding(8)
                .drawingGroup() // draw on the GPU instead of rendering gradient and shadow on the CPU
                .padding(-8)
                .animation(.spring(duration: 0.6), value: progress)
            VStack(spacing: 0) {
                Text(label)
                    .font(.system(size: size * 0.24, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                if let caption {
                    Text(caption)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: size, height: size)
    }
}

/// Horizontal bar 0–1.
struct Meter: View {
    var fraction: Double
    var color: Color
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.primary.opacity(0.08))
                Capsule()
                    .fill(LinearGradient(colors: [color.opacity(0.75), color], startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(height, geo.size.width * min(1, max(0, fraction))))
                    .animation(.spring(duration: 0.5), value: fraction)
            }
        }
        .frame(height: height)
    }
}

struct StatRow: View {
    var label: String
    var value: String
    var systemImage: String?
    var detail: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
            }
            Text(label).font(.system(size: 12))
            Spacer(minLength: 8)
            if let detail {
                Text(detail).font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            Text(value)
                .font(.system(size: 12, weight: .semibold))
                .monospacedDigit()
        }
    }
}

/// Small tile with a value and a label.
struct Tile: View {
    var label: String
    var value: String
    var color: Color = .primary

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.primary.opacity(0.05)))
    }
}

struct Chip: View {
    var text: String
    var color: Color
    var systemImage: String?

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage { Image(systemName: systemImage).font(.system(size: 9, weight: .bold)) }
            Text(text).font(.system(size: 10, weight: .semibold))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Capsule().fill(color.opacity(0.14)))
    }
}

struct RangePicker: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 2) {
            ForEach(ChartRange.allCases) { range in
                let selected = model.range == range
                Button {
                    model.range = range
                } label: {
                    Text(range.label)
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

/// One data set for a line chart. Gaps (sleep) split the line into segments.
struct ChartSeries {
    var name: String
    var color: Color
    var points: [Point]
    var filled = true
}

private struct SegmentedPoint: Identifiable {
    var series: String
    var segment: Int
    var t: Date
    var v: Double
    var id: String { "\(series)-\(t.timeIntervalSinceReferenceDate)" }
}

struct LineChart: View {
    var series: [ChartSeries]
    var yDomain: ClosedRange<Double>?
    var height: CGFloat = 90
    var format: (Double) -> String
    var reference: Double?
    var xDomain: ClosedRange<Date>?

    private func segmented(_ s: ChartSeries) -> [SegmentedPoint] {
        guard s.points.count > 1 else { return [] }
        let span = (s.points.last!.t.timeIntervalSince(s.points.first!.t))
        let gap = max(180, span / 60)
        var segment = 0
        var result: [SegmentedPoint] = []
        var previous: Date?
        for p in s.points {
            if let previous, p.t.timeIntervalSince(previous) > gap { segment += 1 }
            result.append(SegmentedPoint(series: s.name, segment: segment, t: p.t, v: p.v))
            previous = p.t
        }
        return result
    }

    var body: some View {
        let all = series.map { ($0, segmented($0)) }
        Chart {
            ForEach(all, id: \.0.name) { s, points in
                ForEach(points) { p in
                    if s.filled {
                        AreaMark(x: .value("Time", p.t), y: .value(s.name, p.v),
                                 series: .value("Segment", "\(s.name)-\(p.segment)"), stacking: .unstacked)
                            .foregroundStyle(LinearGradient(colors: [s.color.opacity(0.35), s.color.opacity(0.02)],
                                                            startPoint: .top, endPoint: .bottom))
                            .interpolationMethod(.monotone)
                    }
                    LineMark(x: .value("Time", p.t), y: .value(s.name, p.v),
                             series: .value("Segment", "\(s.name)-\(p.segment)"))
                        .foregroundStyle(s.color)
                        .lineStyle(StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                        .interpolationMethod(.monotone)
                }
            }
            if let reference {
                RuleMark(y: .value("Average", reference))
                    .foregroundStyle(.secondary.opacity(0.6))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
        }
        .chartYScale(domain: yDomain ?? autoDomain)
        .chartXScale(domain: xDomain ?? autoXDomain)
        .chartLegend(.hidden)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                AxisGridLine().foregroundStyle(.primary.opacity(0.06))
                AxisValueLabel(format: .dateTime.hour().minute(), centered: false)
                    .font(.system(size: 8))
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { value in
                AxisGridLine().foregroundStyle(.primary.opacity(0.06))
                AxisValueLabel {
                    if let v = value.as(Double.self) { Text(format(v)).font(.system(size: 8)) }
                }
            }
        }
        .frame(height: height)
        .overlay {
            if series.allSatisfy({ $0.points.count < 2 }) {
                Text("Collecting data …").font(.system(size: 10)).foregroundStyle(.tertiary)
            }
        }
    }

    private var autoDomain: ClosedRange<Double> {
        let values = series.flatMap { $0.points.map(\.v) }
        let hi = values.max() ?? 1
        return 0...(hi > 0 ? hi * 1.15 : 1)
    }

    private var autoXDomain: ClosedRange<Date> {
        let dates = series.flatMap { $0.points.map(\.t) }
        guard let lo = dates.min(), let hi = dates.max(), lo < hi else { return Date.now.addingTimeInterval(-60)...Date.now }
        return lo...hi
    }
}

/// List of the apps with the highest usage.
struct AppList: View {
    var apps: [AppUsage]
    var value: (AppUsage) -> Double
    var format: (Double) -> String
    var color: Color
    /// Smaller values are hidden (they would show up as "0.0").
    var minimum: Double = 0.005

    var body: some View {
        let top = apps.map(value).max() ?? 1
        let apps = apps.filter { value($0) >= minimum }
        VStack(spacing: 7) {
            ForEach(apps) { app in
                HStack(spacing: 8) {
                    Group {
                        if let icon = app.icon {
                            Image(nsImage: icon).resizable()
                        } else {
                            Image(systemName: "gearshape.2").resizable().scaledToFit().padding(2).foregroundStyle(.secondary)
                        }
                    }
                    .frame(width: 16, height: 16)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(app.name).font(.system(size: 11)).lineLimit(1)
                            Spacer()
                            Text(format(value(app)))
                                .font(.system(size: 11, weight: .semibold))
                                .monospacedDigit()
                        }
                        Meter(fraction: top > 0 ? value(app) / top : 0, color: color, height: 3)
                    }
                }
            }
            if apps.isEmpty {
                Text("Nothing notable right now").font(.system(size: 10)).foregroundStyle(.tertiary)
            }
        }
    }
}

struct LegendDot: View {
    var color: Color
    var label: String

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label).font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }
}

enum ChartFormat {
    static func percent(_ v: Double) -> String { "\(Int((v * 100).rounded()))%" }
    static func percentPoints(_ v: Double) -> String { "\(Int(v.rounded()))%" }
    static func watts(_ v: Double) -> String { "\(Fmt.number(v, digits: v < 10 ? 1 : 0)) W" }
    static func celsius(_ v: Double) -> String { "\(Int(v.rounded()))°" }
    static func rate(_ v: Double) -> String { Fmt.rateCompact(v) }
}
