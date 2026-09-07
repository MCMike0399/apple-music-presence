import AppKit
import ServiceManagement

/// Menu bar icon and menu. All settings the original exposes for Apple Music that
/// matter day-to-day are toggled here; everything else lives in settings.json.
final class StatusItemController: NSObject, NSMenuDelegate {
    private let item: NSStatusItem
    private let coordinator: PresenceCoordinator
    private let statusLine = NSMenuItem(title: "Waiting for Apple Music", action: nil, keyEquivalent: "")
    private let discordLine = NSMenuItem(title: "Discord: disconnected", action: nil, keyEquivalent: "")

    init(coordinator: PresenceCoordinator) {
        self.coordinator = coordinator
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        item.button?.image = NSImage(systemSymbolName: "music.note", accessibilityDescription: "Apple Music Presence")
        item.button?.image?.isTemplate = true
        item.button?.toolTip = "Apple Music Presence"
        item.isVisible = coordinator.settings.showMenuBarIcon

        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu

        coordinator.onStatusChange = { [weak self] text in
            DispatchQueue.main.async { self?.statusLine.title = text; self?.refreshIcon() }
        }
        coordinator.onDiscordStateChange = { [weak self] state in
            DispatchQueue.main.async {
                switch state {
                case .disconnected: self?.discordLine.title = "Discord: not connected"
                case .connecting: self?.discordLine.title = "Discord: connecting…"
                case .connected(let user): self?.discordLine.title = "Discord: connected as \(user)"
                }
                self?.refreshIcon()
            }
        }
    }

    /// Shows or hides the menu bar icon; the app keeps running either way.
    func setIconVisible(_ visible: Bool) {
        item.isVisible = visible
    }

    private func refreshIcon() {
        let s = coordinator.settings
        let symbol: String
        if !s.enabled { symbol = "music.note.slash" }
        else if case .connected = coordinator.discordState, statusLine.title.hasPrefix("Playing") { symbol = "music.note.list" }
        else { symbol = "music.note" }
        item.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Apple Music Presence")
        item.button?.image?.isTemplate = true
        item.button?.appearsDisabled = !s.enabled
    }

    // Rebuild the menu every time it opens so check marks reflect the settings.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let s = coordinator.settings

        statusLine.isEnabled = false
        discordLine.isEnabled = false
        menu.addItem(statusLine)
        menu.addItem(discordLine)
        menu.addItem(.separator())

        menu.addItem(toggle("Enabled", s.enabled, #selector(toggleEnabled)))
        menu.addItem(toggle("Show Paused Music", s.showPausedMedia, #selector(togglePaused)))
        menu.addItem(toggle("Show \"Play on Apple Music\" Button", s.showButtons, #selector(toggleButtons)))
        menu.addItem(toggle("Show Album Name", s.showAlbumName, #selector(toggleAlbum)))
        menu.addItem(toggle("Show Apple Music Logo on Cover", s.showPlayerLogo, #selector(toggleLogo)))

        let display = NSMenuItem(title: "Status Shows \"Listening to…\"", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for type in DisplayType.allCases {
            let mi = NSMenuItem(title: type.menuTitle, action: #selector(pickDisplayType(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = type.rawValue
            mi.state = s.displayType == type ? .on : .off
            sub.addItem(mi)
        }
        display.submenu = sub
        menu.addItem(display)
        menu.addItem(.separator())

        if Bundle.main.bundleIdentifier != nil {
            let login = toggle("Launch at Login", SMAppService.mainApp.status == .enabled, #selector(toggleLaunchAtLogin))
            menu.addItem(login)
        }
        menu.addItem(action("Hide Menu Bar Icon…", #selector(hideIcon)))
        menu.addItem(action("Open Settings File", #selector(openSettings)))
        menu.addItem(action("Open Log", #selector(openLog)))
        menu.addItem(action("Reload Settings", #selector(reload)))
        menu.addItem(.separator())
        menu.addItem(action("Quit Apple Music Presence", #selector(quit), key: "q"))
    }

    private func toggle(_ title: String, _ on: Bool, _ sel: Selector) -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: sel, keyEquivalent: "")
        mi.target = self
        mi.state = on ? .on : .off
        return mi
    }

    private func action(_ title: String, _ sel: Selector, key: String = "") -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: sel, keyEquivalent: key)
        mi.target = self
        return mi
    }

    // MARK: - Actions

    @objc private func toggleEnabled() { coordinator.update { $0.enabled.toggle() }; refreshIcon() }
    @objc private func togglePaused() { coordinator.update { $0.showPausedMedia.toggle() } }
    @objc private func toggleButtons() { coordinator.update { $0.showButtons.toggle() } }
    @objc private func toggleAlbum() { coordinator.update { $0.showAlbumName.toggle() } }
    @objc private func toggleLogo() { coordinator.update { $0.showPlayerLogo.toggle() } }

    @objc private func pickDisplayType(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let type = DisplayType(rawValue: raw) else { return }
        coordinator.update { $0.displayType = type }
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            Log.shared.error("Login item: \(error)")
        }
    }

    @objc private func hideIcon() {
        let alert = NSAlert()
        alert.messageText = "Hide the menu bar icon?"
        alert.informativeText = "Apple Music Presence keeps running in the background. To bring the icon back, open the app again from /Applications (or Spotlight), or set \"showMenuBarIcon\" to true in settings.json."
        alert.addButton(withTitle: "Hide")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .informational
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        coordinator.update { $0.showMenuBarIcon = false }
        setIconVisible(false)
        Log.shared.info("Menu bar icon hidden")
    }

    @objc private func openSettings() { NSWorkspace.shared.open(Paths.settingsFile) }
    @objc private func openLog() { NSWorkspace.shared.open(Paths.supportDirectory.appendingPathComponent("presence.log")) }
    @objc private func reload() { coordinator.reloadSettingsFromDisk() }
    @objc private func quit() { NSApp.terminate(nil) }
}
