import Foundation

/// 单曲。对应网易云 song 对象的最小可用字段集。
struct Song: Identifiable, Hashable, Codable {
    let id: Int64
    let name: String
    let artists: [Artist]
    let album: Album
    let duration: Int          // 秒
    let coverURL: URL?
    /// 标记来自哪里：在线歌单 / 我喜欢的 / 本地 / 搜索结果 / FM ...
    let source: Source

    var displayArtists: String { artists.map(\.name).joined(separator: " / ") }
    var displayDuration: String {
        let m = duration / 60
        let s = duration % 60
        return String(format: "%d:%02d", m, s)
    }

    enum Source: String, Codable, Hashable {
        case playlist, liked, search, radio, local, recent
    }
}

struct Artist: Identifiable, Hashable, Codable {
    let id: Int64
    let name: String
}

struct Album: Identifiable, Hashable, Codable {
    let id: Int64
    let name: String
    let coverURL: URL?
}
