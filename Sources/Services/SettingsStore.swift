import Foundation
import SwiftUI
import Combine

/// 应用设置持久化层。对应 ncm/src/config/settings.py。
///
/// 存储分三层：
///   - 业务配置（下载路径 / 默认音质 / 播放模式 / 主题 / 语言等）→ JSON 文件
///     ~/Library/Application Support/NeteaseMusicDownloader/settings.json
///   - 播放计数 / 续播状态 → JSON 文件
///     ~/Library/Application Support/NeteaseMusicDownloader/playback.json
///   - 敏感凭据（cookie / deviceId）→ Keychain
@MainActor
final class SettingsStore: ObservableObject {
    @Published var defaultDownloadDirectory: URL {
        didSet { persist(Business.self) }
    }
    @Published var defaultQuality: AudioQuality {
        didSet { persist(Business.self) }
    }
    @Published var concurrentDownloads: Int {
        didSet { persist(Business.self) }
    }
    @Published var overwriteExisting: Bool {
        didSet { persist(Business.self) }
    }
    @Published var downloadLyrics: Bool {
        didSet { persist(Business.self) }
    }
    @Published var language: AppLanguage {
        didSet { persist(Business.self) }
    }
    @Published var theme: AppTheme {
        didSet { persist(Business.self) }
    }
    @Published var liquidGlassEnabled: Bool {
        didSet { persist(Business.self) }
    }
    @Published var localMusicFolders: [URL] {
        didSet { persist(Business.self) }
    }
    @Published var preferredLocalPlay: Bool {
        didSet { persist(Business.self) }
    }
    @Published var reportPlayCountToCloud: Bool {
        didSet { persist(Business.self) }
    }
    @Published var autoCheckUpdates: Bool {
        didSet { persist(Business.self) }
    }
    @Published var updateChannel: UpdateChannel {
        didSet { persist(Business.self) }
    }

    /// 上次播放的会话（续播用）。单独存。
    @Published var resumeSession: ResumeSession? {
        didSet { persistPlayback() }
    }
    /// 播放计数：songId → count。仅本地，不上报（开关打开才上报）。
    @Published var playCounts: [Int64: Int] {
        didSet { persistPlayback() }
    }

    private let appSupport: URL
    private let businessURL: URL
    private let playbackURL: URL

    init() {
        let fm = FileManager.default
        let appSupport = (try? fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("NeteaseMusicDownloader", isDirectory: true)) ?? fm.temporaryDirectory.appendingPathComponent("NeteaseMusicDownloader")
        if !fm.fileExists(atPath: appSupport.path) {
            try? fm.createDirectory(at: appSupport, withIntermediateDirectories: true)
        }
        self.appSupport = appSupport
        self.businessURL = appSupport.appendingPathComponent("settings.json")
        self.playbackURL = appSupport.appendingPathComponent("playback.json")

        // 默认值（先用占位，应用启动后用 load() 覆盖）
        let downloads = (try? fm.url(for: .downloadsDirectory, in: .userDomainMask, appropriateFor: nil, create: false))
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Downloads")
        let downloadsWithFolder = downloads.appendingPathComponent("NeteaseMusic", isDirectory: true)
        let business = Self.loadBusiness(from: businessURL) ?? Business(
            defaultDownloadDirectoryPath: downloadsWithFolder.path,
            defaultQuality: .exhigh,
            concurrentDownloads: 2,
            overwriteExisting: false,
            downloadLyrics: true,
            language: .system,
            theme: .system,
            liquidGlassEnabled: true,
            localMusicFolderPaths: [],
            preferredLocalPlay: false,
            reportPlayCountToCloud: false,
            autoCheckUpdates: true,
            updateChannel: .latest
        )
        self.defaultDownloadDirectory = URL(fileURLWithPath: business.defaultDownloadDirectoryPath)
        self.defaultQuality = business.defaultQuality
        self.concurrentDownloads = business.concurrentDownloads
        self.overwriteExisting = business.overwriteExisting
        self.downloadLyrics = business.downloadLyrics
        self.language = business.language
        self.theme = business.theme
        self.liquidGlassEnabled = business.liquidGlassEnabled
        self.localMusicFolders = business.localMusicFolderPaths.map { URL(fileURLWithPath: $0) }
        self.preferredLocalPlay = business.preferredLocalPlay
        self.reportPlayCountToCloud = business.reportPlayCountToCloud
        self.autoCheckUpdates = business.autoCheckUpdates
        self.updateChannel = business.updateChannel

        let playback = Self.loadPlayback(from: playbackURL)
        self.resumeSession = playback?.resumeSession
        self.playCounts = playback?.playCounts ?? [:]

        // 确保下载目录存在
        try? fm.createDirectory(at: defaultDownloadDirectory, withIntermediateDirectories: true)
    }

