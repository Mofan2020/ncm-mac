# Architecture

## 模块关系

```
┌─────────────────────────────────────────────────────┐
│                       AppState                       │
│  (ObservableObject, 聚合所有服务, 持 settings + api)  │
└──────────────────┬──────────────────────────────────┘
                   │ @EnvironmentObject
        ┌──────────┼──────────┬──────────┬──────────┐
        ▼          ▼          ▼          ▼          ▼
    Settings    NeteaseAPI   Auth    Library     Local
    Store                   Service  Store       Music
   ↑                                               │
   │                                               │
   ├── PlayerService ←── LyricsService              │
   │       │                                       │
   │       └────→ DownloadManager ───→ API         │
   │                                               │
   └──────→ UpdateService (GitHub Releases)         │
                                                     
       Views:
       ├── ContentView (侧栏 + detail)
       ├── DownloadView     DownloadTaskRow
       ├── PlayView         ControlBar
       ├── LibraryView      PlaylistDetailSheet
       ├── LocalMusicView   LocalTrackRow
       └── SettingsView     QRCodeView
```

所有服务都是 `@MainActor` 的 `ObservableObject`，AppState 是它们的容器与连线点（auth 的 cookie 注入 api、account 变化触发 library 重拉等）。

## eapi 加密

`CryptoService` 是 `ncm/src/core/crypto.py` 的 Swift 复刻。

```python
# Python
message = f"{path}-36cd479b6b5-{json}-36cd479b6b5-{md5(nobody{path}use{json}md5forencrypt)}"
params  = HEX_UPPER(AES-128-ECB-PKCS7(message, key="e82ckenh8dichen8"))
```

Swift 端：

- JSON 序列化：Swift 的 `[String: Any]` 是无序哈希表，**无法保留插入顺序**。而网易云服务端按 JSON 字节流做 md5 签名，字段顺序参与计算——所以本模块引入 `OrderedDict = [(String, AnyValue)]` 类型，强制调用方按顺序构造 payload。
- `JEncoder`（在 `CryptoService.swift` 里）是一个手写的紧凑 JSON 编码器，行为对齐 Python `json.dumps(separators=(",", ":"), ensure_ascii=False)`：无空格、保留插入顺序、字符串不做 Unicode 转义、字典整数 key 不被转为 Double。
- AES-128-ECB-PKCS7：CryptoKit 不暴露 ECB；走 CommonCrypto `CCCrypt(kCCOptionECBMode|kCCOptionPKCS7Padding, ...)`。CommonCrypto macOS 自带，无第三方依赖。
- MD5：`CryptoKit.Insecure.MD5`，hex 小写。

参数签名顺序（path → JSON → md5）与 Python 完全对齐；用 `scripts/gen_test_vectors.py` + 独立 Swift 校验器做 byte-level 校验（不依赖真实网络）。

## 响应解压

所有 `eapi/*` 请求都加 `Accept-Encoding: gzip, deflate`（显式不含 `br`）——网易云默认会回 brotli，而 `URLSession` 默认不解 brotli，会拿到压缩字节流导致 JSON 解析失败。QR 接口（`qrKey` / `qrPoll`）同样处理。

## QR 登录

`AuthService.startQRLogin()` 走两步：

1. `NeteaseAPI.qrKey()` —— `GET /api/login/qrcode/unikey?type=1&timestamp=...`。
   legacy 接口**不加密**，加 `User-Agent: Mozilla/5.0 ... Safari/16.6` 和
   `Cookie: os=pc; appver=8.9.70; channel=netease` 身份头（不带这俩服务端
   可能拒）。
2. `NeteaseAPI.qrPoll(unikey:)` —— 走 eapi 通道 `POST /eapi/.../client/login`，
   payload `{"key": unikey, "type": 1}`。响应里 `code` / `cookie` 可能嵌套
   在 `data.*` 下，解析要做 nested fallback；`cookie` 也兼容 dict 形式。

`NeteaseAPI.userAgent` / `clientCookieHeader` 是这两个头的单一来源（`static`）。

## 播放 vs ncm 的回环 HTTP

ncm 的 `mediaserver.py` 是给 pywebview 准备的：pywebview 的 `file://` 同源策略不让 webview 直接读本地文件，所以起一个回环 HTTP 服务器代理授权过的 file/CDN 流。

ncm-mac 走原生 SwiftUI + AVPlayer：

- 在线：直接 `AVURLAsset(url: songURL)` 喂给 AVPlayer。
- 本地：直接 `AVURLAsset(url: fileURL)`。
- 无沙箱（`ENABLE_APP_SANDBOX=NO`），NSOpenPanel 选过的目录一律可读。
- 续播、上一首下一首、模式、进度上报都直接走 SwiftUI 状态。

## 下载并发与 `.part`

`DownloadManager` 用 `URLSession` + `URLSessionDownloadTask`：

- 并发数走 settings.concurrentDownloads（默认 2）。
- Delegate 拿到下载完成的临时文件后：
  1. 把文件挪到 `<target>.part`
  2. 校验文件大小是否与接口声明一致；不一致就删 part 标失败
  3. 原子 `rename(.part → target)`
- 失败任务不阻塞其他，列在 `failedTasks` 单独展示。

## 本地音乐零依赖

ncm 这边已经验证过 `mutagen` 是 GPL，ncm 是 MIT，不能引入。`LocalMusicService` 用三个手写解析器：

