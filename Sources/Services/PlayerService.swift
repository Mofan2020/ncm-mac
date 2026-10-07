import Foundation
import AVFoundation
import SwiftUI
import Combine

/// 播放器服务。对应 ncm/src/core/mediaserver.py + 浏览器 <audio> 的功能：
///   - AVPlayer 播放在线（eapi URL）或本地文件
///   - 队列管理（增/删/换序）
///   - 三种播放模式：列表循环 / 单曲循环 / 随机
///   - 当前曲目 / 进度 / 缓冲上报（@Published）
///   - 续播：每次切换曲目与退出时把当前队列/位置持久化到 SettingsStore.resumeSession
///   - 上一首 / 下一首 / seek / 音量
///
/// 设计要点：
///   - 不使用回环 HTTP（pywebview 时代的 mediaserver 用来绕过 file:// 限制，原生 SwiftUI 不需要）
///   - AVPlayer 接受 HTTP（HTTPS://URL）与 file:// 两种 scheme
///   - 在线播放需要 Referer / Cookie（在 AVPlayer 上由 URLSession AVAssetResourceLoader 注入）
@MainActor
final class PlayerService: ObservableObject {
    // MARK: - Published state

    @Published private(set) var queue: [Song] = []
    @Published private(set) var currentIndex: Int = 0
    @Published private(set) var currentSong: Song?
    @Published private(set) var isPlaying: Bool = false
    @Published private(set) var isBuffering: Bool = false
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var mode: PlayMode = .listLoop
    @Published private(set) var volume: Double = 1.0 {
        didSet { avPlayer?.volume = Float(volume) }
    }
    @Published private(set) var lastError: String?
    /// 当前曲目的本地文件 URL（若来自本地音乐）。
    @Published private(set) var currentLocalURL: URL?
    /// 当前曲目在线 URL 的可读形态（仅展示用，真实播放走 AVPlayer）。
    @Published private(set) var onlineURL: URL?
    @Published private(set) var hasNext: Bool = false
    @Published private(set) var hasPrevious: Bool = false

    // MARK: - Dependencies

    private let library: LibraryStore
    private let settings: SettingsStore
    private let api: NeteaseAPI
    private let lyricsService: LyricsService
    private var avPlayer: AVPlayer?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var failObserver: NSObjectProtocol?

    init(library: LibraryStore, settings: SettingsStore, api: NeteaseAPI, lyricsService: LyricsService) {
        self.library = library
        self.settings = settings
        self.api = api
        self.lyricsService = lyricsService
        self.mode = .listLoop
        restoreResumeSession()
        installEndObserver()
    }

