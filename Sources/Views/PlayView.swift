import SwiftUI
import Combine

/// 播放页：
///   - 左侧：源选择（账号歌单 / 我喜欢的 / 本地音乐 / 搜索结果 / 最近播放）
///   - 中间：曲目列表
///   - 顶部：搜索框（在线搜或本地过滤）
///   - 底部：底部控制条 + 歌词面板（可折叠）
struct PlayView: View {
    @EnvironmentObject private var appState: AppState
    @State private var source: PlaySource = .liked
    @State private var searchText: String = ""
    @State private var searchResults: [Song] = []
    @State private var displayedSongs: [Song] = []
    @State private var isSearching: Bool = false
    @State private var localError: String?
    @State private var loadingLiked: Bool = false
    @State private var showLyrics: Bool = false
    @State private var searchTask: Task<Void, Never>?

    enum PlaySource: String, CaseIterable, Identifiable {
        case liked, online, local, search, recent
        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .liked:  return "我喜欢的"
            case .online: return "在线歌单"
            case .local:  return "本地音乐"
            case .search: return "搜索结果"
            case .recent: return "最近播放"
            }
        }
        var systemImage: String {
            switch self {
            case .liked:  return "heart.fill"
            case .online: return "music.note.list"
            case .local:  return "folder"
            case .search: return "magnifyingglass"
            case .recent: return "clock.arrow.circlepath"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            Divider()
            HStack(spacing: 0) {
                sourceList
                    .frame(width: 240)
                Divider()
                Group {
                        if showLyrics {
                            lyricsPanel.frame(maxWidth: .infinity)
                        } else {
                            songList.frame(maxWidth: .infinity)
                        }
                    }
            }
            Divider()
            ControlBar(showLyrics: $showLyrics)
        }
        .alert("出错了", isPresented: errorBinding) {
            Button("好") { localError = nil }
        } message: {
            Text(localError ?? "")
        }
        .onAppear { reloadDisplayedSongs() }
        .onChange(of: source) { _ in reloadDisplayedSongs() }
        .onChange(of: appState.library.accountPlaylists) { _ in
            if source == .online { reloadDisplayedSongs() }
        }
        .onChange(of: appState.localMusic.tracks) { _ in
            if source == .local { reloadDisplayedSongs() }
        }
    }

    // MARK: - Sections

    private var searchBar: some View {
        HStack {
            Picker("", selection: $source) {
                ForEach(PlaySource.allCases) { s in
                    Label(s.displayName, systemImage: s.systemImage).tag(s)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 480)
            Spacer()
            TextField(source == .local ? "过滤本地列表…" : "搜索在线歌曲…", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 360)
                .onSubmit {
                        if source != .local {
                            Task { await runSearch() }
                        } else {
                            reloadDisplayedSongs()
                        }
                    }
        }
        .padding(10)
    }

    private var sourceList: some View {
        List {
            switch source {
            case .liked:
                if loadingLiked {
                    ProgressView().padding(.vertical, 4)
                } else if let liked = appState.library.likedPlaylist {
                    Button {
                        Task { await loadLikedSongs() }
                    } label: {
                        Label(liked.name, systemImage: "heart.fill")
                    }
                } else {
                    Text("登录后查看「我喜欢的」")
                        .foregroundStyle(.secondary)
                }
            case .online:
                if appState.library.accountPlaylists.isEmpty {
                    Text("登录后查看账号歌单")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(appState.library.accountPlaylists) { p in
                        Button {
                            Task { await loadPlaylist(p.id) }
                        } label: {
                            Label("\(p.name)（\(p.trackCount)）", systemImage: "music.note.list")
                                .lineLimit(1)
                        }
                    }
                }
            case .local:
                Text("共 \(appState.localMusic.tracks.count) 首本地曲目")
                    .font(.caption).foregroundStyle(.secondary)
            case .search:
                Text(isSearching ? "搜索中…" : "\(searchResults.count) 条结果")
                    .font(.caption).foregroundStyle(.secondary)
            case .recent:
                Text("暂未实现")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var songList: some View {
        if displayedSongs.isEmpty {
            VStack(spacing: 12) {
                Spacer()
                Image(systemName: "music.note.list")
                    .font(.system(size: 48))
                    .foregroundStyle(.secondary)
                Text(source == .local ? "未添加音乐文件夹或无匹配曲目" : "暂无曲目")
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else {
            List(displayedSongs) { song in
                SongRow(song: song, trailing: .both)
                    .environmentObject(appState)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        appState.player.playOrEnqueue(song)
                    }
            }
        }
    }

    private var lyricsPanel: some View {
        VStack(spacing: 0) {
            if let lyrics = appState.lyrics.current {
                let lines = lyrics.lines
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(Array(lines.enumerated()), id: \.offset) { idx, line in
                                Text(line.text)
                                    .font(.system(size: lineFontSize(at: idx), design: .rounded))
                                    .foregroundStyle(lineColor(at: idx))
                                    .id(idx)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                if let tr = line.translation, !tr.isEmpty {
                                    Text(tr)
                                        .font(.system(size: lineFontSize(at: idx) - 2, design: .rounded))
                                        .foregroundStyle(lineColor(at: idx).opacity(0.7))
                                        .id("t-\(idx)")
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                            Spacer(minLength: 60)
                        }
                        .padding(20)
                    }
                    onChange(of: appState.player.currentTime) { newValue in
                                            let idx = appState.lyrics.currentLineIndex(at: newValue)
                        if idx >= 0 {
                            withAnimation(.easeInOut(duration: 0.3)) {
                                proxy.scrollTo(idx, anchor: .center)
                            }
                        }
                    }
                }
            } else {
                VStack(spacing: 10) {
                    Spacer()
                    Image(systemName: "text.alignleft")
                        .font(.system(size: 36))
                        .foregroundStyle(.secondary)
                    Text(appState.lyrics.isLoading ? "加载歌词…" : "无歌词")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    // MARK: - Actions

    private func reloadDisplayedSongs() {
        switch source {
        case .liked:
            if appState.library.likedPlaylist == nil, appState.auth.isLoggedIn {
                Task { await loadLikedSongs() }
            } else {
                displayedSongs = appState.library.likedPlaylist?.tracks ?? []
            }
        case .online:
            // 默认选中第一个账号歌单
            displayedSongs = []
        case .local:
            let filter = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let raw = appState.localMusic.tracks.map { LocalTrackAsSong($0) }
            if filter.isEmpty {
                displayedSongs = raw
            } else {
                displayedSongs = raw.filter {
                    $0.name.lowercased().contains(filter) ||
                    $0.artists.first?.name.lowercased().contains(filter) == true
                }
            }
        case .search:
            displayedSongs = searchResults
        case .recent:
            displayedSongs = []
        }

        // 启动恢复：把当前 source 的候选歌单喂给 player.tryRestoreQueue
        // 让 player 用 id 匹配 pending 队列。内部用 clearPendingResume 保证只生效一次。
        if !displayedSongs.isEmpty {
            appState.player.tryRestoreQueue(from: displayedSongs)
        }
    }

    private func runSearch() async {
        let keyword = searchText.trimmingCharacters(in: .whitespaces)
        guard !keyword.isEmpty else {
            searchResults = []
            reloadDisplayedSongs()
            return
        }
        isSearching = true
        defer { isSearching = false }
        do {
            let results = try await appState.api.searchSongs(keyword: keyword, limit: 50)
            searchResults = results
            reloadDisplayedSongs()
        } catch {
            localError = error.localizedDescription
        }
    }

    private func loadLikedSongs() async {
        loadingLiked = true
        defer { loadingLiked = false }
        do {
            guard let liked = appState.library.likedPlaylist else {
                displayedSongs = []
                return
            }
            let detail = try await appState.library.loadPlaylistTracks(id: liked.id)
            displayedSongs = detail?.tracks ?? liked.tracks
        } catch {
            localError = error.localizedDescription
        }
    }

    private func loadPlaylist(_ id: Int64) async {
        do {
            if let playlist = try await appState.library.loadPlaylistTracks(id: id) {
                displayedSongs = playlist.tracks
            }
        } catch {
            localError = error.localizedDescription
        }
    }

    private func lineColor(at idx: Int) -> Color {
        let cur = appState.lyrics.currentLineIndex(at: appState.player.currentTime)
        if idx == cur { return .primary }
        if idx < cur { return .secondary.opacity(0.6) }
        return .secondary.opacity(0.4)
    }

    private func lineFontSize(at idx: Int) -> CGFloat {
        let cur = appState.lyrics.currentLineIndex(at: appState.player.currentTime)
        if idx == cur { return 22 }
        return 16
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { localError != nil },
            set: { newValue in if !newValue { localError = nil } }
        )
    }

    private func LocalTrackAsSong(_ t: LocalTrack) -> Song {
        Song(
            id: Int64(t.url.absoluteString.hashValue),
            name: t.title.isEmpty ? t.url.deletingPathExtension().lastPathComponent : t.title,
            artists: [Artist(id: 0, name: t.artist)],
            album: Album(id: 0, name: t.album, coverURL: nil),
            duration: Int(t.duration),
            coverURL: nil,
            source: .local
        )
    }
}

/// 底部控制条：封面 / 进度条 / 播放控制 / 模式 / 收藏 / 音量。
struct ControlBar: View {
    @EnvironmentObject private var appState: AppState
    @Binding var showLyrics: Bool

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                AsyncImage(url: appState.player.currentSong?.coverURL) { phase in
                    switch phase {
                    case .success(let img):
                        img.resizable().aspectRatio(contentMode: .fill)
                    default:
                        ZStack {
                            Color.secondary.opacity(0.15)
                            Image(systemName: "music.note")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(width: 48, height: 48)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                VStack(alignment: .leading, spacing: 2) {
                    Text(appState.player.currentSong?.name ?? "未在播放")
                        .font(.subheadline)
                        .lineLimit(1)
                    Text(appState.player.currentSong?.displayArtists ?? "")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(minWidth: 140, maxWidth: 240, alignment: .leading)
                Spacer()
                Button {
                    appState.player.togglePlayPause()
                } label: {
                    Image(systemName: appState.player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 32))
                }
                .buttonStyle(.borderless)
                .keyboardShortcut(.space, modifiers: [])
                Button { appState.player.previous() } label: {
                    Image(systemName: "backward.fill")
                }
                .buttonStyle(.borderless)
                .disabled(!appState.player.hasPrevious)
                Button { appState.player.next() } label: {
                    Image(systemName: "forward.fill")
                }
                .buttonStyle(.borderless)
                .disabled(!appState.player.hasNext)
                Button {
                    appState.player.setMode(cycleNext(appState.player.mode))
                } label: {
                    Image(systemName: appState.player.mode.systemImage)
                }
                .buttonStyle(.borderless)
                .help(appState.player.mode.displayName)
                Button {
                    showLyrics.toggle()
                } label: {
                    Image(systemName: showLyrics ? "text.bubble.fill" : "text.bubble")
                }
                .buttonStyle(.borderless)
                HStack {
                    Image(systemName: "speaker.fill")
                        .foregroundStyle(.secondary)
                    Slider(value: Binding(
                        get: { appState.player.volume },
                        set: { appState.player.setVolume($0) }
                    ), in: 0...1)
                    .frame(width: 120)
                    Image(systemName: "speaker.wave.3.fill")
                        .foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 8) {
                Text(format(appState.player.currentTime))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Slider(value: Binding(
                    get: { appState.player.currentTime },
                    set: { appState.player.seek(to: $0) }
                ), in: 0...max(appState.player.duration, 1))
                Text(format(appState.player.duration))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
        .padding(8)
    }

    private func cycleNext(_ m: PlayMode) -> PlayMode {
        let all = PlayMode.allCases
        let i = all.firstIndex(of: m) ?? 0
        return all[(i + 1) % all.count]
    }

    private func format(_ t: TimeInterval) -> String {
        guard t.isFinite, t >= 0 else { return "0:00" }
        let m = Int(t) / 60
        let s = Int(t) % 60
        return String(format: "%d:%02d", m, s)
    }
}