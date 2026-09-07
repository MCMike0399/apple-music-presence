import AppKit
import Foundation

/// Watches Music.app. Track / state changes arrive instantly through the
/// `com.apple.Music.playerInfo` distributed notification; the playback position
/// (which the notification does not carry) is read via AppleScript on each
/// change and on a slow poll so seeks are picked up.
final class MusicMonitor {
    static let bundleIdentifier = "com.apple.Music"

    /// Called on the main thread with the latest snapshot, or nil when nothing is playing
    /// (Music not running, stopped, or no readable track).
    var onSnapshot: ((NowPlaying?) -> Void)?

    private var pollTimer: Timer?
    private var debounce: DispatchWorkItem?
    private var script: NSAppleScript?
    private var observers: [Any] = []
    private var pollInterval: TimeInterval

    init(pollInterval: TimeInterval) {
        self.pollInterval = pollInterval
    }

    func start() {
        compileScript()

        let dnc = DistributedNotificationCenter.default()
        observers.append(dnc.addObserver(
            forName: Notification.Name("com.apple.Music.playerInfo"), object: nil, queue: .main
        ) { [weak self] _ in
            self?.scheduleRefresh(after: 0.25)
        })

        let ws = NSWorkspace.shared.notificationCenter
        observers.append(ws.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            if app?.bundleIdentifier == MusicMonitor.bundleIdentifier {
                Log.shared.info("Music: application quit")
                self?.onSnapshot?(nil)
            }
        })

        restartPolling()
        refresh()
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        debounce?.cancel()
        for o in observers {
            DistributedNotificationCenter.default().removeObserver(o)
            NSWorkspace.shared.notificationCenter.removeObserver(o)
        }
        observers.removeAll()
    }

    func setPollInterval(_ interval: TimeInterval) {
        pollInterval = max(1.0, interval)
        restartPolling()
    }

    var isMusicRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: MusicMonitor.bundleIdentifier).isEmpty
    }

    // MARK: - Internals

    private func restartPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        pollTimer?.tolerance = 0.3
    }

    private func scheduleRefresh(after delay: TimeInterval) {
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refresh() }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func compileScript() {
        // Wrapping every property in `try` keeps radio streams and cloud tracks with
        // missing metadata from aborting the whole query.
        let source = """
        tell application "Music"
            set ps to player state
            if ps is stopped then return {"stopped"}
            set stateText to "paused"
            if ps is playing then set stateText to "playing"
            try
                set t to current track
            on error
                return {"stopped"}
            end try
            set pos to 0
            try
                set pos to player position
            end try
            set trackName to ""
            set trackArtist to ""
            set trackAlbum to ""
            set trackAlbumArtist to ""
            set trackDuration to 0
            set trackPID to ""
            set trackKind to ""
            set trackYear to 0
            try
                set trackName to name of t
            end try
            try
                set trackArtist to artist of t
            end try
            try
                set trackAlbum to album of t
            end try
            try
                set trackAlbumArtist to album artist of t
            end try
            try
                set trackDuration to duration of t
            end try
            try
                set trackPID to persistent ID of t
            end try
            try
                set trackKind to kind of t
            end try
            try
                set trackYear to year of t
            end try
            return {stateText, pos, trackName, trackArtist, trackAlbum, trackAlbumArtist, trackDuration, trackPID, trackKind, trackYear}
        end tell
        """
        var error: NSDictionary?
        script = NSAppleScript(source: source)
        if script?.compileAndReturnError(&error) != true {
            Log.shared.error("AppleScript: compile failed: \(error ?? [:])")
        }
    }

    /// Queries Music.app and publishes a snapshot. Never launches Music.
    func refresh() {
        guard isMusicRunning else {
            onSnapshot?(nil)
            return
        }
        guard let script else { return }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error {
            let code = error[NSAppleScript.errorNumber] as? Int ?? 0
            // -1712 = Apple event timed out (Music busy), -600 = app not running.
            Log.shared.warn("AppleScript: execution failed (\(code)): \(error[NSAppleScript.errorMessage] ?? "")")
            return
        }
        onSnapshot?(Self.parse(result))
    }

    private static func parse(_ desc: NSAppleEventDescriptor) -> NowPlaying? {
        guard desc.numberOfItems >= 1,
              let stateText = desc.atIndex(1)?.stringValue else { return nil }
        if stateText == "stopped" || desc.numberOfItems < 10 { return nil }
        let state: NowPlaying.State = stateText == "playing" ? .playing : .paused
        func str(_ i: Int) -> String { desc.atIndex(i)?.stringValue ?? "" }
        func dbl(_ i: Int) -> Double {
            guard let d = desc.atIndex(i) else { return 0 }
            if let s = d.stringValue, let v = Double(s) { return v }
            return d.doubleValue
        }
        let title = str(3)
        if title.isEmpty { return nil }
        return NowPlaying(
            state: state,
            title: title,
            artist: str(4),
            album: str(5),
            albumArtist: str(6),
            duration: dbl(7),
            position: dbl(2),
            sampledAt: Date(),
            persistentID: str(8),
            kind: str(9),
            year: Int(desc.atIndex(10)?.int32Value ?? 0)
        )
    }
}
