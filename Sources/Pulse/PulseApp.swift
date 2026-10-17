import AppKit
import SwiftUI

@main
enum PulseApp {
    @MainActor static let delegate = AppDelegate()

    @MainActor
    static func main() {
        let app = NSApplication.shared
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let model = AppModel()
    private var items: [MenuItemKind: NSStatusItem] = [:]
    private var rendered: [MenuItemKind: String] = [:]
    private let popover = NSPopover()
    private weak var anchor: NSStatusBarButton?

    func applicationDidFinishLaunching(_ notification: Notification) {
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self

        model.onSample = { [weak self] in self?.updateItems() }
        model.start()
        syncItems()
        observeColor()

        if let dir = CommandLine.arguments.first(where: { $0.hasPrefix("--snapshot=") })?.dropFirst("--snapshot=".count) {
            model.panelVisible = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self] in self?.snapshot(to: String(dir)) }
        }
        if CommandLine.arguments.contains("--open") {
            let section = CommandLine.arguments.first { $0.hasPrefix("--section=") }
                .flatMap { Section(rawValue: String($0.dropFirst("--section=".count))) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                guard let self, let kind = self.items.keys.sorted(by: { $0.rawValue < $1.rawValue }).first else { return }
                self.open(kind, section: section)
            }
        }
    }

    /// `--snapshot=<folder> [--dark]`: renders each section and the menu bar as PNGs and quits the app.
    private func snapshot(to dir: String) {
        model.snapshotMode = true
        let dark = CommandLine.arguments.contains("--dark")
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        NSApp.appearance = appearance
        let folder = URL(fileURLWithPath: dir)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // The ImageRenderer's first images come out dimmed; so render twice.
        for section in Section.allCases + Section.allCases {
            model.section = section
            let view = PanelView()
                .environment(model)
                .background(Color(nsColor: .windowBackgroundColor))
                .environment(\.colorScheme, dark ? .dark : .light)
                .transaction { $0.disablesAnimations = true }
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            if let cg = renderer.cgImage {
                try? NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])?
                    .write(to: folder.appendingPathComponent("\(section.rawValue).png"))
            }
        }

        let images = MenuItemKind.allCases.map { MenuBarRenderer.content(for: $0, model: model).image }
        let width = images.reduce(12) { $0 + $1.size.width + 12 }
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width * 2), pixelsHigh: 44, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = NSSize(width: width, height: 22)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        appearance?.performAsCurrentDrawingAppearance {
            (dark ? NSColor(white: 0.12, alpha: 1) : NSColor(white: 0.96, alpha: 1)).setFill()
            NSRect(x: 0, y: 0, width: width, height: 22).fill()
            var x: CGFloat = 12
            for image in images {
                let rect = NSRect(x: x, y: 0, width: image.size.width, height: 22)
                if image.isTemplate, let cg = NSGraphicsContext.current?.cgContext {
                    // Otherwise macOS tints templates in the menu bar's color.
                    cg.beginTransparencyLayer(auxiliaryInfo: nil)
                    image.draw(in: rect)
                    NSColor.labelColor.withAlphaComponent(1).setFill()
                    rect.fill(using: .sourceIn)
                    cg.endTransparencyLayer()
                } else {
                    image.draw(in: rect)
                }
                x += image.size.width + 12
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        try? rep.representation(using: .png, properties: [:])?.write(to: folder.appendingPathComponent("menubar.png"))
        NSApp.terminate(nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.shutdown()
    }

    // MARK: Menu bar icons

    /// Creates or removes icons to match the settings.
    private func syncItems() {
        withObservationTracking {
            _ = model.settings.enabledItems
            _ = model.settings.menuBarLayout
        } onChange: { [weak self] in
            Task { @MainActor in self?.syncItems() }
        }
        let wanted = Set(MenuItemKind.allCases.filter { model.settings.isVisible($0) && ($0 != .battery || model.hasBattery) })
        for (kind, item) in items where !wanted.contains(kind) {
            NSStatusBar.system.removeStatusItem(item)
            items[kind] = nil
            rendered[kind] = nil
        }
        // Newly created icons appear on the left; so create them in reverse of the desired order.
        for kind in MenuItemKind.allCases.reversed() where wanted.contains(kind) && items[kind] == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.autosaveName = "pulse.\(kind.rawValue)"
            item.button?.target = self
            item.button?.action = #selector(itemClicked(_:))
            item.button?.identifier = NSUserInterfaceItemIdentifier(kind.rawValue)
            item.button?.imagePosition = .imageOnly
            items[kind] = item
        }
        // At least one icon must stay, otherwise the app is unreachable.
        if items.isEmpty { model.settings.setEnabled(.cpu, true) }
        updateItems()
    }

    /// Apply the color style right away, not only with the next reading.
    private func observeColor() {
        withObservationTracking {
            _ = model.settings.menuBarColor
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.updateItems()
                self?.observeColor()
            }
        }
    }

    private func updateItems() {
        for (kind, item) in items {
            guard let button = item.button else { continue }
            let content = MenuBarRenderer.content(for: kind, model: model)
            let key = content.key + (button.effectiveAppearance.name.rawValue)
            guard rendered[kind] != key else { continue }
            rendered[kind] = key
            button.image = content.image
            button.toolTip = content.tooltip
        }
    }

    @objc private func itemClicked(_ sender: NSStatusBarButton) {
        guard let raw = sender.identifier?.rawValue, let kind = MenuItemKind(rawValue: raw) else { return }
        if popover.isShown, anchor === sender {
            popover.performClose(nil)
            return
        }
        open(kind)
    }

    private func open(_ kind: MenuItemKind, section: Section? = nil) {
        guard let button = items[kind]?.button else { return }
        model.section = section ?? kind.section
        model.showSettings = false
        anchor = button
        NSApp.activate(ignoringOtherApps: true)
        // The panel only lives while it is open; when closed, SwiftUI should not redraw anything.
        if popover.contentViewController == nil {
            let host = NSHostingController(rootView: PanelView().environment(model))
            host.sizingOptions = .preferredContentSize
            popover.contentViewController = host
        }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        model.panelVisible = true
    }

    func popoverDidClose(_ notification: Notification) {
        popover.contentViewController = nil
        model.panelVisible = false
    }
}
