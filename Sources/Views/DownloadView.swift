import SwiftUI
import Combine

/// 下载页：
///   - 顶部：粘贴歌单 ID / 链接 + 解析按钮
///   - 中部：歌单曲目表（带勾选 + 立即下载按钮）
///   - 底部：进行中的下载队列 + 失败列表
///
/// 对应 ncm 标签页 "下载"。
struct DownloadView: View {
    @EnvironmentObject private var appState: AppState
    @State private var input: String = ""
    @State private var loadedPlaylist: Playlist?
    @State private var selection: Set<Int64> = []
    @State private var loadingPlaylist: Bool = false
    @State private var localError: String?

    var body: some View {
        VStack(spacing: 0) {
            inputBar
            Divider()
            if let playlist = loadedPlaylist {
                playlistTable(playlist)
            } else {
                emptyState
            }
            Divider()
            queueFooter
        }
        .alert("出错了", isPresented: errorBinding) {
            Button("好") { localError = nil }
        } message: {
            Text(localError ?? "")
        }
    }

    // MARK: - Sections

    private var inputBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("粘贴歌单 ID 或链接（如 3778678 或 https://music.163.com/playlist?id=3778678）", text: $input)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await loadPlaylist() } }
                Button(action: { Task { await loadPlaylist() } }) {
                    Label(loadingPlaylist ? "加载中…" : "获取歌单", systemImage: "arrow.down.doc")
                }
                .buttonStyle(.borderedProminent)
                .disabled(loadingPlaylist || input.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            HStack {
                Picker("音质", selection: $appState.settings.defaultQuality) {
                    ForEach(AudioQuality.allCases) { q in
                        Text(q.displayName).tag(q)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 460)
                Spacer()
                Toggle("下载歌词", isOn: $appState.settings.downloadLyrics)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                Toggle("覆盖已有", isOn: $appState.settings.overwriteExisting)
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
        }
        .padding(12)
    }

    private func playlistTable(_ playlist: Playlist) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(playlist.name).font(.headline)
                Text("·").foregroundStyle(.secondary)
                Text(playlist.creator.isEmpty ? "未知创建者" : playlist.creator)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(playlist.tracks.count) 首")
                    .foregroundStyle(.secondary)
                Button("全选") { selection = Set(playlist.tracks.map(\.id)) }
                Button("取消全选") { selection.removeAll() }
                Button {
                    enqueueSelected(from: playlist)
                } label: {
                    Label("加入下载（\(selection.count)）", systemImage: "arrow.down.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(selection.isEmpty)
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            Divider()
            List(playlist.tracks, selection: $selection) { song in
                SongRow(song: song, trailing: SongRow.SongTrailing.primaryAction)
                    .environmentObject(appState)
                    .tag(song.id)
            }
            .listStyle(.inset)
        }
    }

    private var queueFooter: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("下载队列").font(.headline)
                Spacer()
                Text("运行中 \(appState.downloader.runningCount) / 总计 \(appState.downloader.tasks.count)")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Button("清空已完成") { appState.downloader.clearFinished() }
            }
            if appState.downloader.tasks.isEmpty && appState.downloader.failedTasks.isEmpty {
                Text("暂无下载任务。")
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 6)
            } else {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(appState.downloader.tasks) { task in
                            DownloadTaskRow(task: task)
                                .environmentObject(appState)
                        }
                        ForEach(appState.downloader.failedTasks) { task in
                            DownloadTaskRow(task: task)
                                .environmentObject(appState)
                        }
                    }
                }
                .frame(maxHeight: 220)
            }
        }
        .padding(12)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "tray.and.arrow.down")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)
            Text("粘贴一个歌单 ID 或链接开始")
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Actions

    private func loadPlaylist() async {
        let id = parsePlaylistID(from: input)
        guard let id else {
            localError = "无法解析歌单 ID"
            return
        }
        loadingPlaylist = true
        defer { loadingPlaylist = false }
        do {
            let playlist = try await appState.api.fetchPlaylistDetail(id: id)
            self.loadedPlaylist = playlist
            self.selection = Set(playlist.tracks.map(\.id))
        } catch {
            localError = error.localizedDescription
        }
    }

    private func parsePlaylistID(from text: String) -> Int64? {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if s.contains("music.163.com") || s.contains("163.cn") {
            if let queryRange = s.range(of: "id=") {
                let tail = s[queryRange.upperBound...]
                let digits = String(tail.prefix { $0.isNumber })
                if let id = Int64(digits) { return id }
            }
        }
        return Int64(s)
    }

    private func enqueueSelected(from playlist: Playlist) {
        let dir = appState.settings.defaultDownloadDirectory
        let q = appState.settings.defaultQuality
        let includeLyrics = appState.settings.downloadLyrics
        var tasks: [DownloadTask] = []
        for song in playlist.tracks where selection.contains(song.id) {
            let filename = makeFilename(for: song, quality: q)
            let url = dir.appendingPathComponent(filename)
            tasks.append(DownloadTask(song: song, quality: q, url: url, includeLyrics: includeLyrics))
        }
        appState.downloader.enqueueAll(tasks)
    }

    private func makeFilename(for song: Song, quality: AudioQuality) -> String {
        let artist = song.artists.first?.name ?? "Unknown"
        let safe = "\(artist) - \(song.name)"
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        return "\(safe).\(quality.fileExtension)"
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { localError != nil },
            set: { newValue in if !newValue { localError = nil } }
        )
    }
}

