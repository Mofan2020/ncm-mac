import Foundation

/// 用户登录账号。
struct Account: Codable, Hashable {
    let userId: Int64
    let nickname: String
    let avatarURL: URL?
    let vipType: Int             // 0=普通, 1=VIP, 11=SVIP
}

/// 歌词行。
struct LyricLine: Hashable, Codable {
    let timeMs: Int
    let text: String
    /// 翻译（可空）。
    let translation: String?
}

/// 单首歌曲的歌词（含原文与翻译合并后的展示）。
struct SongLyrics: Hashable, Codable {
    let songId: Int64
    let lines: [LyricLine]
    let hasTranslation: Bool
}
