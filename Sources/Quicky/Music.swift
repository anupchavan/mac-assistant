import AppKit
import CryptoKit
import Foundation

/// Songs, albums, artists, lyrics and what's playing.
///
/// Sources, measured from India on 22 Oct 2026 (experiments/music-bench, 18 mainstream-to-niche queries):
/// - YouTube Music (the web client's own search API): 18/18 found, ~520 ms. The only source that has
///   OSTs, anime and game music, Coke Studio and unofficial uploads. Also has lyrics for most songs.
/// - iTunes Search (country storefront): 18/18 in the India store, ~450 ms first hit, cached repeats ~20 ms.
///   Clean metadata: album, release date, genre, track number, Apple Music link.
/// - LRCLIB: time-synced lyrics, ~200-400 ms when it answers; misses and rate-limits under load, so
///   every answer (and miss) is cached on disk and YouTube Music's lyrics are the fallback.
/// - MusicBrainz: credits (composer, lyricist), only on demand: it allows one request per second.
/// - Deezer returns nothing from India, so it isn't used.
enum Music: QuickyExtension {
    static let id = "music"
    static let when = "The user wants to know something about a song, album, artist or soundtrack (who sang it, which film or album it's from, release year, tracklist, credits), wants lyrics, or asks what song is playing."
    static let cues = #"\b(song|songs|lyrics?|album|singer|sang|sung|track|tracklist|ost|soundtrack|playing|gaana|gana|gaane|bol|music)\b"#
    static let readOnly: Set<String> = ["music_search", "music_album", "lyrics", "now_playing", "music_credits"]

    static let tools: [[String: Any]] = {
        let s: [String: Any] = ["type": "string"]
        return [
            Extensions.fn("music_search", "Find songs, albums or artists, including soundtracks, anime/game music and songs not on Apple Music here. Returns title, artists, album, year, length and links. Use it to identify a song or answer who sang it / which film it's from.",
                          ["query": ["type": "string", "description": "Song, album or artist words as the user said them, plus any film or show"],
                           "kind": ["type": "string", "enum": ["song", "album", "artist"], "description": "Default song"]], ["query"]),
            Extensions.fn("music_album", "An album or soundtrack's tracklist with release year and label.", ["query": ["type": "string", "description": "Album or film name, with the artist if known"]], ["query"]),
            Extensions.fn("lyrics", "Lyrics of a song. With no title, the song playing now, with the line being sung marked.",
                          ["title": s, "artist": s, "album": s,
                           "seconds": ["type": "number", "description": "Song length in seconds, if known from music_search; improves the match"]], []),
            Extensions.fn("now_playing", "The song playing now in Music or Spotify: title, artist, album, position.", [:], []),
            Extensions.fn("music_credits", "Who wrote, composed and produced a song (slow, about 3 s).", ["title": s, "artist": s], ["title"]),
        ]
    }()

    static func run(_ call: ToolCall) async -> String? {
        switch call.name {
        case "music_search": return await search(call.string("query"), kind: call.string("kind").isEmpty ? "song" : call.string("kind"))
        case "music_album": return await album(call.string("query"))
        case "lyrics": return await lyrics(title: call.string("title"), artist: call.string("artist"), album: call.string("album"),
                                           seconds: (call.arguments["seconds"] as? NSNumber)?.doubleValue)
        case "now_playing": return await NowPlaying.read()?.line ?? "Nothing is playing in Music or Spotify."
        case "music_credits": return await credits(title: call.string("title"), artist: call.string("artist"))
        default: return nil
        }
    }

    static var country: String { (Locale.current.region?.identifier ?? "IN").lowercased() }

    // MARK: Search

    struct Hit {
        var title: String, artists: String, album = "", year = "", length = "", seconds: Double? = nil
        var source: String, link = "", extra = ""
        var line: String {
            [title, artists.isEmpty ? nil : "by \(artists)", album.isEmpty ? nil : "album \(album)", year.isEmpty ? nil : year,
             length.isEmpty ? nil : length, extra.isEmpty ? nil : extra, link.isEmpty ? nil : link]
                .compactMap { $0 }.joined(separator: " · ") + " [\(source)]"
        }
    }

