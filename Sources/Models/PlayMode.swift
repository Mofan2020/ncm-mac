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
    let name: String
    let body: String
    let htmlURL: URL
    let publishedAt: Date
    let assets: [ReleaseAsset]
    let isPrerelease: Bool
}

struct ReleaseAsset: Codable, Hashable {
    let name: String
    let browserDownloadURL: URL
    let size: Int64
}
