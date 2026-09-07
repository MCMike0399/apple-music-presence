import Foundation

/// Turns a Music.app snapshot into a Discord activity payload.
enum PresenceBuilder {
    static let appleMusicLogoURL = "https://music.apple.com/assets/favicon/favicon-180.png"
    static let stationRegex = try! NSRegularExpression(
        pattern: #"(.+’s Station|.+'s Station|Estación de .+|Station de : .+|Stazione di .+|Station van .+|.+s Sender|Estação de .+)"#
    )

    static func isPersonalStation(_ track: NowPlaying) -> Bool {
        for text in [track.title, track.album, track.artist] {
            let range = NSRange(text.startIndex..., in: text)
            if stationRegex.firstMatch(in: text, range: range) != nil { return true }
        }
        return false
    }

    static func activity(for track: NowPlaying, links: TrackLinks, settings: Settings) -> [String: Any]? {
        if track.state == .paused && !settings.showPausedMedia { return nil }
        if settings.hidePersonalStations && isPersonalStation(track) { return nil }

        let album = settings.cleanAlbumSuffixes ? Normalizer.cleanAlbum(track.album) : track.album
        let artist = track.artist.isEmpty ? track.albumArtist : track.artist

        var activity: [String: Any] = [
            "type": 2, // Listening
            "status_display_type": settings.displayType.discordValue,
            "details": clamp(track.title),
        ]
        if !artist.isEmpty {
            activity["state"] = clamp(artist)
        } else if settings.displayType == .artist {
            // Nothing sensible to show as "Listening to <artist>"; fall back to the app name.
            activity["status_display_type"] = 0
        }
        if let url = links.trackURL { activity["details_url"] = url }
        if let url = links.artistURL { activity["state_url"] = url }

        var assets: [String: Any] = [
            "large_image": links.artworkURL ?? appleMusicLogoURL,
        ]
        if settings.showAlbumName && !album.isEmpty {
            assets["large_text"] = clamp(album)
        }
        if let url = links.albumURL { assets["large_url"] = url }
        if track.state == .paused {
            assets["small_image"] = appleMusicLogoURL
            assets["small_text"] = "Paused"
        } else if settings.showPlayerLogo && links.artworkURL != nil {
            assets["small_image"] = appleMusicLogoURL
            assets["small_text"] = "Apple Music"
        }
        activity["assets"] = assets

        if track.state == .playing && track.duration > 0 {
            let start = track.sampledAt.addingTimeInterval(-track.position)
            let end = start.addingTimeInterval(track.duration)
            activity["timestamps"] = [
                "start": Int(start.timeIntervalSince1970 * 1000),
                "end": Int(end.timeIntervalSince1970 * 1000),
            ]
        }

        if settings.showButtons, let url = links.trackURL ?? links.albumURL {
            activity["buttons"] = [["label": "Play on Apple Music", "url": url]]
        }
        return activity
    }

    /// Discord requires 2...128 characters for text fields.
    private static func clamp(_ s: String) -> String {
        var text = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.count > 128 { text = String(text.prefix(127)) + "…" }
        while text.count < 2 { text += "\u{2009}" } // thin space keeps 1-char titles valid
        return text
    }

    static func describe(_ track: NowPlaying) -> String {
        var s = "\(track.title)"
        if !track.artist.isEmpty { s += " by \(track.artist)" }
        if !track.album.isEmpty { s += " on \(track.album)" }
        let pos = Int(track.estimatedPosition()), dur = Int(track.duration)
        s += " [\(pos / 60):\(String(format: "%02d", pos % 60))/\(dur / 60):\(String(format: "%02d", dur % 60)) \(track.state.rawValue)]"
        return s
    }
}
