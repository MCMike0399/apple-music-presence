import AppKit

/// Posted by a second instance so the running one re-shows its menu bar icon.
let showIconNotification = Notification.Name("dev.burbujamc.apple-music-presence.show-icon")

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var coordinator: PresenceCoordinator!
    private var statusItem: StatusItemController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        coordinator = PresenceCoordinator(settings: Settings.load())
        statusItem = StatusItemController(coordinator: coordinator)
        coordinator.onMenuBarIconVisibilityChange = { [weak self] visible in
            DispatchQueue.main.async { self?.statusItem.setIconVisible(visible) }
        }
        DistributedNotificationCenter.default().addObserver(
            forName: showIconNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.coordinator.showMenuBarIcon()
        }
        coordinator.start()
    }

    /// Opening the app while it runs (Finder, Spotlight, Dock) lands here for bundled builds.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        coordinator.showMenuBarIcon()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        coordinator.stop()
        // Give the IPC queue a moment to deliver the clearing SET_ACTIVITY.
        Thread.sleep(forTimeInterval: 0.2)
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }
}

// Only one instance should talk to Discord. A second launch just asks the first
// to show its menu bar icon again (the way back after "Hide Menu Bar Icon").
if let bundleId = Bundle.main.bundleIdentifier,
   NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).count > 1 {
    Log.shared.info("Another instance is already running; asking it to show the menu bar icon")
    DistributedNotificationCenter.default().postNotificationName(
        showIconNotification, object: nil, userInfo: nil, deliverImmediately: true)
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
