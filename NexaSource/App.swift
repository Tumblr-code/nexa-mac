import AppKit
import SwiftUI
import Combine
import CoreText

func systemString(_ name: String) -> String {
    var length = 0
    guard sysctlbyname(name, nil, &length, nil, 0) == 0, length > 0 else { return "" }
    var data = [CChar](repeating: 0, count: length)
    guard sysctlbyname(name, &data, &length, nil, 0) == 0 else { return "" }
    return String(cString: data)
}

// Sits behind the popover's content so the arrow is paper too, not the system material.
final class PopoverBackdrop: NSView {
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.backgroundColor = Brand.paperColor.cgColor }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem!
    private var popover = NSPopover()
    private var hosting: NSHostingController<NexaPanel>!
    private let monitor = SystemMonitor()
    private let preferences = Preferences(defaults: CommandLine.arguments.contains(where: { ["--render-previews", "--smoke-test"].contains($0) })
        ? UserDefaults(suiteName: "cn.nexastore.nexa.render-tests")! : .standard)
    private let activity = AppActivityMonitor()
    private let backdrop = PopoverBackdrop()
    private var activityWindow: ActivityWindowController?
    private var subscriptions: Set<AnyCancellable> = []
    private var observers: [NSObjectProtocol] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let font = Bundle.main.url(forResource: "Manrope-Variable", withExtension: "woff2") {
            CTFontManagerRegisterFontsForURL(font as CFURL, .process, nil)
        }
        if CommandLine.arguments.contains("--render-previews") {
            renderPreviews()
            return
        }
        let other = NSRunningApplication.runningApplications(withBundleIdentifier: "cn.nexastore.nexa")
            .first { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        if let other, !CommandLine.arguments.contains("--smoke-test") {
            other.activate(options: [])
            NSApp.terminate(nil)
            return
        }
        NotificationCenter.default.publisher(for: .nexaShowActivity).sink { [weak self] _ in self?.showActivity() }
            .store(in: &subscriptions)
        let root = NexaPanel(monitor: monitor, preferences: preferences, activity: activity,
                             chip: systemString("machdep.cpu.brand_string"), resize: { [weak self] in self?.resize() })
        hosting = NSHostingController(rootView: root)
        popover.contentViewController = hosting
        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = Brand.menuImage()
            button.imagePosition = .imageLeading
            button.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
            button.target = self
            button.action = #selector(togglePanel)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.setAccessibilityLabel("nexa 系统状态")
        }
        monitor.$snapshot.sink { [weak self] _ in
            DispatchQueue.main.async { self?.updateMenu() }
        }.store(in: &subscriptions)
        preferences.$indicator.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.updateMenu() }
        }.store(in: &subscriptions)
        preferences.$interval.sink { [weak self] value in self?.monitor.start(interval: value) }
            .store(in: &subscriptions)
        preferences.$appearance.sink { [weak self] theme in
            self?.popover.appearance = theme == "system" ? nil : NSAppearance(named: theme == "dark" ? .darkAqua : .aqua)
            self?.activityWindow?.window?.appearance = theme == "system" ? nil : NSAppearance(named: theme == "dark" ? .darkAqua : .aqua)
        }.store(in: &subscriptions)
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.monitor.stop()
            self?.activity.suspend()
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.monitor.start(interval: self.preferences.interval)
            self.activity.resume()
        })
        updateMenu()
        if CommandLine.arguments.contains("--smoke-test") { smokeTest(); return }
        if !UserDefaults.standard.bool(forKey: "hasLaunched") {
            UserDefaults.standard.set(true, forKey: "hasLaunched")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { self.showPanel() }
        }
    }

    private func updateMenu() {
        guard let button = statusItem?.button else { return }
        let data = monitor.snapshot
        switch preferences.indicator {
        case "cpu": button.title = " " + (data.cpu.map { String(format: "%.0f%%", $0) } ?? "—")
        case "memory": button.title = " \(Units.memory(data.memoryUsed)) GB"
        default: button.title = ""
        }
        button.toolTip = "nexa · \(data.status)\nCPU \(data.cpu.map { String(format: "%.0f%%", $0) } ?? "采集中") · 内存 \(Units.memory(data.memoryUsed)) GB"
        button.setAccessibilityValue(data.status)
    }

    @objc private func togglePanel() {
        if let event = NSApp.currentEvent, event.type == .rightMouseUp, let button = statusItem.button {
            let menu = NSMenu()
            menu.addItem(withTitle: "打开 nexa", action: #selector(showPanel), keyEquivalent: "").target = self
            menu.addItem(withTitle: "设置…", action: #selector(showSettings), keyEquivalent: ",").target = self
            menu.addItem(.separator())
            menu.addItem(withTitle: "应用活动", action: #selector(showActivity), keyEquivalent: "").target = self
            menu.addItem(withTitle: "退出 nexa", action: #selector(quit), keyEquivalent: "q").target = self
            NSMenu.popUpContextMenu(menu, with: event, for: button)
            return
        }
        if popover.isShown { popover.close() } else { showPanel() }
    }

    @objc private func showPanel() {
        guard let button = statusItem?.button else { return }
        preferences.refreshLogin()
        NSApp.activate(ignoringOtherApps: true)
        hosting.view.layoutSubtreeIfNeeded()
        popover.contentSize = hosting.view.fittingSize
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        if let frame = popover.contentViewController?.view.window?.contentView?.superview, backdrop.superview !== frame {
            backdrop.wantsLayer = true
            backdrop.frame = frame.bounds
            backdrop.autoresizingMask = [.width, .height]
            frame.addSubview(backdrop, positioned: .below, relativeTo: frame.subviews.first)
        }
        popover.contentViewController?.view.window?.makeKey()
    }

    @objc private func showSettings() {
        showPanel()
        NotificationCenter.default.post(name: .nexaShowSettings, object: nil)
    }
    @objc private func showActivity() {
        popover.close()
        if activityWindow == nil { activityWindow = ActivityWindowController(activity: activity, preferences: preferences) }
        activityWindow?.open()
    }
    func popoverDidShow(_ notification: Notification) { activity.hold("panel") }
    func popoverDidClose(_ notification: Notification) { activity.drop("panel") }
    @objc private func quit() { NSApp.terminate(nil) }

    private func resize() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.hosting.view.invalidateIntrinsicContentSize()
            self.hosting.view.layoutSubtreeIfNeeded()
            self.popover.contentSize = self.hosting.view.fittingSize
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if activityWindow?.window?.isVisible == true { activityWindow?.open() } else { showPanel() }
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        monitor.stop()
        activity.suspend()
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }

    private var renderWindow: NSWindow?
    private func smokeTest() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            func check(_ condition: Bool, _ name: String) {
                guard condition else { fputs("FAIL: \(name)\n", stderr); exit(1) }
                print("PASS: \(name)")
            }
            self.showPanel()
            check(self.popover.isShown, "Status popover opens")
            check(self.statusItem.button?.image?.isTemplate == true, "Monochrome menu icon")
            check(self.popover.contentSize.width == NexaPanel.width && self.popover.contentSize.height <= u(500), "Compact popover sizing")
            check(self.backdrop.superview != nil, "Brand paper behind the popover")
            check(!self.monitor.snapshot.trend.isEmpty, "Live CPU trend")
            self.preferences.indicator = "cpu"
            self.updateMenu()
            check(self.statusItem.button!.title.contains("%"), "Live CPU menu indicator")
            self.preferences.indicator = "memory"
            self.updateMenu()
            check(self.statusItem.button!.title.contains("GB"), "Live memory menu indicator")
            self.preferences.appearance = "dark"
            self.showSettings()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                check(self.popover.contentSize.height < u(550), "Settings resizes popover")
                self.popover.close()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    check(!self.popover.isShown, "Status popover closes")
                    self.showPanel()
                    check(self.popover.isShown, "Status popover reopens")
                    self.preferences.scale = 1.4
                    check(Scale.value == 1.4 && NexaPanel.width == 448, "Interface size setting")
                    self.preferences.scale = 1.2
                    self.preferences.interval = 5
                    self.preferences.compact = true
                    check(self.preferences.interval == 5 && self.preferences.compact, "Settings update")
                    self.showActivity()
                    check(self.activityWindow?.window?.isVisible == true, "Built-in application activity window")
                    check(!self.popover.isShown, "Activity opens without a stacked popover")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                        check(self.activity.apps.isEmpty == false, "Live application list")
                        check(self.activity.apps.contains(where: { $0.memory != nil }), "Live per-application memory")
                        check(self.activity.busiest != nil, "Busiest application for the panel")
                        self.activityWindow?.close()
                        check(self.activityWindow?.window?.isVisible == false, "Activity window closes")
                        UserDefaults.standard.removePersistentDomain(forName: "cn.nexastore.nexa.render-tests")
                        NSApp.terminate(nil)
                    }
                }
            }
        }
    }

    private func renderPreviews() {
        let folder = CommandLine.arguments.last!
        monitor.start(interval: 2)
        activity.hold("panel")
        let root = NexaPanel(monitor: monitor, preferences: preferences, activity: activity, chip: systemString("machdep.cpu.brand_string"))
        hosting = NSHostingController(rootView: root)
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable]
        window.title = "nexa · 界面验证"
        window.center()
        window.makeKeyAndOrderFront(nil)
        renderWindow = window
        preferences.compact = false
        // NEXA_PREVIEW_WARMUP lets a capture wait until the trend has filled in.
        let warmup = ProcessInfo.processInfo.environment["NEXA_PREVIEW_WARMUP"].flatMap(Double.init) ?? 3
        DispatchQueue.main.asyncAfter(deadline: .now() + max(3, min(120, warmup))) {
            self.capture(theme: "light", folder: folder) {
                self.capture(theme: "dark", folder: folder) {
                    self.preferences.compact = true
                    self.capture(theme: "light", folder: folder, name: "compact") {
                        NotificationCenter.default.post(name: .nexaShowSettings, object: nil)
                        self.capture(theme: "light", folder: folder, name: "settings") {
                            self.captureActivity(folder: folder)
                        }
                    }
                }
            }
        }
    }

    private func captureActivity(folder: String) {
        activityWindow = ActivityWindowController(activity: activity, preferences: preferences)
        activityWindow?.open()
        preferences.appearance = "light"
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            do {
                try self.activityWindow?.capture(to: URL(fileURLWithPath: "\(folder)/nexa-activity-light.png"))
                self.preferences.appearance = "dark"
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    do {
                        try self.activityWindow?.capture(to: URL(fileURLWithPath: "\(folder)/nexa-activity-dark.png"))
                    } catch { print("Activity screenshot failed: \(error)") }
                    UserDefaults.standard.removePersistentDomain(forName: "cn.nexastore.nexa.render-tests")
                    NSApp.terminate(nil)
                }
            } catch { print("Activity screenshot failed: \(error)"); NSApp.terminate(nil) }
        }
    }

    private func capture(theme: String, folder: String, name: String? = nil, completion: @escaping () -> Void) {
        preferences.appearance = theme
        renderWindow?.appearance = NSAppearance(named: theme == "dark" ? .darkAqua : .aqua)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
            let view = self.hosting.view
            view.layoutSubtreeIfNeeded()
            self.renderWindow?.setContentSize(view.fittingSize)
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                print("Capture failed"); NSApp.terminate(nil); return
            }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            if let png = bitmap.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: "\(folder)/nexa-native-\(name ?? theme).png"))
                print("Captured \(theme): \(view.bounds)")
            }
            completion()
        }
    }
}

