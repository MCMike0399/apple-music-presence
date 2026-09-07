import Foundation

/// Cover art and store links for a track. Two sources, both served from Apple's CDN
/// (so Discord can proxy the image) and both credential-free:
///
/// 1. The Apple Music catalog API used by the music.apple.com web player. Its public
///    developer token is embedded in the web player's JavaScript bundle, valid for a
///    few months, and re-fetched when it expires. This is the source the original
///    Music Presence uses and it covers new releases the day they come out.
/// 2. The iTunes Search API as a fallback. No token, but its index lags behind.
///
/// Every result is scored against the local metadata because both searches are fuzzy
/// and the first hit is frequently a cover version or a karaoke track.
struct TrackLinks: Codable, Equatable {
    var artworkURL: String?   // 600x600 JPEG on mzstatic
    var trackURL: String?
    var albumURL: String?
    var artistURL: String?
}

/// A search hit from either source, normalised for scoring.
struct Candidate {
    var title: String
    var artist: String
    var album: String
    var durationMillis: Double
    var links: TrackLinks
}

final class ArtworkResolver {
    private var cache: [String: TrackLinks] = [:]
    private var inFlight: [String: [(TrackLinks) -> Void]] = [:]
    private let session: URLSession
    private let catalog: AppleMusicCatalog
    private let queue = DispatchQueue(label: "amp.artwork")
    private let maxCacheEntries = 500

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.httpAdditionalHeaders = ["User-Agent": "AppleMusicPresence/1.0 (macOS)"]
        session = URLSession(configuration: config)
        catalog = AppleMusicCatalog(session: session)
        loadCache()
    }

    static func cacheKey(for track: NowPlaying) -> String {
        "\(track.artist)|\(track.album)|\(track.title)|\(Int(track.duration.rounded()))"
    }

    /// Completion is called on the main thread exactly once.
    func resolve(_ track: NowPlaying, country: String, completion: @escaping (TrackLinks) -> Void) {
        let key = Self.cacheKey(for: track)
        queue.async {
            if let hit = self.cache[key] {
                DispatchQueue.main.async { completion(hit) }
                return
            }
            if self.inFlight[key] != nil {
                self.inFlight[key]?.append(completion)
                return
            }
            self.inFlight[key] = [completion]
            self.lookup(track, country: country) { links in
                self.queue.async {
                    let result = links ?? TrackLinks()
                    // Only remember hits; a miss may be a transient network problem.
                    if links != nil {
                        self.cache[key] = result
                        self.trimCacheIfNeeded()
                        self.saveCache()
                    }
                    let waiters = self.inFlight.removeValue(forKey: key) ?? []
                    DispatchQueue.main.async { waiters.forEach { $0(result) } }
                }
            }
        }
    }

    func cached(_ track: NowPlaying) -> TrackLinks? {
        queue.sync { cache[Self.cacheKey(for: track)] }
    }

    // MARK: - Lookup chain

    private func lookup(_ track: NowPlaying, country: String, completion: @escaping (TrackLinks?) -> Void) {
        let primaryArtist = Normalizer.primaryArtist(track.artist)
        let songTerm = "\(primaryArtist) \(Normalizer.stripDecorations(track.title))"

        catalog.searchSongs(term: songTerm, storefront: country) { candidates in
            if let best = Scorer.bestSong(from: candidates, for: track) {
                Log.shared.info("Catalog: matched \(track.title) by \(track.artist)")
                completion(best); return
            }
            self.itunes(term: songTerm, entity: "song", country: country, limit: 25) { results in
                let candidates = results.compactMap(Self.itunesSongCandidate)
                if let best = Scorer.bestSong(from: candidates, for: track) {
                    Log.shared.info("iTunes: matched \(track.title) by \(track.artist)")
                    completion(best); return
                }
                guard !track.album.isEmpty else { completion(nil); return }
                let albumTerm = "\(primaryArtist) \(Normalizer.cleanAlbum(track.album))"
                self.itunes(term: albumTerm, entity: "album", country: country, limit: 10) { results in
                    let candidates = results.compactMap(Self.itunesAlbumCandidate)
                    let best = Scorer.bestAlbum(from: candidates, for: track)
                    if best != nil { Log.shared.info("iTunes: matched album \(track.album) by \(track.artist)") }
                    completion(best)
                }
            }
        }
    }

    // MARK: - iTunes Search API

    private func itunes(term: String, entity: String, country: String, limit: Int,
                        completion: @escaping ([[String: Any]]) -> Void) {
        var components = URLComponents(string: "https://itunes.apple.com/search")!
        components.queryItems = [
            URLQueryItem(name: "term", value: term),
            URLQueryItem(name: "entity", value: entity),
            URLQueryItem(name: "media", value: "music"),
            URLQueryItem(name: "country", value: country),
            URLQueryItem(name: "limit", value: String(limit)),
        ]
        guard let url = components.url else { completion([]); return }
        session.dataTask(with: url) { data, response, error in
            if let error {
                Log.shared.warn("iTunes: request failed: \(error.localizedDescription)")
                completion([]); return
            }
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                Log.shared.warn("iTunes: HTTP \(http.statusCode) for \(entity) '\(term)'")
                completion([]); return
            }
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let results = json["results"] as? [[String: Any]] else {
                completion([]); return
            }
            completion(results)
        }.resume()
    }

    private static func itunesSongCandidate(_ r: [String: Any]) -> Candidate? {
        guard r["kind"] as? String == "song" else { return nil }
        return Candidate(
            title: r["trackName"] as? String ?? "",
            artist: r["artistName"] as? String ?? "",
            album: r["collectionName"] as? String ?? "",
            durationMillis: r["trackTimeMillis"] as? Double ?? 0,
            links: TrackLinks(
                artworkURL: Artwork.upscaleITunes(r["artworkUrl100"] as? String),
                trackURL: Artwork.cleanURL(r["trackViewUrl"] as? String),
                albumURL: Artwork.cleanURL(r["collectionViewUrl"] as? String),
                artistURL: Artwork.cleanURL(r["artistViewUrl"] as? String)
            )
        )
    }

    private static func itunesAlbumCandidate(_ r: [String: Any]) -> Candidate? {
        guard r["collectionType"] as? String == "Album" || r["wrapperType"] as? String == "collection" else { return nil }
        return Candidate(
            title: "",
            artist: r["artistName"] as? String ?? "",
            album: r["collectionName"] as? String ?? "",
            durationMillis: 0,
            links: TrackLinks(
                artworkURL: Artwork.upscaleITunes(r["artworkUrl100"] as? String),
                trackURL: nil,
                albumURL: Artwork.cleanURL(r["collectionViewUrl"] as? String),
                artistURL: Artwork.cleanURL(r["artistViewUrl"] as? String)
            )
        )
    }

    // MARK: - Cache persistence

    private func loadCache() {
        guard let data = try? Data(contentsOf: Paths.cacheFile),
              let stored = try? JSONDecoder().decode([String: TrackLinks].self, from: data) else { return }
        cache = stored
    }

    private func saveCache() {
        guard let data = try? JSONEncoder().encode(cache) else { return }
        try? data.write(to: Paths.cacheFile, options: .atomic)
    }

    private func trimCacheIfNeeded() {
        guard cache.count > maxCacheEntries else { return }
        // No access-order tracking; dropping an arbitrary half is good enough for a lookup cache.
        for key in Array(cache.keys.prefix(cache.count / 2)) { cache.removeValue(forKey: key) }
    }
}

