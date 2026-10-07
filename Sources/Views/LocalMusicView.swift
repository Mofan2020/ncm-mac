import SwiftUI
import Combine
import AppKit

/// 本地音乐页：管理本地文件夹 + 扫描 + 列表播放。
struct LocalMusicView: View {
    @EnvironmentObject private var appState: AppState
    @State private var isScanning: Bool = false
    @State private var localError: String?

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if appState.localMusic.tracks.isEmpty {
                emptyState
            } else {
                List(appState.localMusic.tracks) { track in
                    LocalTrackRow(track: track)
                        .environmentObject(appState)
                        .onTapGesture { play(track) }
                }
            }
        }
        .alert("出错了", isPresented: errorBinding) {
            Button("好") { localError = nil }
        } message: {
            Text(localError ?? "")
        }
    }

    // MARK: - Sections

    private var toolbar: some View {
        HStack {
            Button {
                pickFolder()
            } label: {
                Label("添加文件夹", systemImage: "plus.folder")
            }
            Button {
                Task { await rescan() }
            } label: {
                if isScanning {
                    ProgressView().controlSize(.small)
                    Text("扫描中…")
                } else {
                    Label("重新扫描", systemImage: "arrow.clockwise")
                }
            }
            .disabled(isScanning)
            Spacer()
            Menu("文件夹") {
                if appState.localMusic.folders.isEmpty {
                    Text("未添加").foregroundStyle(.secondary)
                } else {
                    ForEach(appState.localMusic.folders, id: \.self) { folder in
                        Button(folder.path) { }
                            .contextMenu {
                                Button("移除") {
                                    appState.localMusic.removeFolder(folder)
                                }
                            }
                    }
                }
            }
        }
        .padding(10)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "folder.badge.plus")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)
            Text("添加一个音乐文件夹开始")
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Actions

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "添加"
        if panel.runModal() == .OK {
            for url in panel.urls {
                appState.localMusic.addFolder(url)
            }
            Task { await rescan() }
        }
    }

    private func rescan() async {
        isScanning = true
        defer { isScanning = false }
        await appState.localMusic.rescan()
    }

    private func play(_ track: LocalTrack) {
        guard let idx = appState.localMusic.tracks.firstIndex(where: { $0.url == track.url }) else { return }
        appState.player.playLocalQueue(appState.localMusic.tracks, startIndex: idx)
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { localError != nil },
            set: { newValue in if !newValue { localError = nil } }
        )
    }
}

struct LocalTrackRow: View {
    @EnvironmentObject private var appState: AppState
    let track: LocalTrack

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Color.secondary.opacity(0.15)
                Image(systemName: "music.quarternote.3")
                    .foregroundStyle(.secondary)
            }
            .frame(width: 36, height: 36)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title.isEmpty ? track.url.lastPathComponent : track.title)
                    .lineLimit(1)
                Text("\(track.artist) · \(track.album)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Text(format(track.duration))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private func format(_ t: TimeInterval) -> String {
        let m = Int(t) / 60
        let s = Int(t) % 60
        return String(format: "%d:%02d", m, s)
    }
}