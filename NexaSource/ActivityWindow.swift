import AppKit
import SwiftUI

final class ActivityWindowController: NSWindowController, NSWindowDelegate {
    let activity: AppActivityMonitor
    let selection = ActivitySelection()
    private let hosting: NSHostingController<ActivityView>

    init(activity: AppActivityMonitor, preferences: Preferences) {
        self.activity = activity
        hosting = NSHostingController(rootView: ActivityView(activity: activity,
            preferences: preferences, selection: selection))
        let window = NSWindow(contentViewController: hosting)
        window.title = "nexa · 应用活动"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.backgroundColor = Brand.paperColor
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: u(520), height: u(380))
        window.setContentSize(NSSize(width: u(560), height: u(480)))
        window.center()
        super.init(window: window)
        window.delegate = self
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func open() {
        activity.hold("window")
        if window?.isMiniaturized == true { window?.deminiaturize(nil) }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    func windowWillClose(_ notification: Notification) { activity.drop("window") }
    func windowDidMiniaturize(_ notification: Notification) { activity.drop("window") }
    func windowDidDeminiaturize(_ notification: Notification) { activity.hold("window") }

    func capture(to url: URL) throws {
        let view = hosting.view
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw CocoaError(.fileWriteUnknown)
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try png.write(to: url)
    }
}
