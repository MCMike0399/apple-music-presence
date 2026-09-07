import Foundation

struct NowPlaying: Equatable {
    enum State: String { case playing, paused }

    var state: State
    var title: String
    var artist: String
    var album: String
    var albumArtist: String
    var duration: TimeInterval
    /// Playback position at `sampledAt`.
    var position: TimeInterval
    var sampledAt: Date
    var persistentID: String
    var kind: String
    var year: Int

    /// Identity of the track independent of position/state.
    var trackKey: String { "\(persistentID)|\(title)|\(artist)|\(album)" }

    /// Estimated position right now, assuming playback continued since sampling.
    func estimatedPosition(at date: Date = Date()) -> TimeInterval {
        guard state == .playing else { return position }
        return position + date.timeIntervalSince(sampledAt)
    }
}
