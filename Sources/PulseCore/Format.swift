import Foundation

/// Number formats for the panel and the menu bar. Numbers use a fixed English locale so the output stays
/// deterministic; clock times follow the user's 12/24-hour setting.
public enum Fmt {
    private static let en = Locale(identifier: "en_US")

    public static func number(_ x: Double, digits: Int = 0) -> String {
        x.formatted(.number.precision(.fractionLength(digits)).locale(en))
    }

    /// 0.42 → "42%"
    public static func percent(_ fraction: Double, digits: Int = 0) -> String {
        number(fraction * 100, digits: digits) + "%"
    }

    /// 0.42 → "42%" (compact for the menu bar)
    public static func percentCompact(_ fraction: Double) -> String {
        "\(Int((fraction * 100).rounded()))%"
    }

    /// Watts with one decimal below 10 W, otherwise whole numbers.
    public static func watts(_ w: Double) -> String {
        number(w, digits: abs(w) < 10 ? 1 : 0) + " W"
    }

    public static func celsius(_ c: Double, compact: Bool = false) -> String {
        compact ? "\(Int(c.rounded()))°" : "\(Int(c.rounded())) °C"
    }

    /// Duration as "5h 9m" or "42 min".
    public static func duration(_ interval: TimeInterval) -> String {
        let minutes = max(0, Int((interval / 60).rounded()))
        if minutes < 60 { return "\(minutes) min" }
        return "\(minutes / 60)h \(minutes % 60)m"
    }

    /// Compact duration for the menu bar: "5:09" or "42m".
    public static func durationCompact(_ interval: TimeInterval) -> String {
        let minutes = max(0, Int((interval / 60).rounded()))
        if minutes < 60 { return "\(minutes)m" }
        return String(format: "%d:%02d", minutes / 60, minutes % 60)
    }

    /// Rough duration after "for": "12 min", "17 h", "3 days".
    public static func since(_ interval: TimeInterval) -> String {
        let minutes = max(0, Int(interval / 60))
        if minutes < 60 { return "\(minutes) min" }
        if minutes < 48 * 60 { return "\(minutes / 60) h" }
        return "\(minutes / (24 * 60)) days"
    }

    /// `spellsOutZero: false` keeps "0 bytes" instead of "Zero bytes".
    private static func byteStyle(_ style: ByteCountFormatStyle.Style) -> ByteCountFormatStyle {
        ByteCountFormatStyle(style: style, allowedUnits: .all, spellsOutZero: false, includesActualByteCount: false, locale: en)
    }
    private static let memoryStyle = byteStyle(.memory)
    private static let decimalStyle = byteStyle(.decimal)

    public static func bytes(_ bytes: Double) -> String {
        Int64(max(0, bytes)).formatted(memoryStyle)
    }

    /// Data rate: "1.2 MB/s".
    public static func rate(_ bytesPerSecond: Double) -> String {
        Int64(max(0, bytesPerSecond)).formatted(decimalStyle) + "/s"
    }

    /// Compact data rate for the menu bar: "1.2M", "340K", "0K".
    public static func rateCompact(_ bytesPerSecond: Double) -> String {
        let b = max(0, bytesPerSecond)
        switch b {
        case ..<1_000: return "0K"
        case ..<1_000_000: return "\(Int(b / 1_000))K"
        case ..<10_000_000: return String(format: "%.1fM", b / 1_000_000)
        case ..<1_000_000_000: return "\(Int(b / 1_000_000))M"
        default: return String(format: "%.1fG", b / 1_000_000_000)
        }
    }

    public static func clock(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    /// Abbreviated English weekday: "Mon".
    public static func weekday(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.abbreviated).locale(en))
    }
}