    static func search(_ query: String, kind: String) async -> String {
        guard !query.isEmpty else { return "error: no query" }
        let t0 = Date()
        async let yt = YTMusic.search(query, kind: kind)
        async let it = iTunes.search(query, kind: kind)
        let (y, i) = await (yt, it)
        Log.time("music_search ytmusic \(y.count), itunes \(i.count)", since: t0)
        // YouTube Music ranks better for loose spoken queries; iTunes adds clean dates and the Apple link.
        var out: [String] = []
        for h in y.prefix(5) {
            var h = h
            if let m = i.first(where: { same($0, h) }) {
                if h.year.isEmpty { h.year = m.year }
                if h.album.isEmpty { h.album = m.album }
                h.extra = [m.extra, m.link].filter { !$0.isEmpty }.joined(separator: " · ")
                h.source += "+itunes"
            }
            out.append(h.line)
        }
        for h in i.prefix(5) where !y.contains(where: { same($0, h) }) && out.count < 7 { out.append(h.line) }
        return out.isEmpty ? "No results for “\(query)”." : out.joined(separator: "\n")
    }

    static func same(_ a: Hit, _ b: Hit) -> Bool {
        func key(_ s: String) -> String { s.lowercased().components(separatedBy: CharacterSet(charactersIn: "([-–|")).first?.filter { $0.isLetter || $0.isNumber } ?? "" }
        // "紅蓮華 - Gurenge" and "Gurenge" are one title: compare letters only, either containing the other.
        func flat(_ s: String) -> String { s.lowercased().filter { $0.isLetter || $0.isNumber } }
        let (x, y) = (flat(a.title), flat(b.title))
        guard key(a.title) == key(b.title) || (min(x.count, y.count) >= 4 && (x.contains(y) || y.contains(x))),
              !key(a.title).isEmpty else { return false }
        // Same title isn't the same recording: covers share it. Need a shared artist name and, when both
        // lengths are known, lengths within 5 s.
        func names(_ s: String) -> Set<String> {
            Set(s.lowercased().components(separatedBy: CharacterSet(charactersIn: ",&·")).map { $0.filter { $0.isLetter || $0.isNumber } }.filter { !$0.isEmpty })
        }
        guard !names(a.artists).isDisjoint(with: names(b.artists)) else { return false }
        if let x = a.seconds, let y = b.seconds, abs(x - y) > 5 { return false }
        return true
    }

    static func album(_ query: String) async -> String {
        let t0 = Date()
        if let a = await iTunes.album(query) { Log.time("music_album itunes", since: t0); return a }
        if let a = await YTMusic.album(query) { Log.time("music_album ytmusic", since: t0); return a }
        return "No album found for “\(query)”."
    }

    // MARK: Lyrics

