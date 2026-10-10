import Foundation

/// 网易云音乐 eapi 客户端。
/// 对应 ncm/src/core/api.py 的完整 Swift 复刻。
///
/// 所有 eapi 请求的 payload 必须是 ``OrderedDict`` 以保留字段插入顺序——
/// 网易云服务端按 JSON 字符串做 md5 签名，字段顺序参与计算。
@MainActor
final class NeteaseAPI {
    // MARK: - Endpoints

    static let searchEndpoint = "/api/cloudsearch/pc"
    static let userPlaylistEndpoint = "/api/user/playlist"
    static let likeEndpoint = "/api/song/like"
    static let likeListEndpoint = "/api/song/like/get"
    static let weblogEndpoint = "/api/feedback/weblog"

    static let albumEndpoint = "/api/v1/album"
    static let artistEndpoint = "/api/v1/artist"
    static let recommendPlaylistEndpoint = "/api/v1/discovery/recommend/resource"
    static let personalFMEndpoint = "/api/v1/radio/get"
    static let newSongsEndpoint = "/api/v1/discovery/new/songs"
    static let recommendMVEndpoint = "/api/mv/recommend"
    static let topListEndpoint = "/api/v3/playlist/detail"
    static let searchSuggestEndpoint = "/api/search/suggest"

    static let playlistCreate = "/api/playlist/create"
    static let playlistUpdate = "/api/playlist/update"
    static let playlistDelete = "/api/playlist/delete"
    static let playlistTracksAdd = "/api/playlist/tracks/add"
    static let playlistTracksDel = "/api/playlist/tracks/del"
    static let playlistSubscribe = "/api/playlist/subscribe"
    static let playlistCoverUpdate = "/api/playlist/cover/update"

    // MARK: - Hosts

    static let eapiHosts = [
        "https://interface.music.163.com",
        "https://interface3.music.163.com",
        "https://music.163.com",
    ]

    static let legacyHost = "https://music.163.com"

    /// 浏览器风格的 User-Agent：网易云部分 legacy 接口对 UA 有要求（"PC" 客户端身份能拿到 cookie）。
    static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
        + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.6 Safari/605.1.15"

    /// 官方 PC 客户端的身份 cookie（os/appver/channel），登录相关接口在无 cookie 时会拒绝。
    static let clientCookieHeader = "os=pc; appver=8.9.70; channel=netease"

    // MARK: - State

    private let deviceId: String
    private let session: URLSession
    private(set) var cookie: String?
    private var currentHostIndex = 0
    private var currentAccountId: Int64 = 0

    init(deviceId: String, session: URLSession = .shared) {
        self.deviceId = deviceId
        self.session = session
    }

    func setCookie(_ cookie: String?) {
        self.cookie = cookie
    }

    // MARK: - Eapi

    private var currentEapiHost: String { Self.eapiHosts[currentHostIndex] }

    private func rotateHost() {
        currentHostIndex = (currentHostIndex + 1) % Self.eapiHosts.count
    }

    @discardableResult
    func eapi(path: String, payload: OrderedDict) async throws -> Data {
        let body = try CryptoService.eapiBody(
            path: path,
            data: payload,
            deviceId: deviceId
        )
        var request = URLRequest(url: URL(string: "\(currentEapiHost)/eapi\(path)")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        request.setValue("https://music.163.com/", forHTTPHeaderField: "Referer")
        // 显式声明只接受 gzip/deflate；网易云默认会回 brotli，而 URLSession 默认不解 brotli，
        // 不限制就会拿到压缩字节流 → JSON 解析失败。
        request.setValue("gzip, deflate", forHTTPHeaderField: "Accept-Encoding")
        if let cookie {
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
        }
        let encoded = body
            .map { key, value in
                "\(key.urlEncoded)=\(value.urlEncoded)"
            }
            .joined(separator: "&")
        request.httpBody = Data(encoded.utf8)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }
        guard http.statusCode == 200 else {
            if http.statusCode >= 500, currentEapiHost != Self.eapiHosts.last {
                rotateHost()
                return try await eapi(path: path, payload: payload)
            }
            throw APIError.httpStatus(http.statusCode, data)
        }
        return data
    }

