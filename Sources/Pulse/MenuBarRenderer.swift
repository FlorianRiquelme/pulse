import AppKit
import PulseCore

/// Draws the menu bar icons: small history bars, the battery icon and numbers.
@MainActor
enum MenuBarRenderer {
    struct Content {
        var image: NSImage
        /// If the key does not change, nothing is redrawn.
        var key: String
        var tooltip: String
    }

    static let height: CGFloat = 22
    private static let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
    private static let smallFont = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium)
    private static let tinyFont = NSFont.systemFont(ofSize: 7, weight: .bold)

    /// How an icon is colored: in the calm style as a template in the menu bar's color,
    /// only colored when action is needed.
    struct Look {
        let style: MenuBarColor
        let attention: Attention

        var template: Bool { style == .mono || (style == .calm && attention == .none) }
        /// Base color: templates are drawn black, macOS tints them to match the menu bar.
        var ink: NSColor { template ? .black : .labelColor }

        /// Color of a part: colorful always, calm only on its own warning, monochrome never.
        func color(_ colorful: NSColor?, alert: Attention = .none) -> NSColor? {
            switch style {
            case .colorful: Self.alertColor(alert) ?? colorful
            case .calm: Self.alertColor(alert)
            case .mono: nil
            }
        }

        static func alertColor(_ a: Attention) -> NSColor? {
            switch a {
            case .none: nil
            case .warning: .systemOrange
            case .critical: .systemRed
            }
        }

        var key: String { "\(style.rawValue)\(attention.rawValue)" }
    }

    static func content(for kind: MenuItemKind, model: AppModel) -> Content {
        let s = model.settings
        let style = s.menuBarColor
        switch kind {
        case .cpu:
            let total = model.cpu.total
            let text = Fmt.percentCompact(total)
            let values = s.menuBarGraphs ? model.tail(.cpu, 14) : []
            let look = Look(style: style, attention: model.backgroundHogs.isEmpty ? .none : .warning)
            let colors: ((Double) -> NSColor)? = style == .colorful ? loadColors : nil
            let hogs = model.backgroundHogs.map(\.name)
            return Content(
                image: graphWithValue(values: values, colors: colors, caption: "CPU", text: text, look: look, dot: !hogs.isEmpty),
                key: "cpu|\(text)|\(values.map { Int($0 * 20) })|\(look.key)|\(hogs)",
                tooltip: cpuTooltip(model))

        case .gpu:
            let value = model.gpu ?? 0
            let text = Fmt.percentCompact(value)
            let values = s.menuBarGraphs ? model.tail(.gpu, 14) : []
            let look = Look(style: style, attention: .none)
            let colors: ((Double) -> NSColor)? = style == .colorful ? gpuColors : nil
            return Content(
                image: graphWithValue(values: values, colors: colors, caption: "GPU", text: text, look: look),
                key: "gpu|\(text)|\(values.map { Int($0 * 20) })|\(look.key)",
                tooltip: "GPU \(Fmt.percent(value))")

        case .memory:
            let fraction = model.memory.usedFraction
            let text = Fmt.percentCompact(fraction)
            let alert = memoryAttention(model)
            let look = Look(style: style, attention: alert)
            return Content(
                image: meterWithValue(fraction: fraction, color: look.color(pressureColor(model.memory.pressure), alert: alert),
                                      caption: "RAM", text: text, look: look),
                key: "mem|\(text)|\(model.memory.pressure)|\(look.key)|\(model.longKeepAwake != nil)",
                tooltip: memoryTooltip(model))

        case .temperature:
            let temp = model.temperatures.socAverage
            let text = temp.map { Fmt.celsius($0, compact: true) } ?? "–"
            let alert = temperatureAttention(model)
            let look = Look(style: style, attention: alert)
            let color = look.color(temp.flatMap(temperatureColor), alert: alert)
            return Content(
                image: symbolWithValue("thermometer.medium", color: color, text: text, look: look),
                key: "temp|\(text)|\(color?.description ?? "-")|\(look.key)",
                tooltip: temperatureTooltip(model))

        case .power:
            let watts = model.systemPower ?? model.battery?.batteryPowerW ?? 0
            let text = Fmt.number(watts, digits: watts < 10 ? 1 : 0) + "W"
            let look = Look(style: style, attention: .none)
            return Content(
                image: symbolWithValue("bolt.fill", color: look.color(.systemYellow), text: text, look: look),
                key: "pow|\(text)|\(look.key)",
                tooltip: "System \(Fmt.watts(watts))")

        case .network:
            let up = Fmt.rateCompact(model.network.outRate), down = Fmt.rateCompact(model.network.inRate)
            let look = Look(style: style, attention: .none)
            return Content(
                image: twoLines(top: "↑ " + up, bottom: "↓ " + down,
                                topColor: look.color(.systemRed), bottomColor: look.color(.systemBlue), look: look),
                key: "net|\(up)|\(down)|\(look.key)",
                tooltip: "Received \(Fmt.rate(model.network.inRate)) · Sent \(Fmt.rate(model.network.outRate))")

        case .battery:
            guard let b = model.battery else {
                let look = Look(style: style, attention: .none)
                return Content(image: symbolWithValue("powerplug", color: nil, text: "", look: look), key: "bat|none|\(look.key)", tooltip: "No battery")
            }
            let time: TimeInterval? = b.plugged ? nil : model.estimate.best
            let percent = Fmt.percentCompact(b.percent / 100)
            var label: String?
            let text: String
            switch (s.batteryDisplay, time) {
            case (.percent, _), (_, nil): text = percent
            case (.time, let t?): text = Fmt.durationCompact(t)
            case (.until, let t?): text = Fmt.clock(.now.addingTimeInterval(t)); label = "until"
            case (.both, let t?): text = percent + " · " + Fmt.durationCompact(t)
            }
            let alert = batteryAttention(model)
            let look = Look(style: style, attention: alert)
            let keptAwake = model.longKeepAwake != nil
            let state = "\(b.charging)|\(b.plugged)|\(look.key)|\(keptAwake)"
            if s.batteryGraph, let runway = runway(model: model, percent: b.percent, remaining: time) {
                return Content(
                    image: runwayWithValue(runway.value, color: look.color(batteryColor(b), alert: alert) ?? look.ink,
                                           symbol: b.charging ? "bolt.fill" : b.plugged ? "powerplug.fill" : nil, caption: label, text: text, look: look, keptAwake: keptAwake),
                    key: "bat|graph|\(text)|\(runway.key)|\(state)",
                    tooltip: batteryTooltip(b, model: model))
            }
            return Content(
                image: batteryWithValue(fraction: b.percent / 100, charging: b.charging, plugged: b.plugged,
                                        fill: look.color(batteryColor(b), alert: alert), look: look, caption: label, text: text, keptAwake: keptAwake),
                key: "bat|\(text)|\(Int(b.percent / 5))|\(state)",
                tooltip: batteryTooltip(b, model: model))

        case .compact:
            return compactContent(model: model)
        }
    }

    /// One icon instead of four (~80 instead of ~290 pt): battery time on the left, CPU and temperature
    /// above memory on the right, and a thin bar with the charge level at the bottom.
    private static func compactContent(model: AppModel) -> Content {
        let batteryAlert = batteryAttention(model), tempAlert = temperatureAttention(model), memAlert = memoryAttention(model)
        let look = Look(style: model.settings.menuBarColor, attention: max(batteryAlert, tempAlert, memAlert))

        let cpu = "CPU \(Int((model.cpu.total * 100).rounded()))"
        let temp = model.temperatures.socAverage
        let tempText = temp.map { Fmt.celsius($0, compact: true) } ?? "–"
        let ram = "RAM " + Fmt.percentCompact(model.memory.usedFraction)
        let top: [(String, NSColor?)] = [
            (cpu, look.color(loadColors(model.cpu.total))),
            (" · ", nil),
            (tempText, look.color(temp.flatMap(temperatureColor), alert: tempAlert)),
        ]
        let bottom: [(String, NSColor?)] = [(ram, look.color(pressureColor(model.memory.pressure), alert: memAlert))]

        var lead = "", level: Double?, fill: NSColor?
        var tooltip = [cpuTooltip(model), temperatureTooltip(model), memoryTooltip(model)]
        if let b = model.battery {
            let time: TimeInterval? = b.plugged ? nil : model.estimate.best
            lead = time.map(Fmt.durationCompact) ?? Fmt.percentCompact(b.percent / 100)
            level = b.percent / 100
            fill = look.color(batteryColor(b), alert: batteryAlert)
            tooltip.insert(batteryTooltip(b, model: model), at: 0)
        }
        let leadColor = look.color(nil, alert: batteryAlert)
        return Content(
            image: compact(lead: lead, leadColor: leadColor, top: top, bottom: bottom, level: level, fill: fill, look: look, keptAwake: model.longKeepAwake != nil),
            key: "compact|\(lead)|\(cpu)|\(tempText)|\(ram)|\(level.map { Int($0 * 40) } ?? -1)|\(fill?.description ?? "-")|"
                + "\(model.cpu.total >= 0.5)\(model.cpu.total >= 0.8)|\(model.memory.pressure)|\(look.key)|\(model.longKeepAwake != nil)",
            tooltip: tooltip.joined(separator: "\n"))
    }

    // MARK: Needs attention

    private static func batteryAttention(_ model: AppModel) -> Attention {
        guard let b = model.battery else { return .none }
        return max(MenuBarAttention.battery(percent: b.percent, remaining: model.estimate.best, plugged: b.plugged),
                   model.longKeepAwake == nil ? .none : .warning)
    }

    private static func temperatureAttention(_ model: AppModel) -> Attention {
        MenuBarAttention.temperature(celsius: model.temperatures.socAverage, thermal: model.thermalState)
    }

    private static func memoryAttention(_ model: AppModel) -> Attention {
        MenuBarAttention.memory(pressureLevel: model.memory.pressure.rawValue)
    }

    // MARK: Tooltips

    private static func cpuTooltip(_ model: AppModel) -> String {
        var text = "CPU \(Fmt.percent(model.cpu.total)) · User \(Fmt.percent(model.cpu.user)) · System \(Fmt.percent(model.cpu.system))"
        let hogs = model.backgroundHogs.map(\.name)
        if !hogs.isEmpty { text += "\nBusy in the background for a long time: " + hogs.joined(separator: ", ") }
        return text
    }

    private static func memoryTooltip(_ model: AppModel) -> String {
        let m = model.memory
        var text = "Memory \(Fmt.bytes(m.used)) of \(Fmt.bytes(m.total)) · Pressure \(m.pressure.label)"
        if m.swapUsed > 0 { text += " · Swap \(Fmt.bytes(m.swapUsed))" }
        return text
    }

    private static func temperatureTooltip(_ model: AppModel) -> String {
        "Chip \(model.temperatures.socAverage.map { Fmt.celsius($0) } ?? "–") · Thermal state \(model.thermalLabel)"
    }

    /// Last computed history; recomputed only on a new log minute, a different percentage or forecast (5 min steps).
    private static var runwayCache: (key: String, value: Runway?)?

    private static func runway(model: AppModel, percent: Double, remaining: TimeInterval?) -> (key: String, value: Runway)? {
        let minute = model.log.samples.last.map { Int($0.t.timeIntervalSinceReferenceDate / 60) } ?? 0
        let key = "\(minute)|\(Int(percent.rounded()))|\(remaining.map { Int($0 / 300) } ?? -1)"
        if runwayCache?.key != key {
            let runway = Runway(points: model.points(.batteryPercent, range: .hour), now: .now, percent: percent, remaining: remaining)
            // Without history (e.g. right after installing) the battery icon stays.
            runwayCache = (key, runway.segments.isEmpty ? nil : runway)
        }
        return runwayCache?.value.map { (key, $0) }
    }

    private static func batteryTooltip(_ b: BatteryReading, model: AppModel) -> String {
        var text = batteryBaseTooltip(b, model: model)
        if let awake = model.longKeepAwake {
            text += "\n\(awake.name) \(awake.blocker.phrase), so the Mac won't sleep on its own"
        }
        return text
    }

    private static func batteryBaseTooltip(_ b: BatteryReading, model: AppModel) -> String {
        if b.plugged {
            if b.charging, let t = model.estimate.best ?? b.macTimeToFull {
                return "Charging · \(Fmt.percent(b.percent / 100)) · full in \(Fmt.duration(t))"
            }
            return "On power adapter · \(Fmt.percent(b.percent / 100))"
        }
        guard let t = model.estimate.best else { return "Battery \(Fmt.percent(b.percent / 100))" }
        return "Battery \(Fmt.percent(b.percent / 100)) · \(Fmt.duration(t)) left · until about \(Fmt.clock(.now.addingTimeInterval(t)))"
    }

    // MARK: Colors

    nonisolated private static func loadColors(_ v: Double) -> NSColor {
        switch v {
        case ..<0.5: NSColor.systemTeal
        case ..<0.8: NSColor.systemOrange
        default: NSColor.systemRed
        }
    }

    nonisolated private static func gpuColors(_ v: Double) -> NSColor { v < 0.8 ? .systemPurple : .systemPink }

    nonisolated private static func batteryColor(_ fraction: Double, charging: Bool, plugged: Bool, colorful: Bool) -> NSColor {
        if !colorful { return .labelColor }
        if charging || plugged { return .systemGreen }
        if fraction < 0.1 { return .systemRed }
        if fraction < 0.2 { return .systemOrange }
        return .labelColor
    }

    static func pressureColor(_ p: MemoryPressure) -> NSColor {
        switch p {
        case .normal: .systemGreen
        case .warning: .systemOrange
        case .critical: .systemRed
        }
    }

    /// Battery fill in the colorful style: green on power adapter, otherwise by charge level.
    private static func batteryColor(_ b: BatteryReading) -> NSColor? {
        if b.charging || b.plugged { return .systemGreen }
        if b.percent < 10 { return .systemRed }
        if b.percent < 20 { return .systemOrange }
        return nil
    }

    static func temperatureColor(_ c: Double) -> NSColor? {
        switch c {
        case ..<70: nil
        case ..<90: .systemOrange
        default: .systemRed
        }
    }

    // MARK: Building blocks

    private static func make(width: CGFloat, look: Look, draw: @escaping (NSRect) -> Void) -> NSImage {
        let image = NSImage(size: NSSize(width: ceil(width), height: height), flipped: false) { rect in
            draw(rect)
            return true
        }
        image.isTemplate = look.template
        return image
    }

    private static func attributed(_ text: String, font: NSFont, color: NSColor) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
    }

    /// Text made of parts with their own color (no color: base color).
    private static func attributed(_ parts: [(String, NSColor?)], font: NSFont, ink: NSColor) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for (text, color) in parts { result.append(attributed(text, font: font, color: color ?? ink)) }
        return result
    }

    /// Tiny caption above a value, e.g. "CPU".
    private static func caption(_ text: String, x: CGFloat, width: CGFloat, ink: NSColor) {
        let s = attributed(text, font: tinyFont, color: ink.withAlphaComponent(0.6))
        s.draw(at: NSPoint(x: x + (width - s.size().width) / 2, y: 13))
    }

    private static func graphWithValue(values: [Double], colors: ((Double) -> NSColor)?, caption label: String, text: String, look: Look, dot: Bool = false) -> NSImage {
        let ink = look.ink
        let value = attributed(text, font: valueFont, color: ink)
        let graphWidth: CGFloat = values.isEmpty ? 0 : 26
        let textWidth = max(value.size().width, 24)
        let width = graphWidth + (graphWidth > 0 ? 4 : 0) + textWidth
        return make(width: width, look: look) { _ in
            if graphWidth > 0 {
                let frame = NSRect(x: 0, y: 3, width: graphWidth, height: 16)
                let track = NSBezierPath(roundedRect: frame, xRadius: 2.5, yRadius: 2.5)
                ink.withAlphaComponent(0.12).setFill()
                track.fill()
                let slots = 14
                let barWidth = (frame.width - 2) / CGFloat(slots)
                let offset = slots - values.count
                for (i, v) in values.enumerated() {
                    let h = max(1, CGFloat(min(1, max(0, v))) * (frame.height - 2))
                    let bar = NSRect(x: frame.minX + 1 + CGFloat(i + offset) * barWidth, y: frame.minY + 1,
                                     width: max(1, barWidth - 0.5), height: h)
                    (colors?(v) ?? ink).setFill()
                    bar.fill()
                }
            }
            let x = graphWidth + (graphWidth > 0 ? 4 : 0)
            caption(label, x: x, width: textWidth, ink: ink)
            value.draw(at: NSPoint(x: x + textWidth - value.size().width, y: 0.5))
            // Small dot next to "CPU": an app has been busy in the background for a long time.
            if dot {
                (look.color(.systemOrange, alert: .warning) ?? ink).setFill()
                NSBezierPath(ovalIn: NSRect(x: x + textWidth - 4, y: 15, width: 4, height: 4)).fill()
            }
        }
    }

    private static func meterWithValue(fraction: Double, color: NSColor?, caption label: String, text: String, look: Look, keptAwake: Bool = false) -> NSImage {
        let ink = look.ink
        let value = attributed(text, font: valueFont, color: ink)
        let textWidth = max(value.size().width, 24)
        return make(width: 7 + 4 + textWidth, look: look) { _ in
            let frame = NSRect(x: 0.5, y: 3.5, width: 6, height: 15)
            let outline = NSBezierPath(roundedRect: frame, xRadius: 2, yRadius: 2)
            ink.withAlphaComponent(0.35).setStroke()
            outline.lineWidth = 1
            outline.stroke()
            let fill = NSRect(x: frame.minX + 1.5, y: frame.minY + 1.5, width: frame.width - 3,
                              height: (frame.height - 3) * CGFloat(min(1, max(0, fraction))))
            (color ?? ink).setFill()
            NSBezierPath(roundedRect: fill, xRadius: 1, yRadius: 1).fill()
            caption(label, x: 11, width: textWidth, ink: ink)
            value.draw(at: NSPoint(x: 11 + textWidth - value.size().width, y: 0.5))
        }
    }

    private static func symbolWithValue(_ name: String, color: NSColor?, text: String, look: Look, keptAwake: Bool = false) -> NSImage {
        let ink = look.ink
        let value = attributed(text, font: valueFont, color: ink)
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
            .applying(.init(paletteColors: [color ?? ink]))
        let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config)
        let symbolWidth = symbol?.size.width ?? 0
        let gap: CGFloat = text.isEmpty ? 0 : 3
        return make(width: symbolWidth + gap + value.size().width, look: look) { _ in
            if let symbol {
                symbol.draw(in: NSRect(x: 0, y: (height - symbol.size.height) / 2, width: symbol.size.width, height: symbol.size.height))
            }
            value.draw(at: NSPoint(x: symbolWidth + gap, y: (height - value.size().height) / 2))
        }
    }

    private static func twoLines(top: String, bottom: String, topColor: NSColor?, bottomColor: NSColor?, look: Look) -> NSImage {
        let a = attributed(top, font: smallFont, color: topColor ?? look.ink)
        let b = attributed(bottom, font: smallFont, color: bottomColor ?? look.ink)
        let width = max(a.size().width, b.size().width, 42)
        return make(width: width, look: look) { _ in
            a.draw(at: NSPoint(x: width - a.size().width, y: 10.5))
            b.draw(at: NSPoint(x: width - b.size().width, y: 0.5))
        }
    }

    private static func compact(lead: String, leadColor: NSColor?, top: [(String, NSColor?)], bottom: [(String, NSColor?)],
                                level: Double?, fill: NSColor?, look: Look, keptAwake: Bool) -> NSImage {
        let ink = look.ink
        let big = attributed(lead, font: valueFont, color: leadColor ?? ink)
        let a = attributed(top, font: smallFont, ink: ink)
        let b = attributed(bottom, font: smallFont, ink: ink)
        let bigWidth = lead.isEmpty ? 0 : big.size().width
        let gap: CGFloat = lead.isEmpty ? 0 : 4
        let linesWidth = max(a.size().width, b.size().width)
        let width = bigWidth + gap + linesWidth
        return make(width: width, look: look) { _ in
            if keptAwake { awakeDot(x: max(0, bigWidth - 4), y: 16, look: look) }
            big.draw(at: NSPoint(x: 0, y: 5))
            a.draw(at: NSPoint(x: bigWidth + gap, y: 11.5))
            b.draw(at: NSPoint(x: bigWidth + gap, y: 2.5))
            if let level {
                let track = NSRect(x: 0, y: 0, width: ceil(width), height: 2)
                ink.withAlphaComponent(0.2).setFill()
                NSBezierPath(roundedRect: track, xRadius: 1, yRadius: 1).fill()
                (fill ?? ink).setFill()
                let bar = NSRect(x: 0, y: 0, width: max(2, track.width * CGFloat(min(1, max(0, level)))), height: 2)
                NSBezierPath(roundedRect: bar, xRadius: 1, yRadius: 1).fill()
            }
        }
    }

    private static func batteryWithValue(fraction: Double, charging: Bool, plugged: Bool, fill: NSColor?, look: Look, caption label: String?, text: String, keptAwake: Bool = false) -> NSImage {
        let ink = look.ink
        let value = attributed(text, font: valueFont, color: ink)
        let bodyWidth: CGFloat = 22, bodyHeight: CGFloat = 11
        return make(width: bodyWidth + 2.5 + 4 + value.size().width, look: look) { _ in
            let body = NSRect(x: 0.5, y: (height - bodyHeight) / 2, width: bodyWidth, height: bodyHeight)
            let outline = NSBezierPath(roundedRect: body, xRadius: 3, yRadius: 3)
            ink.withAlphaComponent(0.4).setStroke()
            outline.lineWidth = 1
            outline.stroke()
            ink.withAlphaComponent(0.4).setFill()
            NSBezierPath(roundedRect: NSRect(x: body.maxX + 1, y: body.midY - 2, width: 1.5, height: 4), xRadius: 0.75, yRadius: 0.75).fill()

            let level = CGFloat(min(1, max(0, fraction)))
            let inner = NSRect(x: body.minX + 2, y: body.minY + 2, width: max(1.5, (body.width - 4) * level), height: body.height - 4)
            let cg = NSGraphicsContext.current?.cgContext
            cg?.beginTransparencyLayer(auxiliaryInfo: nil)
            (fill ?? ink).setFill()
            NSBezierPath(roundedRect: inner, xRadius: 1.5, yRadius: 1.5).fill()

            if charging || plugged {
                let config = NSImage.SymbolConfiguration(pointSize: 8, weight: .heavy)
                    .applying(.init(paletteColors: [ink]))
                if let bolt = NSImage(systemSymbolName: charging ? "bolt.fill" : "powerplug.fill", accessibilityDescription: nil)?
                    .withSymbolConfiguration(config) {
                    let s = bolt.size
                    let rect = NSRect(x: body.midX - s.width / 2, y: body.midY - s.height / 2, width: s.width, height: s.height)
                    // Punch a margin around the symbol out of the fill so it stays readable (also as a template).
                    NSGraphicsContext.saveGraphicsState()
                    let shadow = NSShadow()
                    shadow.shadowColor = .black
                    shadow.shadowBlurRadius = 1.5
                    shadow.set()
                    bolt.draw(in: rect, from: .zero, operation: .destinationOut, fraction: 1)
                    NSGraphicsContext.restoreGraphicsState()
                    bolt.draw(in: rect)
                }
            }
            cg?.endTransparencyLayer()
            if keptAwake { awakeDot(x: body.maxX - 4, y: body.maxY - 3.5, look: look) }
            drawValue(value, caption: label, x: bodyWidth + 2.5 + 4, ink: ink)
        }
    }

    /// Value to the right of an icon; with a caption above, like CPU and RAM.
    private static func drawValue(_ value: NSAttributedString, caption label: String?, x: CGFloat, ink: NSColor) {
        if let label {
            caption(label, x: x, width: value.size().width, ink: ink)
            value.draw(at: NSPoint(x: x, y: 0.5))
        } else {
            value.draw(at: NSPoint(x: x, y: (height - value.size().height) / 2))
        }
    }

    /// Charge level of the last hour (left) and dashed forecast (right), dot at "now".
    private static func runwayWithValue(_ runway: Runway, color: NSColor, symbol: String?, caption label: String?, text: String, look: Look, keptAwake: Bool = false) -> NSImage {
        let ink = look.ink
        let value = attributed(text, font: valueFont, color: ink)
        let graphWidth: CGFloat = 30
        return make(width: graphWidth + 4 + value.size().width, look: look) { _ in
            let frame = NSRect(x: 0, y: 3, width: graphWidth, height: 16)
            ink.withAlphaComponent(0.12).setFill()
            NSBezierPath(roundedRect: frame, xRadius: 2.5, yRadius: 2.5).fill()
            let inner = frame.insetBy(dx: 1.5, dy: 1.5)
            func point(_ p: Runway.Pt) -> NSPoint {
                NSPoint(x: inner.minX + CGFloat(p.x) * inner.width, y: inner.minY + CGFloat(p.y) * inner.height)
            }

            color.setStroke()
            for segment in runway.segments where segment.count > 1 {
                let line = NSBezierPath()
                line.lineWidth = 1.25
                line.lineJoinStyle = .round
                line.move(to: point(segment[0]))
                for p in segment.dropFirst() { line.line(to: point(p)) }
                line.stroke()
            }
            if let end = runway.projectionEnd {
                let dotted = NSBezierPath()
                dotted.lineWidth = 1
                dotted.setLineDash([1.5, 1.5], count: 2, phase: 0)
                dotted.move(to: point(runway.now))
                dotted.line(to: point(end))
                color.withAlphaComponent(0.7).setStroke()
                dotted.stroke()
            }
            color.setFill()
            let now = point(runway.now)
            NSBezierPath(ovalIn: NSRect(x: now.x - 1.75, y: now.y - 1.75, width: 3.5, height: 3.5)).fill()

            // On power adapter there is no forecast; the symbol sits on the right instead.
            if let symbol, runway.projectionEnd == nil {
                let config = NSImage.SymbolConfiguration(pointSize: 8, weight: .heavy)
                    .applying(.init(paletteColors: [color]))
                if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(config) {
                    let s = image.size
                    let right = NSRect(x: now.x + 2, y: inner.minY, width: inner.maxX - now.x - 2, height: inner.height)
                    image.draw(in: NSRect(x: right.midX - s.width / 2, y: right.midY - s.height / 2, width: s.width, height: s.height))
                }
            }
            if keptAwake { awakeDot(x: frame.maxX - 4, y: frame.maxY - 3.5, look: look) }
            drawValue(value, caption: label, x: graphWidth + 4, ink: ink)
        }
    }
    private static func awakeDot(x: CGFloat, y: CGFloat, look: Look) {
        let dot = NSBezierPath(ovalIn: NSRect(x: x, y: y, width: 6, height: 6))
        (look.color(.systemOrange, alert: .warning) ?? look.ink).setFill()
        dot.fill()
    }

}
