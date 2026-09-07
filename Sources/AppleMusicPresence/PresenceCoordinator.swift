import Foundation

/// Glue: Music snapshots in, Discord activity out.
final class PresenceCoordinator {
    private(set) var settings: Settings
    private let monitor: MusicMonitor
    private let resolver = ArtworkResolver()
    private let discord: DiscordClient

    private var current: NowPlaying?
    private var currentLinks: TrackLinks?
    private var lookupGeneration = 0

    /// Human-readable status for the menu bar.
    private(set) var statusText = "Waiting for Apple Music" {
        didSet { if statusText != oldValue { onStatusChange?(statusText) } }
    }
    private(set) var discordState: DiscordClient.ConnectionState = .disconnected {
        didSet { onDiscordStateChange?(discordState) }
    }
    var onStatusChange: ((String) -> Void)?
    var onMenuBarIconVisibilityChange: ((Bool) -> Void)?
    var onDiscordStateChange: ((DiscordClient.ConnectionState) -> Void)?

    /// Position tolerance before a seek is assumed and the timestamps re-sent.
    private let seekTolerance: TimeInterval = 3

    init(settings: Settings) {
        self.settings = settings
        monitor = MusicMonitor(pollInterval: settings.pollIntervalSeconds)
        discord = DiscordClient(clientId: settings.discordApplicationId)
        discord.onStateChange = { [weak self] state in
            self?.discordState = state
            if case .disconnected = state { /* keep last status text */ }
        }
        monitor.onSnapshot = { [weak self] snapshot in self?.handle(snapshot) }
    }

    func start() {
        Log.shared.info("Application startup")
        monitor.start()
        if settings.enabled { discord.start() } else { statusText = "Disabled" }
    }

    func stop() {
        Log.shared.info("Application exiting")
        monitor.stop()
        discord.stop()
    }

    func update(_ mutate: (inout Settings) -> Void) {
        let old = settings
        var new = settings
        mutate(&new)
        guard new != old else { return }
        settings = new
        settings.save()
        apply(changesFrom: old)
    }

    func reloadSettingsFromDisk() {
        let old = settings
        settings = Settings.load()
        apply(changesFrom: old)
    }

    /// Called when the user launches the app while it is already running.
    func showMenuBarIcon() {
        if !settings.showMenuBarIcon { update { $0.showMenuBarIcon = true } }
        onMenuBarIconVisibilityChange?(true)
        Log.shared.info("Menu bar icon shown")
    }

    private func apply(changesFrom old: Settings) {
        if settings.showMenuBarIcon != old.showMenuBarIcon {
            onMenuBarIconVisibilityChange?(settings.showMenuBarIcon)
        }
        if settings.discordApplicationId != old.discordApplicationId {
            discord.setClientId(settings.discordApplicationId)
        }
        if settings.pollIntervalSeconds != old.pollIntervalSeconds {
            monitor.setPollInterval(settings.pollIntervalSeconds)
        }
        if settings.enabled != old.enabled {
            if settings.enabled {
                Log.shared.info("Discord: enabled")
                discord.start()
            } else {
                Log.shared.info("Discord: disabled")
                discord.stop()
                statusText = "Disabled"
                return
            }
        }
        // Any other change may alter the payload: rebuild from the last snapshot.
        if let current { publish(current, force: true) } else { statusText = "Waiting for Apple Music" }
    }

    // MARK: - Snapshots

    private func handle(_ snapshot: NowPlaying?) {
        guard let snapshot else {
            if current != nil {
                Log.shared.info("Music: nothing playing")
                current = nil
                currentLinks = nil
                discord.setActivity(nil)
            }
            statusText = monitor.isMusicRunning ? "Apple Music is idle" : "Waiting for Apple Music"
            return
        }

        let previous = current
        current = snapshot

        let trackChanged = previous?.trackKey != snapshot.trackKey
        let stateChanged = previous?.state != snapshot.state
        var seeked = false
        if let previous, !trackChanged, !stateChanged, snapshot.state == .playing {
            seeked = abs(previous.estimatedPosition(at: snapshot.sampledAt) - snapshot.position) > seekTolerance
        }

        if trackChanged {
            currentLinks = nil
            Log.shared.info("Music: now \(PresenceBuilder.describe(snapshot))")
        }
        guard trackChanged || stateChanged || seeked else {
            // Keep the "current" sample fresh but don't touch Discord.
            if let links = currentLinks { statusText = statusLine(for: snapshot, links: links) }
            return
        }
        if seeked { Log.shared.info("Music: seek detected") }
        publish(snapshot, force: false)
    }

    private func publish(_ track: NowPlaying, force: Bool) {
        guard settings.enabled else { return }
        if let links = currentLinks ?? resolver.cached(track) {
            currentLinks = links
            send(track, links: links)
            return
        }
        lookupGeneration += 1
        let generation = lookupGeneration
        statusText = "Looking up \(track.title)…"
        resolver.resolve(track, country: settings.effectiveCountryCode) { [weak self] links in
            guard let self, generation == self.lookupGeneration,
                  let latest = self.current, latest.trackKey == track.trackKey else { return }
            self.currentLinks = links
            if links.artworkURL == nil {
                Log.shared.warn("iTunes: no match for \(track.title) by \(track.artist); using the Apple Music logo")
            }
            self.send(latest, links: links)
        }
    }

    private func send(_ track: NowPlaying, links: TrackLinks) {
        let activity = PresenceBuilder.activity(for: track, links: links, settings: settings)
        discord.setActivity(activity)
        if activity == nil {
            statusText = track.state == .paused ? "Paused (hidden)" : "Hidden"
            Log.shared.info("Discord: presence cleared (\(track.state.rawValue))")
        } else {
            statusText = statusLine(for: track, links: links)
            let cover = links.artworkURL == nil ? "logo" : "cover"
            Log.shared.info("Discord: presence updated: \(PresenceBuilder.describe(track)) [\(cover)]")
        }
    }

    private func statusLine(for track: NowPlaying, links: TrackLinks) -> String {
        let prefix = track.state == .paused ? "Paused: " : "Playing: "
        let who = track.artist.isEmpty ? "" : " – \(track.artist)"
        return prefix + track.title + who
    }
}
