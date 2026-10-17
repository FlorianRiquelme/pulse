import Charts
import PulseCore
import SwiftUI

struct BatteryView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let battery = model.battery {
            VStack(spacing: 12) {
                hero(battery)
                if !model.keepAwake.isEmpty { keepAwake(battery) }
                let runway = model.workdayRunway()
                if let runway { workday(runway) }
                if !battery.plugged { forecasts(battery) }
                levelChart(battery, endOfDay: runway?.endOfDay)
                powerChart(battery)
                drainers
                if !battery.plugged { WhatIfCard(battery: battery) }
                AppEnergyCard()
                if let session = model.lastSession { sessionCard(session, battery: battery) }
                if let last = model.sleeps.last(where: { $0.duration >= 10 * 60 }) { sleepCard(last) }
                health(battery)
            }
        } else {
            Card { Text("No battery found").foregroundStyle(.secondary) }
        }
    }

    // MARK: Hero

    private func hero(_ b: BatteryReading) -> some View {
        let level = b.percent / 100
        return Card {
            HStack(spacing: 18) {
                Ring(progress: level, colors: Palette.battery(level: level, charging: b.plugged),
                     label: Fmt.percent(level), caption: b.charging ? "charging" : b.plugged ? "adapter" : "battery")
                VStack(alignment: .leading, spacing: 4) {
                    Text(heroTitle(b))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                        .kerning(0.6)
                    Text(heroValue(b))
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Text(heroSubtitle(b))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 6) {
                        if model.lowPowerMode { Chip(text: "Low Power", color: .yellow, systemImage: "leaf.fill") }
                        if b.chargingPaused { Chip(text: "Charging paused", color: .orange, systemImage: "pause.fill") }
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func heroTitle(_ b: BatteryReading) -> String {
        if b.charging { return "Full in" }
        if b.plugged { return "On power adapter" }
        return "Time remaining"
    }

    private func heroValue(_ b: BatteryReading) -> String {
        if b.charging {
            let own = BatteryEstimator.timeToFull(remainingWh: b.remainingWh, fullWh: b.fullWh, chargePowerW: -b.batteryPowerW)
            return (b.macTimeToFull ?? own).map(Fmt.duration) ?? "…"
        }
        if b.plugged { return b.fullyCharged ? "Full" : Fmt.percent(b.percent / 100) }
        return model.estimate.best.map(Fmt.duration) ?? "…"
    }

    private func heroSubtitle(_ b: BatteryReading) -> String {
        if b.charging {
            let watts = b.adapterWatts.map { " on a \($0) W adapter" } ?? ""
            return "Charging at \(Fmt.watts(-b.batteryPowerW))\(watts)"
        }
        if b.plugged {
            let load = b.systemLoadW.map { "System draws \(Fmt.watts($0))" } ?? ""
            return b.chargingPaused ? "Charging paused (optimized charging / charge limit). \(load)" : load
        }
        guard let t = model.estimate.best else { return "Measuring usage …" }
        let basis = model.estimate.recent != nil
            ? "at your usage over the last \(model.estimate.recentMinutes) min"
            : "at current usage"
        let power = (model.estimate.recentPowerW ?? model.estimate.nowPowerW).map { " (avg \(Fmt.watts($0)))" } ?? ""
        return "Until about \(Fmt.clock(.now.addingTimeInterval(t))), \(basis)\(power)"
    }

    // MARK: Keeping awake

    private func keepAwake(_ b: BatteryReading) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                CardTitle("Keeping the Mac awake")
                ForEach(model.keepAwake) { app in
                    HStack(spacing: 8) {
                        Group {
                            if let icon = app.icon {
                                Image(nsImage: icon).resizable()
                            } else {
                                Image(systemName: "gearshape.2").resizable().scaledToFit().padding(2).foregroundStyle(.secondary)
                            }
                        }
                        .frame(width: 16, height: 16)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("**\(app.name)** \(app.blocker.phrase)")
                                .font(.system(size: 12))
                                .fixedSize(horizontal: false, vertical: true)
                            Text(keepAwakeDetail(app))
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer(minLength: 4)
                        if app.canActivate {
                            Button("Show") { model.activate(app) }
                                .buttonStyle(.plain)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Capsule().fill(.primary.opacity(0.06)))
                        }
                    }
                }
                Text(b.plugged ? "So the Mac won't go to sleep on its own."
                               : "So the Mac won't go to sleep on its own and keeps draining the battery.")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func keepAwakeDetail(_ app: KeepAwakeApp) -> String {
        let since = "for \(Fmt.duration(Date.now.timeIntervalSince(app.blocker.since)))"
        return app.blocker.detail.map { "\(since) · \($0)" } ?? since
    }

    // MARK: End of workday

    private func workday(_ r: WorkdayRunway) -> some View {
        let color: Color = r.fits ? .green : .orange
        let verdict = r.fits
            ? "Battery lasts until \(Fmt.clock(r.batteryEnd)) ✓"
            : "only lasts until \(Fmt.clock(r.batteryEnd)), " + (r.chargeNeeded.map { "charge for \(Fmt.duration($0))" } ?? "power adapter needed")
        return Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "briefcase").font(.system(size: 11)).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("End of workday ≈ \(Fmt.clock(r.endOfDay))").font(.system(size: 13, weight: .semibold))
                        Text(verdict).font(.system(size: 12, weight: .medium)).foregroundStyle(color)
                    }
                    Spacer(minLength: 0)
                }
                .monospacedDigit()
                runwayBar(r, color: color)
                Text(workdayFootnote(r))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    /// Timeline from now to the later of end of workday and empty battery.
    private func runwayBar(_ r: WorkdayRunway, color: Color) -> some View {
        let now = Date.now
        let span = max(r.endOfDay, r.batteryEnd).timeIntervalSince(now)
        let battery = r.batteryEnd.timeIntervalSince(now) / span
        let workday = r.endOfDay.timeIntervalSince(now) / span
        return VStack(spacing: 3) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.primary.opacity(0.08))
                    Capsule().fill(color.opacity(0.75)).frame(width: geo.size.width * battery)
                    RoundedRectangle(cornerRadius: 1)
                        .fill(.primary)
                        .frame(width: 2, height: 12)
                        .offset(x: geo.size.width * workday - 1)
                }
            }
            .frame(height: 8)
            HStack {
                Text("now")
                Spacer()
                Text(r.fits ? "empty \(Fmt.clock(r.batteryEnd))" : "end of workday \(Fmt.clock(r.endOfDay))")
            }
            .font(.system(size: 9))
            .foregroundStyle(.tertiary)
            .monospacedDigit()
        }
    }

    private func workdayFootnote(_ r: WorkdayRunway) -> String {
        let target = "Daily target \(Fmt.duration(model.workRules.dailyTarget)) per Stempeluhr"
        guard let typical = r.typicalEnd else { return target }
        let fits = typical >= r.endOfDay ? "enough" : "not enough"
        return "\(target). At typical usage until \(Fmt.clock(typical)) (\(fits))."
    }

    // MARK: Forecasts

    private func forecasts(_ b: BatteryReading) -> some View {
        let e = model.estimate
        return Card {
            VStack(alignment: .leading, spacing: 9) {
                CardTitle("Forecasts")
                forecastRow("Right now", detail: e.nowPowerW.map(Fmt.watts), time: e.now, symbol: "bolt")
                forecastRow(e.recentMinutes > 0 ? "Last \(e.recentMinutes) min" : "Last 30 min", detail: e.recentPowerW.map(Fmt.watts), time: e.recent,
                            symbol: "clock", placeholder: "after 3 min on battery")
                forecastRow("Typical for you", detail: e.typicalPowerW.map(Fmt.watts), time: e.typical,
                            symbol: "person.crop.circle", placeholder: "after 1 h of battery data")
                rhythmRow(model.rhythm)
                forecastRow("macOS", detail: nil, time: b.macTimeToEmpty, symbol: "apple.logo")
                if let full = e.fullChargeRuntime {
                    Divider().opacity(0.5)
                    Text("At your typical usage, a full battery lasts about **\(Fmt.duration(full))**.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func forecastRow(_ label: String, detail: String?, time: TimeInterval?, symbol: String, placeholder: String = "–") -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 16)
            Text(label).font(.system(size: 12))
            if let detail { Text(detail).font(.system(size: 10)).foregroundStyle(.tertiary).monospacedDigit() }
            Spacer()
            if let time {
                Text(Fmt.duration(time)).font(.system(size: 12, weight: .semibold)).monospacedDigit()
                Text("until \(Fmt.clock(.now.addingTimeInterval(time)))")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
                    .frame(width: 76, alignment: .trailing)
            } else {
                Text(placeholder).font(.system(size: 10)).foregroundStyle(.tertiary)
            }
        }
    }

    /// Forecast by time of day: most likely time and the band "empty between … and …".
    private func rhythmRow(_ r: RhythmForecast?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            forecastRow(r?.byHour == false ? "With spread" : "By time of day", detail: nil, time: r?.median,
                        symbol: "calendar.day.timeline.left", placeholder: r == nil ? "after 1 h of battery data" : "over 2 days")
            if let r, let early = r.early {
                let from = Self.rounded(.now.addingTimeInterval(early), up: false)
                let range = r.late.map { late in
                    let to = Self.rounded(.now.addingTimeInterval(late), up: true)
                    let day = Self.day(from)
                    return day == Self.day(to)
                        ? "empty \(day)between \(Fmt.clock(from)) and \(Fmt.clock(to))"
                        : "empty between \(day)\(Fmt.clock(from)) and \(Self.day(to))\(Fmt.clock(to))"
                } ?? "empty \(Self.day(from))\(Fmt.clock(from)) at the earliest"
                let low = r.low.map { Self.rounded(.now.addingTimeInterval($0), up: false) }
                    .map { " · 20% \(Self.day($0))at \(Fmt.clock($0))" } ?? ""
                Text(range + low + (r.byHour ? "" : " (not enough data per hour yet)"))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 24)
            }
        }
    }

    /// Rounded to 10 minutes; the band should not pretend to be more precise than it is.
    private static func rounded(_ date: Date, up: Bool) -> Date {
        let x = date.timeIntervalSinceReferenceDate / 600
        return Date(timeIntervalSinceReferenceDate: (up ? x.rounded(.up) : x.rounded(.down)) * 600)
    }

    /// "" for today, otherwise "tomorrow " or the weekday.
    private static func day(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "" }
        if calendar.isDateInTomorrow(date) { return "tomorrow " }
        return Fmt.weekday(date) + " "
    }

    // MARK: Charge history with forecast

    private func levelChart(_ b: BatteryReading, endOfDay: Date?) -> some View {
        let window: TimeInterval = model.range == .day ? 24 * 3600 : 4 * 3600
        let start = Date.now.addingTimeInterval(-window)
        let points = Self.segmented(model.points(.batteryPercent, range: .day).filter { $0.t >= start })
        let spans = model.pluggedSpans(since: start)
        let rhythm = b.plugged ? nil : model.rhythm
        let sleeps = model.sleeps.filter { $0.end > start }
        // With an end of workday, look ahead until then (at most as far as back).
        let untilEndOfDay = endOfDay.map { min($0.timeIntervalSinceNow + 10 * 60, window) } ?? 0
        let horizon = max(window / 2, untilEndOfDay)
        let prediction = rhythm.map { $0.late ?? BatteryEstimator.rhythmHorizon } ?? model.estimate.best
        let projection: TimeInterval? = b.plugged ? nil : prediction.map { min($0, horizon) }
        let end = Date.now.addingTimeInterval(max(projection ?? 0, untilEndOfDay))
        let marker = endOfDay.flatMap { $0 <= end ? $0 : nil }
        let colors = Palette.battery(level: b.percent / 100, charging: b.plugged)

        return Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    CardTitle("Charge level")
                    RangePicker()
                }
                Chart {
                    ForEach(Array(spans.enumerated()), id: \.offset) { _, span in
                        RectangleMark(xStart: .value("Start", span.lowerBound), xEnd: .value("End", span.upperBound),
                                      yStart: .value("Min", 0), yEnd: .value("Max", 100))
                            .foregroundStyle(Color.green.opacity(0.08))
                    }
                    // Sleep: gray band with the drop instead of a line across the gap
                    ForEach(Array(sleeps.enumerated()), id: \.offset) { _, sleep in
                        RectangleMark(xStart: .value("Start", max(sleep.start, start)), xEnd: .value("End", sleep.end),
                                      yStart: .value("Min", 0), yEnd: .value("Max", 100))
                            .foregroundStyle(Color.secondary.opacity(0.12))
                            .annotation(position: .overlay, alignment: .top) {
                                if sleep.end.timeIntervalSince(max(sleep.start, start)) >= window / 10 {
                                    Text(sleep.drop.map(Self.dropText) ?? "zzz")
                                        .font(.system(size: 8, weight: .medium))
                                        .foregroundStyle(.secondary)
                                        .padding(.top, 3)
                                }
                            }
                    }
                    ForEach(points, id: \.point.t) { s in
                        AreaMark(x: .value("Time", s.point.t), y: .value("Battery", s.point.v), series: .value("Segment", s.segment),
                                 stacking: .unstacked)
                            .foregroundStyle(LinearGradient(colors: [colors[0].opacity(0.4), colors[0].opacity(0.02)],
                                                            startPoint: .top, endPoint: .bottom))
                        LineMark(x: .value("Time", s.point.t), y: .value("Battery", s.point.v), series: .value("Segment", s.segment))
                            .foregroundStyle(colors[0])
                            .lineStyle(StrokeStyle(lineWidth: 1.8))
                    }
                    if let projection, let rhythm {
                        // Band between heavy and light usage, line = typical usage by time of day
                        let shown = rhythm.curve.filter { $0.t <= Date.now.addingTimeInterval(projection) }
                        ForEach(shown) { p in
                            AreaMark(x: .value("Time", p.t), yStart: .value("Min", p.low), yEnd: .value("Max", p.high),
                                     series: .value("S", "Band"))
                                .foregroundStyle(colors[0].opacity(0.2))
                        }
                        ForEach(shown) { p in
                            LineMark(x: .value("Time", p.t), y: .value("Forecast", p.median), series: .value("S", "Forecast"))
                                .foregroundStyle(colors[0].opacity(0.7))
                                .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                        }
                        RuleMark(x: .value("Now", Date.now))
                            .foregroundStyle(.secondary.opacity(0.4))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 2]))
                    } else if let projection, let t = model.estimate.best {
                        // Dashed forecast: from the current level to the end of the visible window
                        let shownEnd = Date.now.addingTimeInterval(projection)
                        let shownLevel = b.percent * (1 - projection / t)
                        LineMark(x: .value("Time", Date.now), y: .value("Forecast", b.percent), series: .value("S", "Forecast"))
                            .foregroundStyle(colors[0].opacity(0.7))
                            .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                        LineMark(x: .value("Time", shownEnd), y: .value("Forecast", max(0, shownLevel)), series: .value("S", "Forecast"))
                            .foregroundStyle(colors[0].opacity(0.7))
                            .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                        RuleMark(x: .value("Now", Date.now))
                            .foregroundStyle(.secondary.opacity(0.4))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 2]))
                    }
                    if let marker {
                        RuleMark(x: .value("End of workday", marker))
                            .foregroundStyle(Color.primary.opacity(0.55))
                            .lineStyle(StrokeStyle(lineWidth: 1.2))
                    }
                }
                .chartYScale(domain: 0...100)
                .chartXScale(domain: start...end)
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 5)) { _ in
                        AxisGridLine().foregroundStyle(.primary.opacity(0.06))
                        AxisValueLabel(format: .dateTime.hour().minute()).font(.system(size: 8))
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .trailing, values: [0, 50, 100]) { value in
                        AxisGridLine().foregroundStyle(.primary.opacity(0.06))
                        AxisValueLabel { Text("\(value.as(Int.self) ?? 0)%").font(.system(size: 8)) }
                    }
                }
                .frame(height: 110)
                HStack(spacing: 12) {
                    LegendDot(color: colors[0], label: "Charge level")
                    LegendDot(color: .green.opacity(0.5), label: "Power adapter")
                    if projection != nil {
                        LegendDot(color: colors[0].opacity(0.6), label: marker == nil ? "Forecast (dashed)" : "Forecast")
                    }
                    if marker != nil { LegendDot(color: .primary.opacity(0.55), label: "End of workday") }
                    if !sleeps.isEmpty { LegendDot(color: .secondary.opacity(0.5), label: "Sleep") }
                    if projection != nil, rhythm != nil { LegendDot(color: colors[0].opacity(0.25), label: "Spread") }
                }
            }
        }
    }

    /// Splits the points at gaps (sleep, Pulse not running) into segments so nothing gets bridged.
    private static func segmented(_ points: [Point]) -> [(segment: Int, point: Point)] {
        var segment = 0
        var previous: Date?
        return points.map { p in
            if let previous, p.t.timeIntervalSince(previous) > 5 * 60 { segment += 1 }
            previous = p.t
            return (segment, p)
        }
    }

    private static func percentText(_ drop: Double) -> String {
        "\(Fmt.number(drop, digits: drop < 1 && drop > 0 ? 1 : 0))%"
    }

    /// "−2%", or "±0%" when there is no measurable drop.
    private static func dropText(_ drop: Double) -> String {
        drop < 0.05 ? "±0%" : "−" + percentText(drop)
    }

    // MARK: Power

    private func powerChart(_ b: BatteryReading) -> some View {
        let battery = model.points(.batteryPower)
        let system = model.points(.systemPower)
        let avg = battery.isEmpty ? nil : battery.map(\.v).reduce(0, +) / Double(battery.count)
        return Card {
            VStack(alignment: .leading, spacing: 8) {
                CardTitle("Power", trailing: b.plugged ? "Adapter \(b.adapterInputW.map(Fmt.watts) ?? "–")"
                    : "Battery \(Fmt.watts(max(0, b.batteryPowerW)))")
                LineChart(series: [
                    ChartSeries(name: "Battery", color: Palette.battery[0], points: battery),
                    ChartSeries(name: "System", color: .yellow, points: system, filled: false),
                ], height: 80, format: ChartFormat.watts, reference: b.plugged ? nil : avg)
                HStack(spacing: 12) {
                    LegendDot(color: Palette.battery[0], label: b.plugged ? "Battery (negative = charging)" : "Battery")
                    LegendDot(color: .yellow, label: "System")
                    if !b.plugged, avg != nil { LegendDot(color: .secondary, label: "Avg") }
                }
            }
        }
    }

    // MARK: What's using power?

    private var drainers: some View {
        let top = model.topApps(by: \.power, limit: 6)
        let total = model.totalAppPower
        return Card {
            VStack(alignment: .leading, spacing: 10) {
                CardTitle("What's using power?", trailing: total > 0 ? "Apps total \(Fmt.watts(total))" : nil)
                AppList(apps: top, value: \.power, format: Fmt.watts, color: Palette.battery[1], minimum: 0.05)
                Text("Kernel energy counters, smoothed over 30 s. System processes (root) are missing.")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: Battery stretch

    private func sessionCard(_ s: DischargeSession, battery: BatteryReading) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                CardTitle(s.ongoing ? "Current time on battery" : "Last time on battery",
                          trailing: "since \(Fmt.weekday(s.start)) \(Fmt.clock(s.start))")
                HStack(spacing: 8) {
                    Tile(label: "used", value: "\(Int(s.startPercent.rounded())) → \(Int(s.endPercent.rounded()))%")
                    Tile(label: "on battery", value: Fmt.duration(Double(s.activeMinutes) * 60))
                    Tile(label: "per hour", value: s.percentPerHour.map { "\(Fmt.number($0, digits: 1))%" } ?? "–")
                }
                if let w = s.averagePowerW {
                    Text("Avg \(Fmt.watts(w)) power draw. Sleep does not count as active.")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    // MARK: Sleep

    private func sleepCard(_ last: SleepRecord) -> some View {
        // The night (longest sleep in the last 24 h) comes first, the latest sleep below it if it was a different one.
        let main = model.sleeps.filter { $0.end > .now.addingTimeInterval(-24 * 3600) }
            .max { $0.duration < $1.duration } ?? last
        let rated = model.sleeps.filter { $0.percentPerHour != nil }.suffix(7)
        let typical = model.sleepLog.typicalPercentPerHour
        let limit = max(1, 2 * (typical ?? 0.5))
        return Card {
            VStack(alignment: .leading, spacing: 8) {
                CardTitle("While asleep", trailing: typical.map { "typically \(Fmt.number($0, digits: 1))%/h" })
                Text(sleepSummary(main))
                    .font(.system(size: 12, weight: .medium))
                    .monospacedDigit()
                Text(sleepDetail(main))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if main != last {
                    Text("Latest: " + sleepSummary(last))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                if rated.count >= 2 {
                    let bars = Array(rated.enumerated())
                    Chart(bars, id: \.offset) { i, sleep in
                        let rate = sleep.percentPerHour ?? 0
                        BarMark(x: .value("Sleep", "\(i)"), y: .value("%/h", rate), width: .ratio(0.55))
                            .foregroundStyle(rate > limit ? Color.orange : Palette.battery[1])
                            .cornerRadius(2)
                            .annotation(position: .top, spacing: 2) {
                                Text(Fmt.number(rate, digits: 1)).font(.system(size: 8)).foregroundStyle(.secondary)
                            }
                    }
                    .chartYAxis(.hidden)
                    .chartXAxis {
                        AxisMarks { value in
                            AxisValueLabel {
                                if let i = value.as(String.self).flatMap(Int.init), i < bars.count {
                                    Text(Self.sleepLabel(bars[i].element)).font(.system(size: 8))
                                }
                            }
                        }
                    }
                    .frame(height: 64)
                }
                Text(typical.map { "Drop in % per hour. A night (8 h) typically costs you about \(Self.percentText($0 * 8))." }
                    ?? "Drop in % per hour on battery.")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// "Night 21:21–06:24: −2%, 46 brief wakeups"
    private func sleepSummary(_ s: SleepRecord) -> String {
        let night = s.duration >= 4 * 3600 && Calendar.current.component(.day, from: s.start) != Calendar.current.component(.day, from: s.end)
        let day = Date.now.timeIntervalSince(s.end) > 20 * 3600 ? Fmt.weekday(s.start) + " " : ""
        var text = "\(night ? "Night" : "Sleep") \(day)\(Fmt.clock(s.start))–\(Fmt.clock(s.end)): "
        text += s.drop.map(Self.dropText) ?? (s.plugged ? "on power adapter" : "–")
        if let n = s.darkWakes { text += ", \(n) brief \(n == 1 ? "wakeup" : "wakeups")" }
        return text
    }

    private func sleepDetail(_ s: SleepRecord) -> String {
        var parts = ["\(Fmt.duration(s.duration)) asleep"]
        if let rate = s.percentPerHour { parts[0] += " (\(Fmt.number(rate, digits: 1))%/h)" }
        if s.darkWakes == nil {
            parts.append("Reading wakeups …")
        } else if !s.topWakers.isEmpty {
            parts.append("woken by " + s.topWakers.prefix(3).map { "\(Self.wakerName($0.name)) \($0.count)×" }.joined(separator: ", "))
        }
        if let rate = s.percentPerHour, let typical = model.sleepLog.typicalPercentPerHour, rate > max(1, 2 * typical) {
            parts.append("much more than usual")
        }
        return parts.joined(separator: " · ")
    }

    private static func sleepLabel(_ s: SleepRecord) -> String {
        let weekday = Fmt.weekday(s.start)
        return s.duration >= 4 * 3600 ? weekday : "\(weekday) \(Fmt.clock(s.start))"
    }

    private static func wakerName(_ name: String) -> String {
        switch name {
        case "dasd": "Background tasks"
        case "powerd": "System"
        case "mDNSResponder": "Network"
        case "Notification": "Notifications"
        default: name
        }
    }

    // MARK: Health

    private func health(_ b: BatteryReading) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                CardTitle("Health")
                HStack(spacing: 8) {
                    Tile(label: "Capacity", value: b.health.map { Fmt.percent(min($0, 1.0)) } ?? "–",
                         color: (b.health ?? 1) < 0.8 ? .orange : .primary)
                    Tile(label: "Cycle count", value: "\(b.cycleCount) / \(b.designCycles)")
                    Tile(label: "Temperature", value: (model.temperatures.battery ?? b.temperature).map { Fmt.celsius($0) } ?? "–")
                }
                StatRow(label: "Full charge", value: "\(Int(b.fullCapacity)) mAh", systemImage: "battery.100percent",
                        detail: "Design \(Int(b.designCapacity)) mAh")
                StatRow(label: "Energy now", value: "\(Fmt.number(b.remainingWh, digits: 1)) Wh", systemImage: "bolt.batteryblock",
                        detail: "of \(Fmt.number(b.fullWh, digits: 1)) Wh")
                StatRow(label: "Voltage", value: "\(Fmt.number(b.voltage, digits: 2)) V", systemImage: "waveform.path")
                StatRow(label: "Current", value: "\(Int(b.amperage)) mA", systemImage: "arrow.left.arrow.right")
                if b.plugged {
                    StatRow(label: "Power adapter", value: b.adapterWatts.map { "\($0) W" } ?? "–", systemImage: "powerplug",
                            detail: b.adapterName)
                }
            }
        }
    }
}
