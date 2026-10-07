import SwiftUI
import Combine

/// 全局应用状态。聚合所有服务，方便视图用 @EnvironmentObject 拿到。
@MainActor
final class AppState: ObservableObject {
    let settings: SettingsStore
    let api: NeteaseAPI
    let auth: AuthService
    let library: LibraryStore
    let downloader: DownloadManager
    let player: PlayerService
    let lyrics: LyricsService
    let localMusic: LocalMusicService
    let updater: UpdateService

    @Published var selectedTab: AppTab = .download
    @Published var currentPlaylist: Playlist?
    @Published var errorMessage: String?

    init() {
        let settings = SettingsStore()
        let deviceId = AppState.persistedOrFreshDeviceId()
        let api = NeteaseAPI(deviceId: deviceId)
        let auth = AuthService(api: api)
        let library = LibraryStore()
        let downloader = DownloadManager(api: api, library: library, settings: settings)
        let player = PlayerService(library: library, settings: settings)
        let lyrics = LyricsService(api: api, settings: settings)
        let localMusic = LocalMusicService(settings: settings)
        let updater = UpdateService()

        self.settings = settings
        self.api = api
        self.auth = auth
        self.library = library
        self.downloader = downloader
        self.player = player
        self.lyrics = lyrics
        self.localMusic = localMusic
        self.updater = updater

        // 把 auth 拿到的 cookie 注入 api；其他服务按需订阅。
        auth.onCookieChanged = { [weak api] cookie in
            api?.setCookie(cookie)
        }
        auth.onAccountChanged = { [weak library, weak downloader] _ in
            library?.refreshAccountPlaylists()
            downloader?.refreshQualityAvailability()
        }
    }

    /// 全局唯一的设备 ID。每个 macOS 用户保持稳定；首次启动时随机生成。
    private static func persistedOrFreshDeviceId() -> String {
        let key = "ncm.deviceId"
        if let existing = UserDefaults.standard.string(forKey: key) {
            return existing
        }
        let bytes = (0..<16).map { _ in UInt8.random(in: 0...255) }
        let fresh = bytes.map { String(format: "%02x", $0) }.joined()
        UserDefaults.standard.set(fresh, forKey: key)
        return fresh
    }

    func presentError(_ message: String) {
        errorMessage = message
    }
}

enum AppTab: String, CaseIterable, Identifiable {
    case download, play, library, localMusic, settings

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .download: return "下载"
        case .play: return "播放"
        case .library: return "歌单"
        case .localMusic: return "本地"
        case .settings: return "设置"
        }
    }

    var systemImage: String {
        switch self {
        case .download: return "arrow.down.circle"
        case .play: return "play.circle"
        case .library: return "music.note.list"
        case .localMusic: return "folder"
        case .settings: return "gearshape"
        }
    }
}