// MARK: - Apple Music catalog (web player API)

final class AppleMusicCatalog {
    private let session: URLSession
    private let queue = DispatchQueue(label: "amp.catalog")
    private var token: String?
    private var tokenExpiry: Date = .distantPast
    private var tokenFetchInFlight: [(String?) -> Void] = []
    private var nextTokenAttempt: Date = .distantPast
    private let tokenFile = Paths.supportDirectory.appendingPathComponent("catalog-token.json")

    init(session: URLSession) {
        self.session = session
        loadToken()
    }

    func searchSongs(term: String, storefront: String, completion: @escaping ([Candidate]) -> Void) {
        withToken { token in
            guard let token else { completion([]); return }
            var components = URLComponents(string: "https://amp-api.music.apple.com/v1/catalog/\(storefront)/search")!
            components.queryItems = [
                URLQueryItem(name: "term", value: term),
                URLQueryItem(name: "types", value: "songs"),
                URLQueryItem(name: "limit", value: "10"),
            ]
            guard let url = components.url else { completion([]); return }
            var request = URLRequest(url: url)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("https://music.apple.com", forHTTPHeaderField: "Origin")
            self.session.dataTask(with: request) { data, response, error in
                if let error {
                    Log.shared.warn("Catalog: request failed: \(error.localizedDescription)")
                    completion([]); return
                }
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                if status == 401 || status == 403 {
                    Log.shared.warn("Catalog: token rejected (HTTP \(status)); will refresh")
                    self.queue.async { self.token = nil; self.tokenExpiry = .distantPast }
                    completion([]); return
                }
                guard status == 200, let data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let results = json["results"] as? [String: Any],
                      let songs = (results["songs"] as? [String: Any])?["data"] as? [[String: Any]] else {
                    if status != 200 { Log.shared.warn("Catalog: HTTP \(status) for '\(term)'") }
                    completion([]); return
                }
                completion(songs.compactMap(Self.candidate))
            }.resume()
        }
    }