/// 单曲行（用于歌单表、搜索结果、本地音乐）。
struct SongRow: View {
    @EnvironmentObject private var appState: AppState
    let song: Song
    var trailing: SongTrailing = .privateAction

    enum SongTrailing {
        case primaryAction
        case privateAction
        case both
    }

    var body: some View {
        HStack(spacing: 10) {
            AsyncImage(url: song.coverURL) { phase in
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
            .frame(width: 36, height: 36)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            VStack(alignment: .leading, spacing: 2) {
                Text(song.name).lineLimit(1)
                Text("\(song.displayArtists) · \(song.album.name)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Text(song.displayDuration)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            switch trailing {
            case .primaryAction:
                Button {
                    quickDownload(song)
                } label: {
                    Image(systemName: "arrow.down.circle")
                }
                .buttonStyle(.borderless)
            case .privateAction:
                Button {
                    appState.player.playOrEnqueue(song)
                } label: {
                    Image(systemName: "play.circle")
                }
                .buttonStyle(.borderless)
            case .both:
                HStack(spacing: 4) {
                    Button { appState.player.playOrEnqueue(song) } label: {
                        Image(systemName: "play.circle")
                    }.buttonStyle(.borderless)
                    Button { quickDownload(song) } label: {
                        Image(systemName: "arrow.down.circle")
                    }.buttonStyle(.borderless)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func quickDownload(_ song: Song) {
        let dir = appState.settings.defaultDownloadDirectory
        let q = appState.settings.defaultQuality
        let safe = "\(song.displayArtists) - \(song.name)"
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        let url = dir.appendingPathComponent("\(safe).\(q.fileExtension)")
        let task = DownloadTask(song: song, quality: q, url: url, includeLyrics: appState.settings.downloadLyrics)
        appState.downloader.enqueue(task)
    }
}

/// 单条下载任务行：进度条 + 状态 + 取消/重试。
struct DownloadTaskRow: View {
    @EnvironmentObject private var appState: AppState
    let task: DownloadTask

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(task.song.name).lineLimit(1)
                HStack(spacing: 6) {
                    Text(task.status.displayName)
                        .font(.caption)
                        .foregroundStyle(color(for: task.status))
                    Text("·").foregroundStyle(.tertiary)
                    Text(task.quality.displayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if case .finished(let url) = task.status {
                        Text("· \(url.path)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    } else if case .failed(let msg) = task.status {
                        Text("· \(msg)").font(.caption).foregroundStyle(.red).lineLimit(1)
                    }
                }
                if case .downloading(let progress, _) = task.status {
                    ProgressView(value: progress).frame(height: 6)
                    Text("\(Int(task.bytesDownloaded / 1024))KB / \(Int(task.totalBytes / 1024))KB")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            switch task.status {
            case .downloading, .queued, .paused:
                Button {
                    appState.downloader.cancel(taskId: task.id)
                } label: {
                    Image(systemName: "xmark.circle")
                }.buttonStyle(.borderless)
            case .failed:
                Button {
                    appState.downloader.retry(taskId: task.id)
                } label: {
                    Image(systemName: "arrow.clockwise")
                }.buttonStyle(.borderless)
            default:
                EmptyView()
            }
        }
        .padding(.vertical, 2)
    }

    private func color(for s: DownloadStatus) -> Color {
        switch s {
        case .queued: return .secondary
        case .downloading: return .blue
        case .finished: return .green
        case .failed: return .red
        case .cancelled: return .orange
        case .paused: return .yellow
        }
    }
}