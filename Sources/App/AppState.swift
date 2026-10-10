import SwiftUI
import Combine

/// 全局应用状态。聚合所有服务，方便视图用 @EnvironmentObject 拿到。
///
/// ``settings`` 是 ``var``（不是 ``let``），因为 SwiftUI binding ``$appState.settings.foo``
/// 需要可写引用。这里的 ``SettingsStore`` 本身是不可变性的（构造时从磁盘恢复默认值，之后绑定
/// 监听 @Published 字段），所以 ``var`` 引用没问题。
@MainActor
final class AppState: ObservableObject {
    var settings: SettingsStore
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
        let library = LibraryStore(api: api, auth: auth)
        let lyrics = LyricsService(api: api, settings: settings)
        let localMusic = LocalMusicService(settings: settings)
        let downloader = DownloadManager(api: api, library: library, settings: settings)
        let player = PlayerService(library: library, settings: settings, api: api, lyricsService: lyrics)
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
        // 更新通道变化同步到 updater
        settings.$updateChannel
            .receive(on: RunLoop.main)
            .sink { [weak updater] channel in
                updater?.channel = channel
            }
            .store(in: &cancellables)
        // 转发 settings 内部字段变化到 appState 的 objectWillChange，
        // 否则 SwiftUI 视图（如 SettingsView 的 Picker / Stepper）只读到
        // settings 启动时的快照，写入成功但不重渲染。
        settings.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
        // 同样转发 updater：SettingsView 用的是 appState.updater（updater 在 AppState
        // 里是 let，子 ObservableObject 不会被视图自动订阅；不转发则点"立即检查"
        // 后 isChecking/lastError/latest 都不刷新，UI 没反应）。
        updater.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
        // 同样转发 player：SettingsView 的"默认播放模式" Picker 读 appState.player.mode，
        // 不转发则 Picker 显示旧值。
        player.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
        // 启动后若开启自动更新，5s 后静默检查一次
        if settings.autoCheckUpdates {
            Task { [weak updater] in
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                updater?.check(silent: true)
            }
        }
    }

    private var cancellables = Set<AnyCancellable>()

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