    private static func candidate(_ song: [String: Any]) -> Candidate? {
        guard let a = song["attributes"] as? [String: Any] else { return nil }
        let trackURL = a["url"] as? String
        // The song URL is "<album url>?i=<song id>"; the album page is the same URL without the query.
        let albumURL = trackURL.flatMap { URLComponents(string: $0) }.map { c -> String in
            var c = c; c.query = nil; return c.string ?? ""
        }
        let artworkTemplate = (a["artwork"] as? [String: Any])?["url"] as? String
        return Candidate(
            title: a["name"] as? String ?? "",
            artist: a["artistName"] as? String ?? "",
            album: a["albumName"] as? String ?? "",
            durationMillis: a["durationInMillis"] as? Double ?? 0,
            links: TrackLinks(
                artworkURL: Artwork.renderTemplate(artworkTemplate),
                trackURL: trackURL,
                albumURL: albumURL,
                artistURL: nil
            )
        )
    }

    // MARK: Token

    private func withToken(_ completion: @escaping (String?) -> Void) {
        queue.async {
            if let token = self.token, self.tokenExpiry > Date().addingTimeInterval(3600) {
                completion(token); return
            }
            if Date() < self.nextTokenAttempt {
                completion(nil); return
            }
            self.tokenFetchInFlight.append(completion)
            guard self.tokenFetchInFlight.count == 1 else { return }
            self.fetchToken { token in
                self.queue.async {
                    if let token {
                        self.token = token
                        self.tokenExpiry = Self.expiry(of: token) ?? Date().addingTimeInterval(86400)
                        self.saveToken()
                        Log.shared.info("Catalog: obtained web token, valid until \(self.tokenExpiry)")
                    } else {
                        self.nextTokenAttempt = Date().addingTimeInterval(600)
                        Log.shared.warn("Catalog: could not obtain a web token; falling back to iTunes Search for 10 minutes")
                    }
                    let waiters = self.tokenFetchInFlight
                    self.tokenFetchInFlight.removeAll()
                    waiters.forEach { $0(token) }
                }
            }
        }
    }