- `ID3v2Parser`：mp3 的 `ID3` 头 + frames（TIT2 / TPE1 / TALB / APIC / USLT）
- `VorbisParser`：flac 的 `fLaC` + metadata blocks；ogg 的 `vorbis` comment header
- `MP4Parser`：递归走 atoms（moov / udta / meta / ilst），找 `©nam` / `©ART` / `©alb` / `covr` / `©lyr`

读不到的走文件名兜底：`"01 - Artist - Title"` → `(Artist, Title)`。

Cover / 嵌入歌词在扫描时不读；播放时按需调用 `readCover(for:)` / `readEmbeddedLyrics(for:)`。

扫描结果写到 `local-index.json`，按 `(mtime, size)` 做缓存键。

## 自动更新

`UpdateService` 直接调 `https://api.github.com/repos/Mofan2020/ncm-mac/releases`，按 `updateChannel` 过滤正式版 / 预发布，比较语义化版本（去 `v` 前缀，逐段数字）。新版可用时 UI 跳到 GitHub Release 页由用户手动下载。

不引入 Sparkle / Squirrel；偏好不要外部依赖。

JSON 解析细节（GitHub API 字段是 snake_case，Swift Codable 不会自动转 camelCase，必须显式声明）：

- 不要用 `convertFromSnakeCase` —— 它对缩写（`html_url` → `htmlUrl` ≠ `htmlURL`）和 `isPrerelease`（GitHub 字段叫 `prerelease`，不会自动加 `is` 前缀）处理不了
- 正确做法：手动写 `enum CodingKeys: String, CodingKey` 显式映射每个字段（`tag_name` ↔ `tagName`、`html_url` ↔ `htmlURL`、`prerelease` ↔ `isPrerelease` 等）
- 自定义 `dateDecodingStrategy` 兼容带/不带 fractional seconds 的 ISO8601（`withInternetDateTime` + `withFractionalSeconds` 两套）
- `ReleaseInfo.name` / `body` 声明为 `String?` —— GitHub API 对自动化发版的 release 这两个字段可能为 null；UI 层做 `??` fallback

## SwiftUI 子 ObservableObject 转发

`AppState` 把 `settings` / `updater` / `player` / `library` / `localMusic` 等子服务挂成属性（`var` 或 `let`）。**SwiftUI 视图对子 ObservableObject 不自动订阅**——`appState.player.mode` 变了，body 不重算。

模式：AppState.init 把每个子服务的 `objectWillChange` 转发到 `self.objectWillChange`，订阅保存到 `cancellables`。子服务任何 `@Published` 字段变化都会冒泡，触发所有 `appState` 视图重渲染。

```swift
player.objectWillChange
    .receive(on: RunLoop.main)
    .sink { [weak self] _ in self?.objectWillChange.send() }
    .store(in: &cancellables)
```

适用对象：所有被 SettingsView 等视图**读**子属性的服务（settings、updater、player、library、localMusic）。AuthService / DownloadManager / NeteaseAPI 主要被**写**操作调用、不在视图 body 里读，不一定要转发。

## settings → SwiftUI 环境

`SettingsView` 改 `settings.theme` / `language` / `liquidGlassEnabled` 后，要在 app 全局生效，必须在 WindowGroup 根 ContentView 上挂 modifier 把 settings 投射到 SwiftUI 环境：

- `ThemingModifier` —— `preferredColorScheme(theme.colorScheme)`
- `LocaleModifier` —— `.environment(\.locale, Locale(identifier: language.localeIdentifier))`
- `MaterialModifier` —— `.background(.background)`（关液态玻璃时退回普通底）

加上 `.id("lang-\(language.rawValue)")` —— SwiftUI 的 `.environment(\.locale)` 改了不会自动重新本地化已渲染的 view tree，靠 id 强制整树重建。

## 窗口透明（macOS 26 NavigationSplitView）

`WindowAccessor` 把 `NSWindow.backgroundColor = .clear` + `styleMask.insert(.fullSizeContentView)`——为了让 sidebar 的玻璃材质透出桌面色。**但** detail 区 SwiftUI 默认不画背景，文字直接画在透明上、字看不清。

修法：ContentView 的 detail 块统一加 `.background(.regularMaterial)`，与 sidebar 视觉一致。一次性给 5 个 detail view（Download/Play/Library/LocalMusic/Settings）都加底色。

## macOS 26 / Swift 5.9 / SDK 27

- `deploymentTarget.macOS = "26.0"`
- `SWIFT_VERSION = "5.9"`
- `MARKETING_VERSION` 写在 `project.yml`，xcodebuild Release 时 `--release` 数字同步。手动 bump；不要自动化脚本。
- `ENABLE_APP_SANDBOX = NO`：`fileImporter` 在沙箱外才有合理行为；用户给的目录直接写。
- 用了 `Set<AnyCancellable>` 与 `async/await`、`@MainActor` 隔离。Combine 仅在 AppState 里订阅 settings 变化用一处。

## 已知边界

- 自动更新走用户手动下载（没有 Apple Developer 账号无法签名）。
- 在线播放的 Referer / Cookie 注入在 AVURLAsset 上没有现成 API；当前 eapi 返回的 URL 已带签名，官方对跨域 referer 校验是放行的。如果网易云收紧 Referer 校验，需切到 `AVAssetResourceLoader` 自实现代理。
- LyricsService 的双语行展示当前是「原句 + 翻译各一行」，与 ncm Python 端一致。
- PlayerService 的续播恢复在启动后**不立即拉 URL**，只记 id 序列；等 PlayView 拉到完整歌单/搜索结果后调用 `player.tryRestoreQueue(from: candidates)` 重建队列。这样启动时不发任何网络请求。