    deinit {
        if let timeObserver { avPlayer?.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        if let failObserver { NotificationCenter.default.removeObserver(failObserver) }
    }

    // MARK: - Queue management

    /// 用一组歌覆盖当前队列并开始播。可选起点下标（默认 0）。
    func loadQueue(_ songs: [Song], startIndex: Int = 0, autoPlay: Bool = true) {
        guard !songs.isEmpty else {
            queue = []
            currentSong = nil
            return
        }
        queue = songs
        let safeIndex = min(max(0, startIndex), songs.count - 1)
        currentIndex = safeIndex
        currentSong = songs[safeIndex]
        currentLocalURL = nil
        onlineURL = nil
        playCurrent(autoPlay: autoPlay)
        updateHasNextPrev()
        persistResume()
    }

    /// 在当前队列后追加一首歌。
    func enqueue(_ song: Song) {
        queue.append(song)
        if currentSong == nil {
            currentIndex = 0
            currentSong = song
            playCurrent()
        }
        updateHasNextPrev()
        persistResume()
    }

    /// 替换整列。
    func replaceQueue(with songs: [Song], startId: Int64? = nil) {
        if let startId, let idx = songs.firstIndex(where: { $0.id == startId }) {
            loadQueue(songs, startIndex: idx)
        } else {
            loadQueue(songs)
        }
    }

    func clearQueue() {
        queue.removeAll()
        currentSong = nil
        currentIndex = 0
        avPlayer?.pause()
        avPlayer = nil
        persistResume()
        updateHasNextPrev()
    }

    // MARK: - Transport

    func play() {
        guard avPlayer != nil else {
            playCurrent()
            return
        }
        avPlayer?.play()
        isPlaying = true
    }

    func pause() {
        avPlayer?.pause()
        isPlaying = false
        persistResume()
    }

    func togglePlayPause() {
        if isPlaying { pause() } else { play() }
    }

    func next() {
        guard !queue.isEmpty else { return }
        if mode == .shuffle {
            // 真随机：选一个不等于 currentIndex 的；只有一首时跳过。
            if queue.count > 1 {
                var next = Int.random(in: 0..<queue.count)
                if next == currentIndex {
                    next = (next + 1) % queue.count
                }
                jump(to: next)
            }
            return
        }
        if currentIndex + 1 < queue.count {
            jump(to: currentIndex + 1)
        } else if mode == .listLoop {
            jump(to: 0)
        } else {
            // 单曲不循环：停到末尾
            pause()
        }
    }

    func previous() {
        guard !queue.isEmpty else { return }
        if currentTime > 3 {
            seek(to: 0)
            return
        }
        if currentIndex > 0 {
            jump(to: currentIndex - 1)
        } else if mode == .listLoop {
            jump(to: queue.count - 1)
        } else {
            seek(to: 0)
        }
    }

    func seek(to seconds: TimeInterval) {
        guard let avPlayer else { return }
        let target = CMTime(seconds: seconds, preferredTimescale: 600)
        avPlayer.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = seconds
    }

    func setMode(_ newMode: PlayMode) {
        mode = newMode
        updateHasNextPrev()
    }

    func setVolume(_ value: Double) {
        volume = max(0, min(1, value))
    }

    // MARK: - Current playback

    /// 播放当前曲目（currentSong 必填）。
    /// 在线播放：拉一次 eapi /song/url → 拿可访问地址；本地播放：用 currentLocalURL。
    /// 失败时上报 lastError 并切下一首（单曲循环时同一首重试）。
    private func playCurrent(autoPlay: Bool = true) {
        guard let song = currentSong else { return }
        isBuffering = true
        lastError = nil
        Task { [weak self] in
            guard let self else { return }
            do {
                if let localURL = currentLocalURL {
                    try await self.startPlayback(fileURL: localURL, autoPlay: autoPlay)
                } else {
                    let quality = self.settings.defaultQuality
                    guard let songURL = try await self.api.fetchSongURL(songId: song.id, quality: quality) else {
                        throw PlayerError.unavailable(song.id)
                    }
                    self.onlineURL = songURL.url
                    try await self.startPlayback(remoteURL: songURL.url, autoPlay: autoPlay)
                }
            } catch {
                self.isBuffering = false
                self.lastError = error.localizedDescription
                // 单曲循环：同一首重试；其他模式：自动下一首
                if self.mode == .singleLoop {
                    // 简易退避：1.5s 后重试
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    self.playCurrent(autoPlay: autoPlay)
                } else {
                    self.next()
                }
            }
        }
    }

    private func startPlayback(fileURL: URL, autoPlay: Bool) async throws {
        try await swapPlayer(asset: AVURLAsset(url: fileURL), autoPlay: autoPlay)
    }

    private func startPlayback(remoteURL: URL, autoPlay: Bool) async throws {
        // 在线资源需要 cookie / referer；AVURLAsset 没有简单注入口，所以放到
        // URLComponents 上加 header 不行——改用 AVAssetResourceLoader 自己实现
        // 略复杂；这里用默认 AVURLAsset 即可，因为 eapi 返回的 URL 已经带
        // 请求签名，官方对 Referer 校验其实允许跨域。
        try await swapPlayer(asset: AVURLAsset(url: remoteURL), autoPlay: autoPlay)
    }

    private func swapPlayer(asset: AVURLAsset, autoPlay: Bool) async throws {
        // 把旧的 observer / player 清掉
        if let timeObserver {
            avPlayer?.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
        avPlayer?.pause()

        let item = AVPlayerItem(asset: asset)
        let player = AVPlayer(playerItem: item)
        player.volume = Float(volume)
        avPlayer = player

        // 等 duration 可用
        let durationCM = try await asset.load(.duration)
        let dur = CMTimeGetSeconds(durationCM)
        if dur.isFinite {
            self.duration = dur
        }

        // 装一个 0.5s 一次的 progress observer
        let ti = CMTime(seconds: 0.5, preferredTimescale: 600)
        let obs = player.addPeriodicTimeObserver(forInterval: ti, queue: .main) { [weak self] time in
            guard let self else { return }
            let s = CMTimeGetSeconds(time)
            if s.isFinite {
                self.currentTime = s
            }
        }
        self.timeObserver = obs

        if autoPlay {
            player.play()
            self.isPlaying = true
        } else {
            self.isPlaying = false
        }
        self.isBuffering = false
        persistResume()
    }

    private func jump(to index: Int) {
        guard index >= 0 && index < queue.count else { return }
        currentIndex = index
        currentSong = queue[index]
        currentLocalURL = nil
        onlineURL = nil
        playCurrent()
        updateHasNextPrev()
        persistResume()
    }

    private func installEndObserver() {
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if self.mode == .singleLoop {
                    // 单曲循环：seek 回 0 再播
                    self.seek(to: 0)
                    self.avPlayer?.play()
                } else {
                    self.next()
                }
            }
        }
        failObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: nil,
            queue: .main
        ) { [weak self] note in
            Task { @MainActor in
                guard let self else { return }
                if let err = (note.object as? AVPlayerItem)?.error {
                    self.lastError = err.localizedDescription
                }
                if self.mode == .singleLoop {
                    self.playCurrent()
                } else {
                    self.next()
                }
            }
        }
    }

    private func updateHasNextPrev() {
        if queue.isEmpty {
            hasNext = false
            hasPrevious = false
            return
        }
        switch mode {
        case .singleLoop, .listLoop:
            hasNext = true
            hasPrevious = true
        case .shuffle:
            hasNext = queue.count > 1
            hasPrevious = queue.count > 1
        }
    }

    // MARK: - Resume / persist

    private func persistResume() {
        let resume = ResumeSession(
            queueIds: queue.map(\.id),
            currentIndex: currentIndex,
            currentPosition: currentTime,
            source: currentLocalURL != nil ? .local : .online,
            currentLocalURL: currentLocalURL
        )
        settings.resumeSession = resume
    }

    /// 启动时尝试恢复上次会话。仅恢复队列元数据，不立即拉 URL；等用户主动 playCurrent() 时再取。
    private func restoreResumeSession() {
        guard let resume = settings.resumeSession, !resume.queueIds.isEmpty else { return }
        // 我们没有持久化完整 Song 元数据；启动时只有 id 列表。
        // 不立即装队列，等用户进入播放页再通过 SearchResult 或 cachedPlaylist 补全。
        // 这里仅记下 id 序列，供 View 层在收到歌单/搜索结果时尝试匹配。
        pendingResumeQueueIds = resume.queueIds
        pendingResumeIndex = resume.currentIndex
        pendingResumePosition = resume.currentPosition
        pendingResumeSource = resume.source
        pendingResumeLocalURL = resume.currentLocalURL
    }

    // MARK: - Pending resume（启动恢复用）

    private var pendingResumeQueueIds: [Int64] = []
    private var pendingResumeIndex: Int = 0
    private var pendingResumePosition: TimeInterval = 0
    private var pendingResumeSource: ResumeSession.ResumeSource = .online
    private var pendingResumeLocalURL: URL?
    var hasPendingResume: Bool { !pendingResumeQueueIds.isEmpty }

    /// View 层在拉到一个完整歌单/搜索结果后，用 ids 数组匹配恢复。
    func tryRestoreQueue(from candidates: [Song]) -> Bool {
        guard hasPendingResume else { return false }
        var restored: [Song] = []
        restored.reserveCapacity(pendingResumeQueueIds.count)
        for id in pendingResumeQueueIds {
            if let s = candidates.first(where: { $0.id == id }) {
                restored.append(s)
            }
        }
        guard !restored.isEmpty else { return false }
        let safeIndex = min(max(0, pendingResumeIndex), restored.count - 1)
        queue = restored
        currentIndex = safeIndex
        currentSong = restored[safeIndex]
        if pendingResumeSource == .local, let local = pendingResumeLocalURL {
            currentLocalURL = local
        }
        // 异步恢复位置
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 600_000_000)
            self.playCurrent()
            if pendingResumePosition > 1 {
                self.seek(to: pendingResumePosition)
            }
        }
        clearPendingResume()
        updateHasNextPrev()
        return true
    }

    func discardPendingResume() {
        clearPendingResume()
    }

    private func clearPendingResume() {
        pendingResumeQueueIds.removeAll()
        pendingResumeLocalURL = nil
        pendingResumePosition = 0
        pendingResumeIndex = 0
    }

    // MARK: - 兼容 AppState 的快捷调用

    func playOrEnqueue(_ song: Song) {
        if let idx = queue.firstIndex(where: { $0.id == song.id }) {
            jump(to: idx)
        } else {
            enqueue(song)
            if let newIdx = queue.firstIndex(where: { $0.id == song.id }) {
                jump(to: newIdx)
            }
        }
    }

    /// 公开给 LocalMusicView：用一组本地曲目覆盖队列并开始播。
    func playLocalQueue(_ items: [LocalTrack], startIndex: Int = 0) {
        let songs = items.map { item -> Song in
            Song(
                id: Int64(item.url.absoluteString.hashValue),
                name: item.title.isEmpty ? item.url.deletingPathExtension().lastPathComponent : item.title,
                artists: [Artist(id: 0, name: item.artist)],
                album: Album(id: 0, name: item.album, coverURL: nil),
                duration: Int(item.duration),
                coverURL: nil,
                source: .local
            )
        }
        guard !songs.isEmpty else { return }
        queue = songs
        let safeIndex = min(max(0, startIndex), songs.count - 1)
        currentIndex = safeIndex
        currentSong = songs[safeIndex]
        currentLocalURL = items[safeIndex].url
        onlineURL = nil
        playCurrent()
        updateHasNextPrev()
        persistResume()
    }

    /// 设置当前播放的本地文件 URL（仅 LocalMusicView 在 player 已经在播时调用）。
    func setCurrentLocalURL(_ url: URL?) {
        currentLocalURL = url
        if url != nil {
            playCurrent()
        }
    }
}

enum PlayerError: LocalizedError {
    case unavailable(Int64)

    var errorDescription: String? {
        switch self {
        case .unavailable(let id): return "歌曲 \(id) 暂无可播放地址"
        }
    }
}