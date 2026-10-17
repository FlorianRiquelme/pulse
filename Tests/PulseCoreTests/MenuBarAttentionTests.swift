import Foundation
import Testing
@testable import PulseCore

@Suite struct MenuBarAttentionTests {
    @Test func batteryThresholds() {
        #expect(MenuBarAttention.battery(percent: 80, remaining: 5 * 3600, plugged: false) == .none)
        #expect(MenuBarAttention.battery(percent: 19, remaining: nil, plugged: false) == .warning)
        #expect(MenuBarAttention.battery(percent: 60, remaining: 50 * 60, plugged: false) == .warning)
        #expect(MenuBarAttention.battery(percent: 9, remaining: 2 * 3600, plugged: false) == .critical)
        #expect(MenuBarAttention.battery(percent: 30, remaining: 15 * 60, plugged: false) == .critical)
    }

    @Test func batteryCalmWhenPlugged() {
        #expect(MenuBarAttention.battery(percent: 5, remaining: 10 * 60, plugged: true) == .none)
    }

    @Test func temperature() {
        #expect(MenuBarAttention.temperature(celsius: 85, thermal: .fair) == .none)
        #expect(MenuBarAttention.temperature(celsius: 92, thermal: .nominal) == .warning)
        #expect(MenuBarAttention.temperature(celsius: nil, thermal: .serious) == .warning)
        #expect(MenuBarAttention.temperature(celsius: 60, thermal: .critical) == .critical)
    }

    @Test func memoryPressure() {
        #expect(MenuBarAttention.memory(pressureLevel: 1) == .none)
        #expect(MenuBarAttention.memory(pressureLevel: 2) == .warning)
        #expect(MenuBarAttention.memory(pressureLevel: 4) == .critical)
    }

    @Test func attentionOrder() {
        #expect([Attention.warning, .none, .critical].max() == .critical)
    }

    @Test func fitAddsSpacingPerItem() {
        #expect(MenuBarFit.width(of: [57, 38, 40, 93]) == 228 + 4 * MenuBarFit.spacing)
        #expect(MenuBarFit.width(of: []) == 0)
    }

    @Test func suggestsCompactNextToNotch() {
        #expect(MenuBarFit.suggestsCompact(separate: 292, compact: 82, available: 645.5))
        #expect(!MenuBarFit.suggestsCompact(separate: 150, compact: 82, available: 645.5))
        #expect(!MenuBarFit.suggestsCompact(separate: 292, compact: 82, available: nil)) // no notch
        #expect(!MenuBarFit.suggestsCompact(separate: 90, compact: 82, available: 200))  // saves nothing
    }
}