@main
enum NexaApplication {
    static func main() {
        if CommandLine.arguments.contains(where: { ["--render-previews", "--smoke-test"].contains($0) }) {
            UserDefaults.standard.removePersistentDomain(forName: "cn.nexastore.nexa.render-tests")
        }
        if CommandLine.arguments.contains("--diagnostics") {
            let sampler = MetricsSampler()
            _ = sampler.sample()
            Thread.sleep(forTimeInterval: 1.2)
            let s = sampler.sample()
            let payload: [String: Any] = [
                "chip": systemString("machdep.cpu.brand_string"),
                "model": systemString("hw.model"),
                "cpuPercent": s.cpu as Any? ?? NSNull(),
                "memoryUsed": s.memoryUsed as Any? ?? NSNull(),
                "memoryTotal": s.memoryTotal, "memoryPressure": s.memoryPressure as Any? ?? NSNull(),
                "diskFree": s.diskFree as Any? ?? NSNull(), "diskTotal": s.diskTotal as Any? ?? NSNull(),
                "network": s.networkName, "downloadBytesPerSecond": s.download as Any? ?? NSNull(),
                "uploadBytesPerSecond": s.upload as Any? ?? NSNull()
            ]
            if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]) {
                print(String(decoding: data, as: UTF8.self))
            }
            return
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
