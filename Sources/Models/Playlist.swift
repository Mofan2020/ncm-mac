import Foundation

/// 用户歌单（含"我喜欢的"）。
struct Playlist: Identifiable, Hashable, Codable {
    let id: Int64
    let name: String
    let creator: String
    let coverURL: URL?
    let trackCount: Int
    /// 完整曲目列表（懒加载：第一次拉取后缓存；切换时不重新拉）。
    var tracks: [Song]
    let isLiked: Bool           // 是否是"我喜欢的"（id 通常是用户 id）
    let isOwnedByMe: Bool       // 是否是当前登录用户自建

    /// 用户主动收藏的歌曲 ID 集合（用于侧栏「我喜欢的」快速判断）。
    var likedSongIDs: Set<Int64> {
        tracks.filter { $0.source == .liked }.map(\.id).reduce(into: Set<Int64>()) { $0.insert($1) }
    }
}
