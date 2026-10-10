import Foundation

/// 播放模式。
enum PlayMode: String, CaseIterable, Codable, Identifiable {
    case listLoop, singleLoop, shuffle

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .listLoop:   return "列表循环"
        case .singleLoop: return "单曲循环"
        case .shuffle:    return "随机播放"
        }
    }

    var systemImage: String {
        switch self {
        case .listLoop:   return "repeat"
        case .singleLoop: return "repeat.1"
        case .shuffle:    return "shuffle"
        }
    }
}

/// 本地音乐扫描得到的曲目。
struct LocalTrack: Identifiable, Hashable {
    let id: UUID
    let url: URL
    let title: String
    let artist: String
    let album: String
    let duration: TimeInterval
    let coverData: Data?

    init(url: URL, title: String, artist: String, album: String, duration: TimeInterval, coverData: Data? = nil) {
        self.id = UUID()
        self.url = url
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
        self.coverData = coverData
    }
}

/// GitHub Release 信息（用于自动更新检查）。
struct ReleaseInfo: Codable, Hashable {
    let tagName: String
    /// GitHub Release 的 name 字段可能为 null（特别是用 API 自动化发版时），
    /// 解析必须容忍；用 tagName 作为显示 fallback。
    let name: String?
    /// Release body 也可能为空（draft release），保持 optional 更稳。
    let body: String?
    let htmlURL: URL
    let publishedAt: Date
    let assets: [ReleaseAsset]
    let isPrerelease: Bool

    // GitHub API 字段是 snake_case，但 Swift 这边习惯 camelCase + 缩写大写（URL）
    // + is 前缀——convertFromSnakeCase 处理不了这两点（`html_url` 会变 `htmlUrl`
    // 而我们要 `htmlURL`；`prerelease` 不变而我们要 `isPrerelease`）。手动声明。
    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name
        case body
        case htmlURL = "html_url"
        case publishedAt = "published_at"
        case assets
        case isPrerelease = "prerelease"
    }
}

struct ReleaseAsset: Codable, Hashable {
    let name: String
    let browserDownloadURL: URL
    let size: Int64

    enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadURL = "browser_download_url"
        case size
    }
}
