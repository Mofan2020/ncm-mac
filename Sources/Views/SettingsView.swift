import SwiftUI
import AppKit
import Combine

/// 设置页：账号 / 通用 / 下载 / 播放 / 外观 / 更新。
/// `selection` binding 由父视图（ContentView）持有，不能用 @State——否则父视图重算
/// 子视图重建，@State 重置回 .account（"改主题/语言跳回账号 tab" bug）。
struct SettingsView: View {
    @EnvironmentObject private var appState: AppState
    @Binding var selection: SettingsTab

    enum SettingsTab: String, CaseIterable, Identifiable, Hashable {
        case account, general, download, playback, appearance, update
        var id: String { rawValue }

        var title: LocalizedStringKey {
            switch self {
            case .account:    return "settings.tab.account"
            case .general:    return "settings.tab.general"
            case .download:   return "settings.tab.download"
            case .playback:   return "settings.tab.playback"
            case .appearance: return "settings.tab.appearance"
            case .update:     return "settings.tab.update"
            }
        }
    }

    var body: some View {
        TabView(selection: $selection) {
            accountTab
                .tabItem { Label("settings.tab.account", systemImage: "person.crop.circle") }
                .tag(SettingsTab.account)
            generalTab
                .tabItem { Label("settings.tab.general", systemImage: "gearshape") }
                .tag(SettingsTab.general)
            downloadTab
                .tabItem { Label("settings.tab.download", systemImage: "arrow.down.circle") }
                .tag(SettingsTab.download)
            playbackTab
                .tabItem { Label("settings.tab.playback", systemImage: "play.circle") }
                .tag(SettingsTab.playback)
            appearanceTab
                .tabItem { Label("settings.tab.appearance", systemImage: "paintbrush") }
                .tag(SettingsTab.appearance)
            updateTab
                .tabItem { Label("settings.tab.update", systemImage: "arrow.triangle.2.circlepath") }
                .tag(SettingsTab.update)
        }
        .frame(width: 640, height: 480)
    }

    // MARK: - Account