    private func parseResponse(_ data: Data) throws -> [String: Any] {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw APIError.invalidJSON
        }
        let code = json["code"] as? Int ?? -1
        guard code == 200 else {
            throw APIError.business(code: code, message: json["message"] as? String)
        }
        return json
    }

    // MARK: - Playlist

    func fetchPlaylistDetail(id: Int64) async throws -> Playlist {
        let data = try await eapi(
            path: "/api/v6/playlist/detail",
            payload: [("id", AnyValue.int(id))]
        )
        let json = try parseResponse(data)
        guard let playlist = json["playlist"] as? [String: Any] else {
            throw APIError.malformedResponse
        }
        let trackIds = (playlist["trackIds"] as? [[String: Any]])?
            .compactMap { $0["id"] as? Int64 } ?? []
        let creator = playlist["creator"] as? [String: Any]
        let creatorId = (creator?["userId"] as? Int64) ?? 0
        let isLiked = (playlist["specialType"] as? Int) == 5

        let tracks = try await fetchSongDetails(ids: trackIds)

        return Playlist(
            id: id,
            name: (playlist["name"] as? String) ?? "",
            creator: (creator?["nickname"] as? String) ?? "",
            coverURL: (playlist["coverImgUrl"] as? String).flatMap(URL.init(string:)),
            trackCount: trackIds.count,
            tracks: tracks,
            isLiked: isLiked,
            isOwnedByMe: creatorId == currentAccountId
        )
    }

    func fetchSongDetails(ids: [Int64]) async throws -> [Song] {
        guard !ids.isEmpty else { return [] }
        var result: [Song] = []
        for chunk in ids.chunked(into: 1000) {
            let c = chunk.map(String.init).joined(separator: ",")
            let data = try await eapi(
                path: "/api/v3/song/detail",
                payload: [("c", .string("[\(c)]"))]
            )
            let json = try parseResponse(data)
            guard let songs = json["songs"] as? [[String: Any]] else {
                throw APIError.malformedResponse
            }
            result.append(contentsOf: songs.map { Self.songFromDetail($0) })
        }
        return result
    }

    // MARK: - Song URL / Lyrics

    func fetchSongURL(songId: Int64, quality: AudioQuality) async throws -> SongURL? {
        let chain = quality.fallbackChain
        for q in chain {
            let payload: OrderedDict = [
                ("ids", .array([.int(songId)])),
                ("br", .int(Int64(Self.bitrate(for: q)))),
                ("encodeType", .string(q.encodeType)),
            ]
            let data = try await eapi(
                path: "/api/song/enhance/player/url/v1",
                payload: payload
            )
            let json = try parseResponse(data)
            guard let entries = json["data"] as? [[String: Any]],
                  let first = entries.first,
                  let urlString = first["url"] as? String,
                  let url = URL(string: urlString) else {
                continue
            }
            let size = (first["size"] as? Int64) ?? 0
            let md5 = first["md5"] as? String
            let actualQuality = (first["level"] as? String).flatMap(AudioQuality.init(rawValue:)) ?? q
            return SongURL(url: url, size: size, md5: md5, quality: actualQuality)
        }
        return nil
    }

    func fetchLyrics(songId: Int64) async throws -> SongLyrics {
        let data = try await eapi(
            path: "/api/song/lyric",
            payload: [("id", AnyValue.int(songId))]
        )
        let json = try parseResponse(data)
        let lrcString = (json["lrc"] as? [String: Any])?["lyric"] as? String ?? ""
        let tlyricString = (json["tlyric"] as? [String: Any])?["lyric"] as? String ?? ""
        let lines = Self.parseLRC(lrcString)
        let translations = Self.parseLRC(tlyricString)
        let merged: [LyricLine] = lines.map { line in
            let translation = translations.first(where: { $0.timeMs == line.timeMs })?.text
            return LyricLine(timeMs: line.timeMs, text: line.text, translation: translation)
        }
        return SongLyrics(
            songId: songId,
            lines: merged,
            hasTranslation: !tlyricString.isEmpty
        )
    }

    // MARK: - Search

    func searchSongs(keyword: String, limit: Int = 30, offset: Int = 0) async throws -> [Song] {
        let trimmed = keyword.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }
        let data = try await eapi(
            path: Self.searchEndpoint,
            payload: [
                ("s", .string(trimmed)),
                ("type", .int(Int64(1))),
                ("limit", .int(Int64(limit))),
                ("offset", .int(Int64(offset))),
            ]
        )
        let json = try parseResponse(data)
        guard let result = json["result"] as? [String: Any],
              let songs = result["songs"] as? [[String: Any]] else {
            return []
        }
        return songs.map { Self.songFromDetail($0, source: .search) }
    }

    func searchSuggest(keyword: String) async throws -> [String] {
        guard !keyword.isEmpty else { return [] }
        let data = try await eapi(
            path: Self.searchSuggestEndpoint,
            payload: [("s", .string(keyword)), ("type", .string("mobile"))]
        )
        let json = try parseResponse(data)
        guard let result = json["result"] as? [String: Any],
              let allMatch = result["allMatch"] as? [[String: Any]] else {
            return []
        }
        return allMatch.compactMap { $0["keyword"] as? String }
    }

    // MARK: - User

    func fetchUserPlaylists(userId: Int64) async throws -> [Playlist] {
        var all: [Playlist] = []
        var offset = 0
        let limit = 100
        while true {
            let data = try await eapi(
                path: Self.userPlaylistEndpoint,
                payload: [
                    ("uid", .int(userId)),
                    ("limit", .int(Int64(limit))),
                    ("offset", .int(Int64(offset))),
                ]
            )
            let json = try parseResponse(data)
            guard let playlists = json["playlist"] as? [[String: Any]] else {
                break
            }
            if playlists.isEmpty { break }
            all.append(contentsOf: playlists.map { Self.playlistFromDetail($0) })
            let more = json["more"] as? Bool ?? false
            if !more { break }
            offset += playlists.count
        }
        return all
    }

    func setLike(songId: Int64, like: Bool) async throws {
        let data = try await eapi(
            path: Self.likeEndpoint,
            payload: [
                ("alg", .string("itembased_alg")),
                ("trackId", .int(songId)),
                ("like", .bool(like)),
                ("time", .int(3)),
            ]
        )
        _ = try parseResponse(data)
    }

    func fetchLikedSongIds(userId: Int64) async throws -> Set<Int64> {
        let data = try await eapi(
            path: Self.likeListEndpoint,
            payload: [("uid", .int(userId))]
        )
        let json = try parseResponse(data)
        let ids = (json["ids"] as? [Int64]) ?? []
        return Set(ids)
    }

    // MARK: - Account

    func fetchAccount() async throws -> Account? {
        guard cookie != nil else { return nil }
        let data = try await eapi(
            path: "/api/w/nuser/account/get",
            payload: []
        )
        let json = try parseResponse(data)
        guard let profile = json["profile"] as? [String: Any] else {
            return nil
        }
        let userId = profile["userId"] as? Int64 ?? 0
        self.currentAccountId = userId
        return Account(
            userId: userId,
            nickname: profile["nickname"] as? String ?? "",
            avatarURL: (profile["avatarUrl"] as? String).flatMap(URL.init(string:)),
            vipType: profile["vipType"] as? Int ?? 0
        )
    }

    // MARK: - WeBlog

    func reportPlay(songId: Int64, action: String, duration: Int, source: String = "list") async throws {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let data = try await eapi(
            path: Self.weblogEndpoint,
            payload: [
                ("action", .string(action)),
                ("json", .ordered([
                    ("id", .int(songId)),
                    ("type", .string("song")),
                    ("time", .int(now)),
                    ("source", .string(source)),
                    ("duration", .int(Int64(duration))),
                ])),
            ]
        )
        _ = try parseResponse(data)
    }

    // MARK: - Legacy QR

    func qrKey() async throws -> String {
        // legacy 接口：GET + query string，不需要 eapi 加密。Python ncm 走的就是这条。
        var components = URLComponents(string: "\(Self.legacyHost)/api/login/qrcode/unikey")!
        components.queryItems = [
            URLQueryItem(name: "type", value: "1"),
            URLQueryItem(name: "timestamp", value: String(Int(Date().timeIntervalSince1970 * 1000))),
        ]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        request.setValue("gzip, deflate", forHTTPHeaderField: "Accept-Encoding")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(Self.clientCookieHeader, forHTTPHeaderField: "Cookie")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw APIError.httpStatus((response as? HTTPURLResponse)?.statusCode ?? -1, data)
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let unikey = json["unikey"] as? String else {
            throw APIError.malformedResponse
        }
        return unikey
    }

    func qrPoll(unikey: String) async throws -> (code: Int, cookie: String?) {
        // qrcode 状态轮询走 eapi 通道（POST /eapi/.../client/login），服务端返回的
        // code/cookie 字段可能嵌套在 data 下；Python ncm 的 _qr_code_of / _qr_cookie_of
        // 就是为了兼容这种嵌套结构。
        let payload: OrderedDict = [
            ("key", .string(unikey)),
            ("type", .int(1)),
        ]
        let data = try await eapi(path: "/api/login/qrcode/client/login", payload: payload)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw APIError.invalidJSON
        }
        // code / cookie 可能直接出现，也可能在 data.* 嵌套里。
        let nested = (json["data"] as? [String: Any]) ?? [:]
        let code: Int = {
            if let n = nested["code"] as? Int { return n }
            if let n = json["code"] as? Int { return n }
            return -1
        }()
        let cookie: String? = {
            if let s = nested["cookie"] as? String, !s.isEmpty { return s }
            if let s = json["cookie"] as? String, !s.isEmpty { return s }
            if let dict = nested["cookies"] as? [String: String], !dict.isEmpty {
                return dict.map { "\($0.key)=\($0.value)" }.joined(separator: "; ")
            }
            if let dict = json["cookies"] as? [String: String], !dict.isEmpty {
                return dict.map { "\($0.key)=\($0.value)" }.joined(separator: "; ")
            }
            return nil
        }()
        return (code, cookie)
    }

    // MARK: - Static helpers

    static func bitrate(for q: AudioQuality) -> Int {
        switch q {
        case .standard:  return 128_000
        case .higher:    return 192_000
        case .exhigh:    return 320_000
        case .lossless:  return 999_000
        case .hires:     return 1_920_000
        }
    }

    static func songFromDetail(_ raw: [String: Any], source: Song.Source = .playlist) -> Song {
        let artists = (raw["ar"] as? [[String: Any]])?.map {
            Artist(id: ($0["id"] as? Int64) ?? 0, name: ($0["name"] as? String) ?? "")
        } ?? []
        let albumRaw = raw["al"] as? [String: Any]
        let album = Album(
            id: (albumRaw?["id"] as? Int64) ?? 0,
            name: (albumRaw?["name"] as? String) ?? "",
            coverURL: (albumRaw?["picUrl"] as? String).flatMap(URL.init(string:))
        )
        let durationMs = (raw["dt"] as? Int) ?? 0
        return Song(
            id: (raw["id"] as? Int64) ?? 0,
            name: (raw["name"] as? String) ?? "",
            artists: artists,
            album: album,
            duration: durationMs / 1000,
            coverURL: album.coverURL,
            source: source
        )
    }

    static func playlistFromDetail(_ raw: [String: Any]) -> Playlist {
        let creator = raw["creator"] as? [String: Any]
        return Playlist(
            id: (raw["id"] as? Int64) ?? 0,
            name: (raw["name"] as? String) ?? "",
            creator: (creator?["nickname"] as? String) ?? "",
            coverURL: (raw["coverImgUrl"] as? String).flatMap(URL.init(string:)),
            trackCount: (raw["trackCount"] as? Int) ?? 0,
            tracks: [],
            isLiked: (raw["specialType"] as? Int) == 5,
            isOwnedByMe: false
        )
    }

    static func parseLRC(_ text: String) -> [LyricLine] {
        guard !text.isEmpty else { return [] }
        var lines: [LyricLine] = []
        let pattern = #"\[(\d{2}):(\d{2})\.(\d{2,3})\](.*)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return []
        }
        for raw in text.components(separatedBy: .newlines) {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            let nsLine = trimmed as NSString
            let matches = regex.matches(in: trimmed, range: NSRange(location: 0, length: nsLine.length))
            for match in matches where match.numberOfRanges == 5 {
                let min = Int(nsLine.substring(with: match.range(at: 1))) ?? 0
                let sec = Int(nsLine.substring(with: match.range(at: 2))) ?? 0
                let fracRange = match.range(at: 3)
                let frac = Int(nsLine.substring(with: fracRange)) ?? 0
                let ms: Int = fracRange.length == 3 ? frac : frac * 10
                let textRange = match.range(at: 4)
                let lineText = nsLine.substring(with: textRange).trimmingCharacters(in: .whitespaces)
                if lineText.isEmpty
                    || lineText.hasPrefix("作词")
                    || lineText.hasPrefix("作曲")
                    || lineText.hasPrefix("编曲") {
                    continue
                }
                let timeMs = min * 60_000 + sec * 1000 + ms
                lines.append(LyricLine(timeMs: timeMs, text: lineText, translation: nil))
            }
        }
        return lines.sorted { $0.timeMs < $1.timeMs }
    }
}

// MARK: - Supporting types

struct SongURL: Equatable {
    let url: URL
    let size: Int64
    let md5: String?
    let quality: AudioQuality
}

enum APIError: LocalizedError {
    case invalidResponse
    case invalidJSON
    case httpStatus(Int, Data)
    case malformedResponse
    case business(code: Int, message: String?)

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "无效的网络响应"
        case .invalidJSON: return "无法解析服务器响应"
        case .httpStatus(let code, _): return "HTTP \(code)"
        case .malformedResponse: return "服务器返回结构异常"
        case .business(let code, let msg): return "服务器错误 (\(code))\(msg.map { ": \($0)" } ?? "")"
        }
    }
}

// MARK: - Helpers

extension String {
    var urlEncoded: String {
        addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? self
    }
}

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}