    /// Scrapes the developer token out of the web player's main JavaScript bundle.
    private func fetchToken(_ completion: @escaping (String?) -> Void) {
        let homepage = URL(string: "https://music.apple.com/us/browse")!
        session.dataTask(with: homepage) { data, _, _ in
            guard let data, let html = String(data: data, encoding: .utf8) else { completion(nil); return }
            let bundlePattern = try! NSRegularExpression(pattern: #"/assets/index[^"']*\.js"#)
            let matches = bundlePattern.matches(in: html, range: NSRange(html.startIndex..., in: html))
            var paths = Array(Set(matches.map { String(html[Range($0.range, in: html)!]) })).sorted()
            func tryNext() {
                guard !paths.isEmpty else { completion(nil); return }
                let path = paths.removeFirst()
                self.session.dataTask(with: URL(string: "https://music.apple.com\(path)")!) { data, _, _ in
                    if let data, let js = String(data: data, encoding: .utf8),
                       let token = Self.extractJWT(from: js), Self.expiry(of: token).map({ $0 > Date() }) ?? false {
                        completion(token)
                    } else {
                        tryNext()
                    }
                }.resume()
            }
            tryNext()
        }.resume()
    }

    private static func extractJWT(from js: String) -> String? {
        let pattern = try! NSRegularExpression(pattern: #"eyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}"#)
        let range = NSRange(js.startIndex..., in: js)
        for m in pattern.matches(in: js, range: range) {
            let token = String(js[Range(m.range, in: js)!])
            if let claims = claims(of: token), claims["iss"] as? String == "AMPWebPlay" { return token }
        }
        return nil
    }

    private static func claims(of token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 { payload += "=" }
        guard let data = Data(base64Encoded: payload) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func expiry(of token: String) -> Date? {
        guard let exp = claims(of: token)?["exp"] as? Double else { return nil }
        return Date(timeIntervalSince1970: exp)
    }

    private struct StoredToken: Codable { var token: String; var expiry: Date }

    private func loadToken() {
        guard let data = try? Data(contentsOf: tokenFile),
              let stored = try? JSONDecoder().decode(StoredToken.self, from: data) else { return }
        token = stored.token
        tokenExpiry = stored.expiry
    }

    private func saveToken() {
        guard let token, let data = try? JSONEncoder().encode(StoredToken(token: token, expiry: tokenExpiry)) else { return }
        try? data.write(to: tokenFile, options: .atomic)
    }
}

// MARK: - Scoring

enum Scorer {
    static func bestSong(from candidates: [Candidate], for track: NowPlaying) -> TrackLinks? {
        let wantTitle = Normalizer.key(track.title)
        let wantTitleBare = Normalizer.key(Normalizer.stripDecorations(track.title))
        let wantArtist = Normalizer.key(track.artist)
        let wantArtists = Normalizer.splitArtists(track.artist).map(Normalizer.key)
        let wantAlbum = Normalizer.key(Normalizer.cleanAlbum(track.album))

        var best: (score: Int, links: TrackLinks)?
        for c in candidates {
            let title = Normalizer.key(c.title)
            let titleBare = Normalizer.key(Normalizer.stripDecorations(c.title))
            let artist = Normalizer.key(c.artist)
            let album = Normalizer.key(Normalizer.cleanAlbum(c.album))

            var score = 0
            if title == wantTitle { score += 4 }
            else if titleBare == wantTitleBare { score += 3 }
            else if title.contains(wantTitleBare) || wantTitle.contains(titleBare) { score += 1 }
            else { continue } // title must at least overlap

            if artist == wantArtist { score += 3 }
            else if wantArtists.contains(where: { !$0.isEmpty && (artist.contains($0) || $0.contains(artist)) }) { score += 2 }
            else { continue } // wrong artist is never acceptable (covers, tributes, karaoke)

            if !wantAlbum.isEmpty && album == wantAlbum { score += 3 }
            else if !wantAlbum.isEmpty && (album.contains(wantAlbum) || wantAlbum.contains(album)) { score += 1 }

            if track.duration > 0 && c.durationMillis > 0 {
                let delta = abs(c.durationMillis / 1000 - track.duration)
                if delta <= 2 { score += 3 } else if delta <= 6 { score += 1 } else if delta > 30 { score -= 2 }
            }

            if best == nil || score > best!.score { best = (score, c.links) }
        }
        guard let best, best.score >= 5 else { return nil }
        return best.links
    }

    static func bestAlbum(from candidates: [Candidate], for track: NowPlaying) -> TrackLinks? {
        let wantAlbum = Normalizer.key(Normalizer.cleanAlbum(track.album))
        let wantArtists = Normalizer.splitArtists(track.artist.isEmpty ? track.albumArtist : track.artist).map(Normalizer.key)
        for c in candidates {
            let album = Normalizer.key(Normalizer.cleanAlbum(c.album))
            let artist = Normalizer.key(c.artist)
            guard album == wantAlbum,
                  wantArtists.contains(where: { !$0.isEmpty && (artist.contains($0) || $0.contains(artist)) })
            else { continue }
            return c.links
        }
        return nil
    }
}

enum Artwork {
    static let size = "600x600"

    static func upscaleITunes(_ url: String?) -> String? {
        url?.replacingOccurrences(of: "100x100bb", with: "\(size)bb")
    }

    /// Catalog artwork URLs are templates: ".../{w}x{h}bb.{f}" (the format placeholder is optional).
    static func renderTemplate(_ template: String?) -> String? {
        template?
            .replacingOccurrences(of: "{w}x{h}", with: size)
            .replacingOccurrences(of: "{f}", with: "jpg")
    }

    /// Drops the affiliate `uo=4` tracking parameter Apple appends.
    static func cleanURL(_ url: String?) -> String? {
        guard let url, var components = URLComponents(string: url) else { return url }
        components.queryItems = components.queryItems?.filter { $0.name != "uo" }
        if components.queryItems?.isEmpty == true { components.queryItems = nil }
        return components.string
    }
}

enum Normalizer {
    /// Lowercased, diacritics folded, punctuation removed, whitespace collapsed.
    static func key(_ s: String) -> String {
        let folded = s.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: nil)
            .lowercased()
            .replacingOccurrences(of: "&", with: "and")
        let scalars = folded.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
        return String(scalars).split(separator: " ").joined(separator: " ")
    }

    /// Removes "(feat. X)", "[Remastered]", "- Live" style decorations from a title.
    static func stripDecorations(_ title: String) -> String {
        var t = title
        for pattern in [#"\s*[\(\[][^\)\]]*[\)\]]"#, #"\s+[-\u{2013}\u{2014}]\s+.*$"#] {
            t = t.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        let trimmed = t.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? title : trimmed
    }

    static func cleanAlbum(_ album: String) -> String {
        album.replacingOccurrences(of: #"\s+[-\u{2013}\u{2014}]\s+(Single|EP)$"#, with: "", options: .regularExpression)
    }

    static func splitArtists(_ artist: String) -> [String] {
        artist.components(separatedBy: CharacterSet(charactersIn: ",&/"))
            .flatMap { $0.components(separatedBy: " feat. ") }
            .flatMap { $0.components(separatedBy: " ft. ") }
            .flatMap { $0.components(separatedBy: " x ") }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    static func primaryArtist(_ artist: String) -> String {
        splitArtists(artist).first ?? artist
    }
}