    private var accountTab: some View {
        Form {
            Section {
                if appState.auth.isLoggedIn, let account = appState.auth.account {
                    HStack {
                        AsyncImage(url: account.avatarURL) { phase in
                            switch phase {
                            case .success(let img):
                                img.resizable().aspectRatio(contentMode: .fill)
                            default:
                                ZStack {
                                    Color.secondary.opacity(0.15)
                                    Image(systemName: "person.fill").foregroundStyle(.secondary)
                                }
                            }
                        }
                        .frame(width: 56, height: 56)
                        .clipShape(Circle())
                        VStack(alignment: .leading) {
                            Text(account.nickname).font(.title3)
                            Text(account.vipType >= 1 ? (account.vipType >= 11 ? "SVIP" : "VIP") : "普通用户")
                                .foregroundStyle(.secondary)
                                .font(.caption)
                        }
                    }
                    Button(role: .destructive) {
                        Task { await appState.auth.logout() }
                    } label: {
                        Label("退出登录", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                } else {
                    Text("未登录").foregroundStyle(.secondary)
                    HStack {
                        Button("扫码登录") {
                            Task { await appState.auth.startQRLogin() }
                        }
                        Button("导入 Cookie…") {
                            showPasteCookieSheet = true
                        }
                    }
                }
            } header: { Text("账号") }
            if case .waitingForScan = appState.auth.qrState {
                Section {
                    if let url = appState.auth.qrImageURL {
                        QRCodeView(content: url.absoluteString)
                            .frame(width: 180, height: 180)
                            .padding(.vertical, 6)
                    }
                    Text(appState.auth.qrState.displayName)
                        .foregroundStyle(.secondary)
                } header: { Text("扫码") }
            } else if case .waitingForConfirm = appState.auth.qrState {
                Section {
                    Text(appState.auth.qrState.displayName)
                        .foregroundStyle(.secondary)
                } header: { Text("已扫码") }
            } else if case .failed(let message) = appState.auth.qrState {
                Section {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    Button("重新扫码") {
                        Task { await appState.auth.startQRLogin() }
                    }
                } header: { Text("登录失败") }
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showPasteCookieSheet) {
            pasteCookieSheet
        }
        .padding()
    }

    @State private var showPasteCookieSheet: Bool = false
    @State private var pasteCookieText: String = ""

    private var pasteCookieSheet: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("粘贴 Cookie")
                .font(.headline)
            Text("粘贴形如 MUSIC_U=xxxxxx 的 cookie 字符串，或整段浏览器 cookie。")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextEditor(text: $pasteCookieText)
                .frame(minHeight: 120)
                .font(.system(.body, design: .monospaced))
            HStack {
                Spacer()
                Button("取消") { showPasteCookieSheet = false }
                Button("登录") {
                    Task {
                        await appState.auth.loginWithCookieString(pasteCookieText)
                        showPasteCookieSheet = false
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(pasteCookieText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    // MARK: - General

    private var generalTab: some View {
        Form {
            Section("语言") {
                Picker("界面语言", selection: $appState.settings.language) {
                    ForEach(AppLanguage.allCases) { l in
                        Text(l.displayName).tag(l)
                    }
                }
                .pickerStyle(.menu)
            }
            Section("日志与诊断") {
                Button("打开配置目录") {
                    let url = (try? FileManager.default.url(
                        for: .applicationSupportDirectory,
                        in: .userDomainMask,
                        appropriateFor: nil,
                        create: false
                    ).appendingPathComponent("NeteaseMusicDownloader")) ?? URL(fileURLWithPath: NSHomeDirectory())
                    NSWorkspace.shared.open(url)
                }
            }
            Section("维护") {
                Button(role: .destructive) {
                    forceRefresh()
                } label: {
                    Label("强制刷新全部缓存", systemImage: "arrow.clockwise.circle.fill")
                }
                .help("清空本地音乐索引、账号会话缓存和 .part 下载临时文件，\n下次启动会重新扫描本地音乐并从服务器重新拉取歌单/账号信息。\n不会删除已下载的歌曲、歌词和你的偏好设置。")
                if let done = lastForceRefreshMessage {
                    Text(done).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    @State private var lastForceRefreshMessage: String?

    private func forceRefresh() {
        // 1) 清本地音乐扫描索引（下次访问"本地"页会全量重扫）
        // 2) 清账号会话 + Cookie（不删 deviceId；eapi 签名靠它）
        // 3) 清未完成的 .part 临时文件
        // 4) 触发 library 重新拉账号歌单（不重新登录；只刷服务端数据）
        let appSupport = (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: false
        ).appendingPathComponent("NeteaseMusicDownloader", isDirectory: true)) ?? URL(fileURLWithPath: NSTemporaryDirectory())
        var cleared: [String] = []
        var skipped: [String] = []

        // local-index.json
        let indexURL = appSupport.appendingPathComponent("local-index.json")
        if FileManager.default.fileExists(atPath: indexURL.path) {
            do { try FileManager.default.removeItem(at: indexURL); cleared.append("本地音乐索引") }
            catch { skipped.append("本地音乐索引（\(error.localizedDescription)）") }
        }
        // 未完成 .part 临时文件
        let downloads = appState.settings.defaultDownloadDirectory
        if let entries = try? FileManager.default.contentsOfDirectory(at: downloads, includingPropertiesForKeys: nil) {
            let parts = entries.filter { $0.pathExtension == "part" }
            for p in parts {
                try? FileManager.default.removeItem(at: p)
            }
            if !parts.isEmpty { cleared.append("\(parts.count) 个 .part 临时文件") }
        }
        // 退出登录（不删本地已下载文件、不删 deviceId）
        Task {
            await appState.auth.logout()
            await MainActor.run {
                lastForceRefreshMessage = "已清空：\(cleared.joined(separator: "、"))。请重新登录以从服务器拉取账号信息。"
            }
        }
    }

    // MARK: - Download

    private var downloadTab: some View {
        Form {
            Section("下载目录") {
                HStack {
                    Text(appState.settings.defaultDownloadDirectory.path)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("选择…") {
                        let panel = NSOpenPanel()
                        panel.canChooseDirectories = true
                        panel.canChooseFiles = false
                        panel.prompt = "选择"
                        if panel.runModal() == .OK, let url = panel.url {
                            appState.settings.defaultDownloadDirectory = url
                        }
                    }
                }
            }
            Section("音质") {
                Picker("默认音质", selection: $appState.settings.defaultQuality) {
                    ForEach(AudioQuality.allCases) { q in
                        Text(q.displayName).tag(q)
                    }
                }
            }
            Section("并发与行为") {
                Stepper(value: $appState.settings.concurrentDownloads, in: 1...3) {
                    Text("同时下载数：\(appState.settings.concurrentDownloads)")
                }
                Toggle("覆盖已存在的文件", isOn: $appState.settings.overwriteExisting)
                Toggle("同时下载歌词（.lrc）", isOn: $appState.settings.downloadLyrics)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    // MARK: - Playback

    private var playbackTab: some View {
        Form {
            Section("播放源") {
                Toggle("优先播放本地版本", isOn: $appState.settings.preferredLocalPlay)
                Text("开启后，列表里与本地匹配（同曲名同歌手）的歌曲优先用本地文件。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("质量与统计") {
                Picker("在线音质", selection: $appState.settings.defaultQuality) {
                    ForEach(AudioQuality.allCases) { q in
                        Text(q.displayName).tag(q)
                    }
                }
                Toggle("上报播放次数到云端", isOn: $appState.settings.reportPlayCountToCloud)
                Button(role: .destructive) {
                    appState.settings.clearPlayCounts()
                } label: {
                    Label("清空本地播放次数", systemImage: "trash")
                }
            }
            Section("模式") {
                Picker("默认播放模式", selection: Binding(
                    get: { appState.player.mode },
                    set: { appState.player.setMode($0) }
                )) {
                    ForEach(PlayMode.allCases) { m in
                        Label(m.displayName, systemImage: m.systemImage).tag(m)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    // MARK: - Appearance

    private var appearanceTab: some View {
        Form {
            Section("主题") {
                Picker("主题", selection: $appState.settings.theme) {
                    ForEach(AppTheme.allCases) { t in
                        Text(t.displayName).tag(t)
                    }
                }
                .pickerStyle(.segmented)
                Toggle("启用液态玻璃效果", isOn: $appState.settings.liquidGlassEnabled)
                Text("关闭后可降低毛玻璃对 GPU 的占用，老设备更顺畅。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    // MARK: - Update

    private var updateTab: some View {
        Form {
            Section("自动更新") {
                Toggle("启动后检查新版本", isOn: $appState.settings.autoCheckUpdates)
                Picker("更新通道", selection: $appState.settings.updateChannel) {
                    ForEach(UpdateChannel.allCases) { c in
                        Text(c.displayName).tag(c)
                    }
                }
                .pickerStyle(.menu)
                Button {
                    appState.updater.check()
                } label: {
                    if appState.updater.isChecking {
                        ProgressView().controlSize(.small)
                        Text("检查中…")
                    } else {
                        Label("立即检查更新", systemImage: "arrow.clockwise")
                    }
                }
                .disabled(appState.updater.isChecking)
            }
            Section("当前与最新") {
                LabeledContent("当前版本", value: UpdateService.currentVersion)
                if let latest = appState.updater.latest {
                    LabeledContent("最新版本", value: latest.version)
                    LabeledContent("最新版本名", value: latest.name ?? latest.tagName)
                    LabeledContent("发布时间", value: latest.publishedAt.formatted(date: .abbreviated, time: .omitted))
                    if let body = latest.body, !body.isEmpty {
                        DisclosureGroup("更新日志") {
                            Text(body).font(.caption)
                        }
                    }
                    if appState.updater.updateAvailable {
                        Button {
                            appState.updater.openReleasePage()
                        } label: {
                            Label("打开下载页", systemImage: "safari")
                        }
                        .buttonStyle(.borderedProminent)
                    } else {
                        Label("已是最新版本", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                } else {
                    Text("尚未检查更新").foregroundStyle(.secondary)
                }
                if let err = appState.updater.lastError {
                    Label(err, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
                if let last = appState.updater.lastChecked {
                    LabeledContent("上次检查", value: last.formatted(date: .abbreviated, time: .shortened))
                }
            }
            Section("如何安装") {
                Text("macOS 上未签名包首次打开请右键 → 打开，或在终端执行：")
                    .font(.caption)
                Text("xattr -dr com.apple.quarantine /Applications/NeteaseMusicDownloader.app")
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

/// 二维码渲染（用 CoreImage 把字符串渲染成 PNG；尺寸可控）。
struct QRCodeView: View {
    let content: String
    var body: some View {
        if let img = generate() {
            Image(nsImage: img)
                .resizable()
                .interpolation(.none)
                .aspectRatio(1, contentMode: .fit)
        } else {
            Color.secondary.opacity(0.1)
        }
    }

    private func generate() -> NSImage? {
        guard let data = content.data(using: .utf8),
              let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        let context = CIContext()
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: scaled.extent.width, height: scaled.extent.height))
    }
}