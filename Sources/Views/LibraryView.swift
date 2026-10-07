import SwiftUI
import Combine

/// 账号歌单页：展示当前账号的歌单（含「我喜欢的」），
/// 可创建 / 删除（自建）/ 收藏（他人创建）/ 进入查看曲目。
struct LibraryView: View {
    @EnvironmentObject private var appState: AppState
    @State private var loadingTracksId: Int64?
    @State private var presentedPlaylist: Playlist?
    @State private var newPlaylistName: String = ""
    @State private var showCreateSheet: Bool = false
    @State private var localError: String?

    var body: some View {
        NavigationStack {
            List {
                if appState.auth.isLoggedIn == false {
                    Section {
                        Text("未登录：扫码或粘贴 Cookie 登录即可同步账号歌单。")
                            .foregroundStyle(.secondary)
                    }
                }
                if let liked = appState.library.likedPlaylist {
                    Section("我喜欢的") {
                        playlistRow(liked, isLiked: true)
                    }
                }
                if !appState.library.accountPlaylists.isEmpty {
                    Section("歌单") {
                        ForEach(appState.library.accountPlaylists) { p in
                            playlistRow(p, isLiked: false)
                        }
                    }
                }
            }
            .navigationTitle("账号歌单")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showCreateSheet = true
                    } label: {
                        Label("新建歌单", systemImage: "plus")
                    }
                    .disabled(!appState.auth.isLoggedIn)
                }
            }
            .sheet(isPresented: $showCreateSheet) { createSheet }
            .sheet(item: $presentedPlaylist) { playlist in
                PlaylistDetailSheet(playlist: playlist)
                    .environmentObject(appState)
            }
            .refreshable { appState.library.refreshAccountPlaylists() }
        }
        .alert("出错了", isPresented: errorBinding) {
            Button("好") { localError = nil }
        } message: {
            Text(localError ?? "")
        }
    }

    // MARK: - Rows

    @ViewBuilder
    private func playlistRow(_ playlist: Playlist, isLiked: Bool) -> some View {
        HStack {
            AsyncImage(url: playlist.coverURL) { phase in
                switch phase {
                case .success(let img):
                    img.resizable().aspectRatio(contentMode: .fill)
                default:
                    ZStack {
                        Color.secondary.opacity(0.15)
                        Image(systemName: isLiked ? "heart.fill" : "music.note.list")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(width: 48, height: 48)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 2) {
                Text(playlist.name)
                    .font(.headline)
                if !playlist.creator.isEmpty {
                    Text(playlist.creator).font(.caption).foregroundStyle(.secondary)
                }
                Text("\(playlist.trackCount) 首")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            if loadingTracksId == playlist.id {
                ProgressView()
            } else {
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            Task { await open(playlist) }
        }
    }

    private var createSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("新建歌单").font(.title2)
            TextField("歌单名", text: $newPlaylistName)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("取消") {
                    showCreateSheet = false
                    newPlaylistName = ""
                }
                Button("创建") {
                    Task { await createPlaylist() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(newPlaylistName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 360)
    }

    // MARK: - Actions

    private func open(_ playlist: Playlist) async {
        loadingTracksId = playlist.id
        defer { loadingTracksId = nil }
        do {
            let detail = try await appState.library.loadPlaylistTracks(id: playlist.id) ?? playlist
            presentedPlaylist = detail
        } catch {
            localError = error.localizedDescription
        }
    }

    private func createPlaylist() async {
        do {
            _ = try await appState.library.createPlaylist(name: newPlaylistName)
            newPlaylistName = ""
            showCreateSheet = false
        } catch {
            localError = error.localizedDescription
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { localError != nil },
            set: { newValue in if !newValue { localError = nil } }
        )
    }
}

/// 进入歌单后弹出的曲目详情。
struct PlaylistDetailSheet: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    let playlist: Playlist
    @State private var isDeleting: Bool = false

    var body: some View {
        NavigationStack {
            List {
                Section("曲目（\(playlist.tracks.count)）") {
                    ForEach(playlist.tracks) { song in
                        SongRow(song: song, trailing: .privateAction)
                            .environmentObject(appState)
                            .onTapGesture { appState.player.playOrEnqueue(song) }
                    }
                }
            }
            .navigationTitle(playlist.name)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                if playlist.isOwnedByMe {
                    ToolbarItem(placement: .destructiveAction) {
                        Button(role: .destructive) {
                            Task { await deletePlaylist() }
                        } label: {
                            if isDeleting {
                                ProgressView()
                            } else {
                                Image(systemName: "trash")
                            }
                        }
                    }
                }
            }
        }
        .frame(minWidth: 520, minHeight: 480)
    }

    private func deletePlaylist() async {
        isDeleting = true
        defer { isDeleting = false }
        do {
            try await appState.library.deletePlaylist(id: playlist.id)
            dismiss()
        } catch {
            // 简单回退
        }
    }
}