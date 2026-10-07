import Foundation

/// 音质枚举。对应 ncm 里的 standard/higher/exexhigh/lossless/hires。
enum AudioQuality: String, CaseIterable, Codable, Identifiable {
    case standard, higher, exhigh, lossless, hires

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .standard:  return "标准"
        case .higher:    return "较高"
        case .exhigh:    return "极高"
        case .lossless:  return "无损"
        case .hires:     return "Hi-Res"
        }
    }

    /// 服务端要求的 encodeType（mp3 / flac）。
    var encodeType: String {
        switch self {
        case .standard, .higher, .exhigh: return "mp3"
        case .lossless, .hires:           return "flac"
        }
    }

    /// 网络降级顺序：hires → lossless → exhigh → higher → standard
    var fallbackChain: [AudioQuality] {
        switch self {
        case .hires:    return [.hires, .lossless, .exhigh, .higher, .standard]
        case .lossless: return [.lossless, .exhigh, .higher, .standard]
        case .exhigh:   return [.exhigh, .higher, .standard]
        case .higher:   return [.higher, .standard]
        case .standard: return [.standard]
        }
    }

    /// 文件扩展名。
    var fileExtension: String { encodeType }
}

/// 下载任务状态。
enum DownloadStatus: Equatable, Hashable {
    case queued
    case downloading(progress: Double, speed: Double)
    case finished(url: URL)
    case failed(message: String)
    case cancelled
    case paused(progress: Double)

    var displayName: String {
        switch self {
        case .queued: return "等待中"
        case .downloading: return "下载中"
        case .finished: return "已完成"
        case .failed: return "失败"
        case .cancelled: return "已取消"
        case .paused: return "已暂停"
        }
    }

    var isActive: Bool {
        switch self {
        case .downloading, .paused, .queued: return true
        default: return false
        }
    }
}

/// 下载任务。
struct DownloadTask: Identifiable, Hashable {
    let id: UUID
    let song: Song
    let quality: AudioQuality
    let url: URL                   // 目标保存路径
    let includeLyrics: Bool
    var status: DownloadStatus
    var bytesDownloaded: Int64
    var totalBytes: Int64

    init(song: Song, quality: AudioQuality, url: URL, includeLyrics: Bool = true) {
        self.id = UUID()
        self.song = song
        self.quality = quality
        self.url = url
        self.includeLyrics = includeLyrics
        self.status = .queued
        self.bytesDownloaded = 0
        self.totalBytes = 0
    }

    var progress: Double {
        guard totalBytes > 0 else { return 0 }
        return Double(bytesDownloaded) / Double(totalBytes)
    }
}
