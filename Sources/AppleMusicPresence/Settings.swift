import Foundation

/// What Discord shows after "Listening to …" in the member list / profile header.
enum DisplayType: String, Codable, CaseIterable {
    case player   // "Listening to Apple Music"
    case artist   // "Listening to <artist>"
    case title    // "Listening to <song title>"

    var menuTitle: String {
        switch self {
        case .player: return "Apple Music"
        case .artist: return "Artist name"
        case .title: return "Song title"
        }
    }

    /// Discord `status_display_type`: 0 = name, 1 = state, 2 = details.
    var discordValue: Int {
        switch self {
        case .player: return 0
        case .artist: return 1
        case .title: return 2
        }
    }
}

struct Settings: Codable, Equatable {
    /// Master switch. When off the presence is cleared and Discord is disconnected.
    var enabled: Bool = true
    /// Discord application whose name is shown as "Listening to <name>".
    /// Defaults to the public "Apple Music" application used by the Music Presence project.
    /// Create your own at https://discord.com/developers/applications to customise the name.
    var discordApplicationId: String = "1247654840780460125"
    var displayType: DisplayType = .player
    /// Keep the presence visible while playback is paused (without a progress bar).
    var showPausedMedia: Bool = false
    var showAlbumName: Bool = true
    /// "Play on Apple Music" button linking to the track.
    var showButtons: Bool = true
    /// Small Apple Music logo in the corner of the cover art.
    var showPlayerLogo: Bool = true
    /// Strip " - Single" / " - EP" from album names.
    var cleanAlbumSuffixes: Bool = true
    /// Hide personal radio stations ("Someone's Station") for privacy.
    var hidePersonalStations: Bool = true
    /// Storefront for iTunes lookups and links (ISO 3166-1 alpha-2). nil = current locale.
    var countryCode: String? = nil
    /// How often to poll Music.app for the playback position (seconds).
    var pollIntervalSeconds: Double = 2.0
    /// Menu bar icon. When hidden, launch the app again (or set this to true) to bring it back.
    var showMenuBarIcon: Bool = true

    static func load() -> Settings {
        guard let data = try? Data(contentsOf: Paths.settingsFile) else {
            let defaults = Settings()
            defaults.save()
            return defaults
        }
        do {
            return try JSONDecoder().decode(Settings.self, from: data)
        } catch {
            Log.shared.error("Settings: could not parse \(Paths.settingsFile.path): \(error). Using defaults.")
            return Settings()
        }
    }

    func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try encoder.encode(self).write(to: Paths.settingsFile, options: .atomic)
        } catch {
            Log.shared.error("Settings: could not save: \(error)")
        }
    }

    var effectiveCountryCode: String {
        if let code = countryCode, code.count == 2 { return code.lowercased() }
        return (Locale.current.region?.identifier ?? "us").lowercased()
    }
}