    static func lyrics(title: String, artist: String, album: String, seconds: Double?) async -> String {
        var title = title, artist = artist, album = album, seconds = seconds
        var position: Double?
        if title.isEmpty {
            guard let np = await NowPlaying.read() else { return "Nothing is playing; which song?" }
            title = np.title; artist = np.artist; album = np.album; seconds = np.duration; position = np.position
        }
        let t0 = Date()
        if let l = await LRCLib.get(title: title, artist: artist, album: album, seconds: seconds) {
            Log.time("lyrics lrclib (\(l.synced.isEmpty ? "plain" : "synced"))", since: t0)
            if let position, !l.synced.isEmpty { return "\(title) by \(artist), at \(Int(position)) s:\n" + LRCLib.around(l.synced, at: position) }
            return "\(title) by \(artist):\n" + l.plain
        }
        if let l = await YTMusic.lyrics(title: title, artist: artist) {
            Log.time("lyrics ytmusic", since: t0)
            return "\(title) by \(artist)\(position.map { " (playing at \(Int($0)) s; these lyrics aren't timed)" } ?? ""):\n" + l
        }
        return "No lyrics found for \(title)\(artist.isEmpty ? "" : " by \(artist)")."
    }

    // MARK: Credits (MusicBrainz, 1 request per second)

    private static let mbGate = Locked(Date.distantPast)

    static func mb(_ path: String) async -> [String: Any]? {
        let wait = 1.05 - Date().timeIntervalSince(mbGate.value)
        if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
        mbGate.value = Date()
        return await HTTP.json("https://musicbrainz.org/ws/2/\(path)\(path.contains("?") ? "&" : "?")fmt=json") as? [String: Any]
    }

    static func credits(title: String, artist: String) async -> String {
        // Artist as loose words, not a quoted phrase: "A.R. Rahman" is "A. R. Rahman" in MusicBrainz.
        let words = String(artist.map { $0.isLetter || $0.isNumber ? $0 : " " }).split(separator: " ").joined(separator: " ")
        let q = "recording:\"\(title)\"" + (words.isEmpty ? "" : " AND artist:(\(words))")
        guard let r = await mb("recording?limit=1&query=\(HTTP.enc(q))"),
              let rec = (r["recordings"] as? [[String: Any]])?.first, let rid = rec["id"] as? String,
              let full = await mb("recording/\(rid)?inc=artist-credits+artist-rels+work-rels+releases") else {
            return "No credits found for \(title)."
        }
        var lines = ["\(full["title"] as? String ?? title) by \(((full["artist-credit"] as? [[String: Any]]) ?? []).compactMap { $0["name"] as? String }.joined(separator: ", "))"]
        func rels(_ j: [String: Any]) -> [String] {
            ((j["relations"] as? [[String: Any]]) ?? []).compactMap { r in
                guard let a = (r["artist"] as? [String: Any])?["name"] as? String, let t = r["type"] as? String else { return nil }
                return "\(t): \(a)"
            }
        }
        lines += rels(full)
        if let work = ((full["relations"] as? [[String: Any]]) ?? []).first(where: { $0["type"] as? String == "performance" })?["work"] as? [String: Any],
           let wid = work["id"] as? String, let w = await mb("work/\(wid)?inc=artist-rels") {
            lines += rels(w)
        }
        if let rel = (full["releases"] as? [[String: Any]])?.first {
            lines.append("first release: \(rel["title"] as? String ?? "") \(rel["date"] as? String ?? "")")
        }
        return Array(NSOrderedSet(array: lines)).compactMap { $0 as? String }.joined(separator: "\n")
    }
}

// MARK: - HTTP

enum HTTP {
    static let ua = "Quicky/0.1 (https://github.com/anupchavan/quicky)"
    static func enc(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&+=?"))) ?? s }

    static func json(_ url: String, body: [String: Any]? = nil, headers: [String: String] = [:], timeout: TimeInterval = 4) async -> Any? {
        guard let u = URL(string: url) else { return nil }
        var req = URLRequest(url: u)
        req.timeoutInterval = timeout
        req.setValue(ua, forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        if let body {
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        guard let (data, resp) = try? await URLSession.shared.data(for: req) else { return nil }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { Log.info("http \(code) \(u.host ?? "")\(u.path)"); return code == 404 ? NSNull() : nil }
        return try? JSONSerialization.jsonObject(with: data)
    }
}

// MARK: - iTunes Search

enum iTunes {
    static func search(_ q: String, kind: String) async -> [Music.Hit] {
        let entity = ["album": "album", "artist": "musicArtist"][kind] ?? "song"
        guard let j = await HTTP.json("https://itunes.apple.com/search?term=\(HTTP.enc(q))&entity=\(entity)&limit=8&country=\(Music.country)") as? [String: Any],
              let rs = j["results"] as? [[String: Any]] else { return [] }
        return rs.map { r in
            let ms = (r["trackTimeMillis"] as? NSNumber)?.doubleValue
            return Music.Hit(title: (r["trackName"] ?? r["collectionName"] ?? r["artistName"]) as? String ?? "",
                             artists: r["artistName"] as? String ?? "", album: entity == "song" ? (r["collectionName"] as? String ?? "") : "",
                             year: String((r["releaseDate"] as? String ?? "").prefix(10)),
                             length: ms.map { Music.mmss($0 / 1000) } ?? "", seconds: ms.map { $0 / 1000 },
                             source: "itunes", link: (r["trackViewUrl"] ?? r["collectionViewUrl"] ?? r["artistLinkUrl"]) as? String ?? "",
                             extra: r["primaryGenreName"] as? String ?? "")
        }
    }

    static func album(_ q: String) async -> String? {
        guard let j = await HTTP.json("https://itunes.apple.com/search?term=\(HTTP.enc(q))&entity=album&limit=1&country=\(Music.country)") as? [String: Any],
              let a = (j["results"] as? [[String: Any]])?.first, let id = (a["collectionId"] as? NSNumber)?.intValue,
              let t = await HTTP.json("https://itunes.apple.com/lookup?id=\(id)&entity=song&country=\(Music.country)") as? [String: Any],
              let rs = t["results"] as? [[String: Any]] else { return nil }
        let tracks = rs.filter { $0["wrapperType"] as? String == "track" }.map { r in
            "\((r["trackNumber"] as? NSNumber)?.intValue ?? 0). \(r["trackName"] as? String ?? "") — \(r["artistName"] as? String ?? "")" +
            ((r["trackTimeMillis"] as? NSNumber).map { " (\(Music.mmss($0.doubleValue / 1000)))" } ?? "")
        }
        guard !tracks.isEmpty else { return nil }
        let head = "\(a["collectionName"] as? String ?? q) by \(a["artistName"] as? String ?? "") · \(String((a["releaseDate"] as? String ?? "").prefix(4))) · \(a["copyright"] as? String ?? "") · \(a["collectionViewUrl"] as? String ?? "") [itunes]"
        return ([head] + tracks).joined(separator: "\n")
    }
}

extension Music {
    static func mmss(_ s: Double) -> String { String(format: "%d:%02d", Int(s) / 60, Int(s) % 60) }
}

// MARK: - YouTube Music (the web client's API)

enum YTMusic {
    static let endpoint = "https://music.youtube.com/youtubei/v1/"
    static var context: [String: Any] {
        ["client": ["clientName": "WEB_REMIX", "clientVersion": "1.20241023.01.00", "hl": "en", "gl": Music.country.uppercased()]]
    }
    static let filters = ["song": "EgWKAQIIAWoKEAkQBRAKEAMQBA%3D%3D", "album": "EgWKAQIYAWoKEAkQBRAKEAMQBA%3D%3D", "artist": "EgWKAQIgAWoKEAkQBRAKEAMQBA%3D%3D"]

    static func call(_ path: String, _ body: [String: Any]) async -> [String: Any]? {
        var b = body; b["context"] = context
        return await HTTP.json(endpoint + path + "?prettyPrint=false", body: b, headers: ["Origin": "https://music.youtube.com"]) as? [String: Any]
    }

    /// Every dictionary under `key`, anywhere in the response. The page layout shifts; the renderers don't.
    static func all(_ key: String, in j: Any) -> [[String: Any]] {
        var out: [[String: Any]] = []
        func walk(_ v: Any) {
            if let d = v as? [String: Any] {
                if let hit = d[key] as? [String: Any] { out.append(hit) }
                for (_, x) in d { walk(x) }
            } else if let a = v as? [Any] { for x in a { walk(x) } }
        }
        walk(j)
        return out
    }

    static func runs(_ d: [String: Any]?) -> [[String: Any]] { ((d?["text"] as? [String: Any])?["runs"] as? [[String: Any]]) ?? [] }

    /// One result row: title, then "Artist • Album • 3:45" (songs) or "Album • Artist • 2019" (albums).
    static func hit(_ r: [String: Any], kind: String) -> Music.Hit? {
        let cols = ((r["flexColumns"] as? [[String: Any]]) ?? []).map { $0["musicResponsiveListItemFlexColumnRenderer"] as? [String: Any] }
        guard let titleRun = runs(cols.first ?? nil).first, let title = titleRun["text"] as? String else { return nil }
        let parts = cols.dropFirst().flatMap { runs($0) }
        func pageType(_ run: [String: Any]) -> String {
            (((run["navigationEndpoint"] as? [String: Any])?["browseEndpoint"] as? [String: Any])?["browseEndpointContextSupportedConfigs"]
                as? [String: Any]).flatMap { ($0["browseEndpointContextMusicConfig"] as? [String: Any])?["pageType"] as? String } ?? ""
        }
        let texts = parts.compactMap { $0["text"] as? String }.filter { $0 != " • " && $0 != " & " && $0 != ", " }
        let artists = parts.filter { pageType($0) == "MUSIC_PAGE_TYPE_ARTIST" }.compactMap { $0["text"] as? String }
        let album = parts.first { pageType($0) == "MUSIC_PAGE_TYPE_ALBUM" }?["text"] as? String ?? ""
        let length = texts.last { $0.range(of: #"^\d+:\d{2}(:\d{2})?$"#, options: .regularExpression) != nil } ?? ""
        let year = texts.last { $0.range(of: #"^(19|20)\d{2}$"#, options: .regularExpression) != nil } ?? ""
        let videoId = (((r["playlistItemData"] as? [String: Any])?["videoId"]) ?? ((titleRun["navigationEndpoint"] as? [String: Any])?["watchEndpoint"] as? [String: Any])?["videoId"]) as? String
        let browseId = ((r["navigationEndpoint"] as? [String: Any])?["browseEndpoint"] as? [String: Any])?["browseId"] as? String
        let link = videoId.map { "https://music.youtube.com/watch?v=\($0)" } ?? browseId.map { "https://music.youtube.com/browse/\($0)" } ?? ""
        var secs: Double?
        if !length.isEmpty { secs = length.split(separator: ":").reduce(0) { $0 * 60 + (Double($1) ?? 0) } }
        let byline = artists.isEmpty ? (texts.first { $0 != "Song" && $0 != "Album" && $0 != "Single" && $0 != "EP" && $0 != length && $0 != year } ?? "") : artists.joined(separator: ", ")
        return Music.Hit(title: title, artists: byline, album: album, year: year, length: length, seconds: secs, source: "ytmusic", link: link)
    }

    static func search(_ q: String, kind: String) async -> [Music.Hit] {
        guard let j = await call("search", ["query": q, "params": filters[kind] ?? filters["song"]!]) else { return [] }
        return all("musicResponsiveListItemRenderer", in: j).compactMap { hit($0, kind: kind) }
    }

    static func album(_ q: String) async -> String? {
        guard let j = await call("search", ["query": q, "params": filters["album"]!]),
              let first = all("musicResponsiveListItemRenderer", in: j).first,
              let browseId = ((first["navigationEndpoint"] as? [String: Any])?["browseEndpoint"] as? [String: Any])?["browseId"] as? String,
              let page = await call("browse", ["browseId": browseId]) else { return nil }
        let head = hit(first, kind: "album")
        let tracks = all("musicResponsiveListItemRenderer", in: page).enumerated().compactMap { i, r -> String? in
            guard let h = hit(r, kind: "song") else { return nil }
            return "\(i + 1). \(h.title)\(h.artists.isEmpty ? "" : " — \(h.artists)")\(h.length.isEmpty ? "" : " (\(h.length))")"
        }
        guard !tracks.isEmpty else { return nil }
        return ([head.map { "\($0.title) · \($0.artists) · \($0.year) · \($0.link) [ytmusic]" } ?? q] + tracks).joined(separator: "\n")
    }

    /// The lyrics tab of the best match (YouTube Music licenses these; most Indian and OST songs have them).
    static func lyrics(title: String, artist: String) async -> String? {
        guard let videoId = await search("\(title) \(artist)", kind: "song").first?.link.components(separatedBy: "v=").last,
              let next = await call("next", ["videoId": videoId]) else { return nil }
        let tabs = all("tabRenderer", in: next)
        guard let browseId = tabs.compactMap({ (($0["endpoint"] as? [String: Any])?["browseEndpoint"] as? [String: Any])?["browseId"] as? String })
                .first(where: { $0.hasPrefix("MPLYt") }),
              let page = await call("browse", ["browseId": browseId]),
              let shelf = all("musicDescriptionShelfRenderer", in: page).first,
              let text = (((shelf["description"] as? [String: Any])?["runs"] as? [[String: Any]]) ?? []).compactMap({ $0["text"] as? String }).first
        else { return nil }
        let source = (((shelf["footer"] as? [String: Any])?["runs"] as? [[String: Any]]) ?? []).compactMap { $0["text"] as? String }.joined()
        return text + (source.isEmpty ? "" : "\n(\(source))")
    }
}

// MARK: - LRCLIB (cached on disk; it rate-limits)

enum LRCLib {
    struct Lyrics: Codable { var plain: String; var synced: String }
    static let dir: URL = {
        let d = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Quicky/lyrics", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    static func get(title: String, artist: String, album: String, seconds: Double?) async -> Lyrics? {
        let key = "\(title)|\(artist)".lowercased()
        let file = dir.appendingPathComponent(String(SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined().prefix(24)) + ".json")
        if let d = try? Data(contentsOf: file) {
            if d.isEmpty {   // a recent miss; don't ask again for a day
                let age = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate).map { Date().timeIntervalSince($0) } ?? 0
                if age < 86_400 { return nil }
            } else if let l = try? JSONDecoder().decode(Lyrics.self, from: d) { return l }
        }
        var q = "track_name=\(HTTP.enc(title))&artist_name=\(HTTP.enc(artist))"
        if !album.isEmpty { q += "&album_name=\(HTTP.enc(album))" }
        if let seconds { q += "&duration=\(Int(seconds.rounded()))" }
        var found = artist.isEmpty ? nil : await HTTP.json("https://lrclib.net/api/get?\(q)", timeout: 2.5)
        if found == nil || found is NSNull {   // no exact match: best search hit
            let s = await HTTP.json("https://lrclib.net/api/search?track_name=\(HTTP.enc(title))\(artist.isEmpty ? "" : "&artist_name=\(HTTP.enc(artist))")", timeout: 2.5)
            if let list = s as? [[String: Any]] { found = list.first { ($0["syncedLyrics"] as? String) != nil } ?? list.first ?? NSNull() }
            else if s is NSNull { found = NSNull() }
            else { found = nil }   // error or rate limit: no answer, so nothing to cache
        }
        guard let j = found else { return nil }   // network error or rate limit: don't cache, just fall back
        guard let d = j as? [String: Any], let plain = (d["plainLyrics"] as? String) ?? (d["syncedLyrics"] as? String).map(strip), !plain.isEmpty else {
            try? Data().write(to: file)
            return nil
        }
        let l = Lyrics(plain: plain, synced: d["syncedLyrics"] as? String ?? "")
        try? JSONEncoder().encode(l).write(to: file)
        return l
    }

    static func strip(_ lrc: String) -> String {
        lrc.split(separator: "\n").map { $0.replacingOccurrences(of: #"^\[[\d:.]+\]\s?"#, with: "", options: .regularExpression) }.joined(separator: "\n")
    }

    /// The lines around `t` seconds, the current one marked with ▶.
    static func around(_ lrc: String, at t: Double) -> String {
        let lines: [(Double, String)] = lrc.split(separator: "\n").compactMap { l in
            guard let m = l.range(of: #"^\[(\d+):(\d+(?:\.\d+)?)\]"#, options: .regularExpression) else { return nil }
            let stamp = l[m].dropFirst().dropLast().split(separator: ":")
            guard stamp.count == 2, let mm = Double(stamp[0]), let ss = Double(stamp[1]) else { return nil }
            return (mm * 60 + ss, String(l[m.upperBound...]).trimmingCharacters(in: .whitespaces))
        }
        guard let i = lines.lastIndex(where: { $0.0 <= t }) else { return strip(lrc) }
        return lines[max(0, i - 3)...min(lines.count - 1, i + 4)].enumerated().map { k, l in
            (max(0, i - 3) + k == i ? "▶ " : "  ") + l.1
        }.joined(separator: "\n")
    }
}

// MARK: - Now playing (Music, Spotify)

enum NowPlaying {
    struct Track { var title, artist, album: String; var duration, position: Double; var app: String
        var line: String { "\(title) by \(artist)\(album.isEmpty ? "" : " · album \(album)") · \(Music.mmss(position)) of \(Music.mmss(duration)) in \(app)" }
    }
    private static let queue = DispatchQueue(label: "nowplaying")

    /// Only asks apps that are already running, so it never launches one.
    static func read() async -> Track? {
        for (bundle, name, durationScale) in [("com.apple.Music", "Music", 1.0), ("com.spotify.client", "Spotify", 0.001)] {
            guard !NSRunningApplication.runningApplications(withBundleIdentifier: bundle).isEmpty else { continue }
            let src = """
            tell application "\(name)"
              if player state is not playing then return ""
              set t to current track
              return (name of t) & tab & (artist of t) & tab & (album of t) & tab & (duration of t) & tab & player position
            end tell
            """
            let out: String = await withCheckedContinuation { c in
                queue.async {
                    var err: NSDictionary?
                    c.resume(returning: NSAppleScript(source: src)?.executeAndReturnError(&err).stringValue ?? "")
                }
            }
            let f = out.components(separatedBy: "\t")
            guard f.count == 5 else { continue }
            let num = { (s: String) in Double(s.replacingOccurrences(of: ",", with: ".")) ?? 0 }
            return Track(title: f[0], artist: f[1], album: f[2], duration: num(f[3]) * durationScale, position: num(f[4]), app: name)
        }
        return nil
    }
}
