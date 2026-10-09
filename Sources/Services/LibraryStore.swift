import Foundation
import SwiftUI
import Combine

/// 账号歌单库：缓存登录账号的所有歌单（含"我喜欢的"），给侧栏 / 播放页用。
@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var accountPlaylists: [Playlist] = []
    @Published private(set) var likedPlaylist: Playlist?
    @Published private(set) var isLoading: Bool = false
    @Published private(set) var lastError: String?

    private let api: NeteaseAPI
    private let auth: AuthService
    private var loadTask: Task<Void, Never>?

    init(api: NeteaseAPI, auth: AuthService) {
        self.api = api
        self.auth = auth
    }

    /// 刷新账号歌单。重复调用会取消上一次任务。
    func refreshAccountPlaylists() {
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            await self?.performRefresh()
        }
    }

    private func performRefresh() async {
        guard let account = auth.account else {
            accountPlaylists = []
            likedPlaylist = nil
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            let playlists = try await api.fetchUserPlaylists(userId: account.userId)
            accountPlaylists = playlists.filter { !$0.isLiked }
            likedPlaylist = playlists.first(where: { $0.isLiked })
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// 拉取某个歌单的完整曲目（懒加载）。
    func loadPlaylistTracks(id: Int64) async -> Playlist? {
        do {
            return try await api.fetchPlaylistDetail(id: id)
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    /// 在已有列表里查找（按 id 命中）。
    func cachedPlaylist(id: Int64) -> Playlist? {
        if likedPlaylist?.id == id { return likedPlaylist }
        return accountPlaylists.first(where: { $0.id == id })
    }

    /// 创建新歌单。返回创建后的 playlist id。
    func createPlaylist(name: String, isPrivate: Bool = false) async throws -> Int64 {
        let data = try await api.eapi(
            path: NeteaseAPI.playlistCreate,
            payload: [
                ("name", .string(name)),
                ("privacy", .int(Int64(isPrivate ? 10 : 0))),
            ]
        )
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        guard let id = (json["playlist"] as? [String: Any])?["id"] as? Int64 else {
            throw APIError.malformedResponse
        }
        refreshAccountPlaylists()
        return id
    }

    /// 删除歌单。
    func deletePlaylist(id: Int64) async throws {
        let data = try await api.eapi(
            path: NeteaseAPI.playlistDelete,
            payload: [("id", .int(id))]
        )
        _ = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        refreshAccountPlaylists()
    }

    /// 收藏/取消收藏歌单。``subscribe=true`` 表示收藏。
    func subscribe(playlistId: Int64, subscribe: Bool) async throws {
        let data = try await api.eapi(
            path: NeteaseAPI.playlistSubscribe,
            payload: [
                ("id", .int(playlistId)),
                ("t", .int(Int64(subscribe ? 1 : 2))),
            ]
        )
        _ = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }

    /// 增/删歌单曲目。
    func addTracks(playlistId: Int64, trackIds: [Int64]) async throws {
        guard !trackIds.isEmpty else { return }
        let data = try await api.eapi(
            path: NeteaseAPI.playlistTracksAdd,
            payload: [
                ("pid", .int(playlistId)),
                ("trackIds", .string(trackIds.map { String($0) }.joined(separator: ","))),
            ]
        )
        _ = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }

    func removeTracks(playlistId: Int64, trackIds: [Int64]) async throws {
        guard !trackIds.isEmpty else { return }
        let data = try await api.eapi(
            path: NeteaseAPI.playlistTracksDel,
            payload: [
                ("pid", .int(playlistId)),
                ("trackIds", .string(trackIds.map { String($0) }.joined(separator: ","))),
            ]
        )
        _ = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }
}