    // MARK: - Persistence

    private struct Business: Codable {
        var defaultDownloadDirectoryPath: String
        var defaultQuality: AudioQuality
        var concurrentDownloads: Int
        var overwriteExisting: Bool
        var downloadLyrics: Bool
        var language: AppLanguage
        var theme: AppTheme
        var liquidGlassEnabled: Bool
        var localMusicFolderPaths: [String]
        var preferredLocalPlay: Bool
        var reportPlayCountToCloud: Bool
        var autoCheckUpdates: Bool
        var updateChannel: UpdateChannel
    }

    private struct Playback: Codable {
        var resumeSession: ResumeSession?
        var playCounts: [Int64: Int]
    }

    private func currentBusiness() -> Business {
        Business(
            defaultDownloadDirectoryPath: defaultDownloadDirectory.path,
            defaultQuality: defaultQuality,
            concurrentDownloads: concurrentDownloads,
            overwriteExisting: overwriteExisting,
            downloadLyrics: downloadLyrics,
            language: language,
            theme: theme,
            liquidGlassEnabled: liquidGlassEnabled,
            localMusicFolderPaths: localMusicFolders.map(\.path),
            preferredLocalPlay: preferredLocalPlay,
            reportPlayCountToCloud: reportPlayCountToCloud,
            autoCheckUpdates: autoCheckUpdates,
            updateChannel: updateChannel
        )
    }

    private func persist<T: Encodable>(_ type: T.Type) {
        do {
            let data = try JSONEncoder().encode(currentBusiness())
            try data.write(to: businessURL, options: .atomic)
        } catch {
            print("[SettingsStore] 业务设置持久化失败: \(error)")
        }
    }

    private func persistPlayback() {
        let payload = Playback(resumeSession: resumeSession, playCounts: playCounts)
        do {
            let data = try JSONEncoder().encode(payload)
            try data.write(to: playbackURL, options: .atomic)
        } catch {
            print("[SettingsStore] 播放状态持久化失败: \(error)")
        }
    }

    private static func loadBusiness(from url: URL) -> Business? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Business.self, from: data)
    }

    private static func loadPlayback(from url: URL) -> Playback? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Playback.self, from: data)
    }

    // MARK: - Convenience

    func clearPlayCounts() {
        playCounts.removeAll()
    }

    /// 把 +1 计数写本地；如开启云上报则异步发 weblog。
    func incrementPlayCount(songId: Int64) {
        playCounts[songId, default: 0] += 1
    }
}

enum AppLanguage: String, CaseIterable, Codable, Identifiable {
    case system, zhHans, en

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: return "跟随系统"
        case .zhHans: return "简体中文"
        case .en:     return "English"
        }
    }

    /// Apple 标准的 BCP-47 标识。
    var localeIdentifier: String? {
        switch self {
        case .system: return nil
        case .zhHans: return "zh-Hans"
        case .en:     return "en"
        }
    }
}

enum AppTheme: String, CaseIterable, Codable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: return "跟随系统"
        case .light:  return "浅色"
        case .dark:   return "深色"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light:  return .light
        case .dark:   return .dark
        }
    }
}

enum UpdateChannel: String, CaseIterable, Codable, Identifiable {
    case latest, prerelease

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .latest:     return "正式版"
        case .prerelease: return "预发布"
        }
    }
}

struct ResumeSession: Codable, Equatable {
    /// 队列里的歌曲 ID 列表（去重保留顺序）。
    var queueIds: [Int64]
    /// 当前曲目在队列里的索引。
    var currentIndex: Int
    /// 当前曲目的播放位置（秒）。
    var currentPosition: TimeInterval
    /// 队列来自哪里。
    var source: ResumeSource
    /// 当前曲目是否来自本地音乐。
    var currentLocalURL: URL?

    enum ResumeSource: String, Codable {
        case online, local, search
    }
}
