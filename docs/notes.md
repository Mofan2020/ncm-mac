# Notes

实施笔记。给维护者看的「为什么这么做、走了哪些岔路、没动什么」。

## 与 ncm 的关系

ncm-mac 是 ncm 的 macOS 原生版。新仓库、SwiftUI 重写。同步策略：

- 新功能先在 ncm-mac 实现（macOS 原生快、不受 pywebview 限制）
- 里程碑版本完成后，按模块 backport 到 ncm 的对应源文件（保留 Python 实现风格，但 API 签名对齐）
- 不走每个 PR 都同步，太碎

ncm 的 `src/core/{crypto,api,downloader,library,lyrics,localmusic}.py` 是 ncm-mac 的 Swift 实现的对照蓝图；ncm-mac 这边的对应文件丢了，主仓 `ncm/src/core/` 仍能跑。

## 没动的与原因

- **`AppState.settings` 是 `var`**：SwiftUI binding `$appState.settings.xxx` 需要可写引用。`SettingsStore` 本身仍只构造一次（启动时从磁盘恢复默认值），绑定监听字段变化；改用 `var` 引用安全。
- **没有回环 HTTP 服务器**：pywebview 时代的 `mediaserver.py` 给 webview 用的，ncm-mac 不需要。
- **没有 mutagen / 其他 GPL 依赖**：ncm 这边已经验证过 mutagen 是 GPL，本项目 MIT。三套手写解析器覆盖 mp3/flac/m4a。
- **没有 Sparkle**：自动更新直接调 GitHub Releases API + 版本号对比，跳到下载页让用户自己处理签名问题。
- **没有后台进程 / 菜单栏应用**：只做菜单栏 app 入口；Music.app 接管 Now Playing 留作未来。
- **没有 Live2D**：ncm 也明确不支持，cubism SDK 法律约束。
- **avfoundation 没有真正写 NowPlaying 到 macOS Music.app 的 `MPNowPlayingInfoCenter`**：当前只暴露 `currentSong` 给 UI；播放控制走菜单栏 `播放` 子菜单。未来要补 `MPNowPlayingInfoCenter.default().nowPlayingInfo`。
- **测试**：仓库不带 XCTest target。eapi 签名 byte-level 校验靠 `scripts/gen_test_vectors.py` + 独立 Swift 校验器（不依赖真实网络）；UI 冒烟靠 `xcodebuild build` + GitHub Actions self-test（启动 4s 后 kill）+ 本地手动验收。

## 坑点

- **AES-128-ECB**：Swift CryptoKit 不暴露 ECB 模式，只能 CommonCrypto `CCCrypt`。CommonCrypto 是 macOS 自带的，不要去 `import` 它也**不要**给二进制链接（系统已暴露）。
- **JSON 字段顺序是有签名的**：网易云服务端按 JSON 字节流做 md5，字段顺序参与计算。Swift 的 `[String: Any]` 是无序哈希表，直接用它做 payload 会导致签名对不上 → 必须用 `OrderedDict = [(String, AnyValue)]`（CryptoService 定义），强制调用方按顺序构造。`JEncoder` 手写紧凑 JSON 输出，行为对齐 Python `json.dumps(separators=(",", ":"), ensure_ascii=False)`。
- **JSONEncoder 不能保持 dict 顺序**：`JSONEncoder` 内部用 `OrderedKeyedEncodingContainer`，输出时按键排序。`JEncoder` 走的是手写路径绕过这个限制，不要回退到 JSONEncoder。
- **brotli 解压**：网易云 `eapi/*` 响应默认 Content-Encoding: br，但 `URLSession` 默认不解 brotli（结果是把 br 字节流塞给 `JSONSerialization` 报 "Garbage at end"）。每个发往网易云的 request 都显式 `Accept-Encoding: gzip, deflate`（不含 br）让服务端改用 gzip，URLSession 默认会处理。NeteaseAPI 的 `eapi` / `qrKey` / `qrPoll` 三处都要加。
- **qrKey 必须 GET 不是 POST**：网易云 legacy 接口 `/api/login/qrcode/unikey` 用 GET + query string + timestamp；POST form body 服务端会拒。不需要 eapi 加密，但需要 `os/appver/channel` 身份 Cookie + 浏览器风格 User-Agent（"PC 客户端"身份才能拿到 session cookie）。
- **qrPoll 走 eapi 不是 plain POST**：状态轮询 `/api/login/qrcode/client/login` 走 eapi 通道；plain POST 服务端拒。响应里 `code` / `cookie` 可能嵌套在 `data.*` 下，解析要做 nested fallback。
- **`@Published` + `Binding` + `let`**：AppState 把 `settings` 暴露为 `var` 后，绑定才能写。SwiftUI Binding 的 setter 在 view body 里要 `$appState.settings.xxx`，不是 `$settings.xxx`。
- **`@EnvironmentObject` 子 ObservableObject 变更不重渲染**：`appState.player.mode` 这种 `.subObject.field` 访问，SwiftUI 不订阅子 ObservableObject，**写入正常但 body 不刷新**。修法：AppState.init 转发子服务的 `objectWillChange` 到 `self.objectWillChange`（settings、updater、player 等所有被视图读的子服务都要转发）。
- **TabView 必须绑 selection**：不写 `TabView(selection: $...)` + `.tag(xxx)`，每次 body 重算（settings 任意字段变都可能触发）会回到第一个 tab。`@State` 死变量（如 `showAccount` 写后没读）也是隐患，留着只会让阅读者误解意图。
- **`.environment(\.locale)` 改了不自动重新本地化**：SwiftUI 已知行为，locale 变了 view tree 不会自动重读字符串。修法：在 ContentView 根上加 `.id("lang-\(language.rawValue)")` 强制整树重建。
- **SettingsView 的 `selectedTab` 不能用 `@State`**：当父视图 ContentView 因 `appState.objectWillChange`（settings 任意字段改都会触发）重算时，`switch appState.selectedTab { case .settings: SettingsView() }` 会**新建 SettingsView 实例**，实例内的 `@State` 重置回初始值。修法：把 binding 提到父视图 `@State private var settingsTab` 持有，传 `@Binding var selection: SettingsTab` 给 SettingsView。
- **SwiftUI 国际化要走标准 i18n**：硬编码中文 string literal 不会被 `.environment(\.locale)` 自动翻译。必须用 `LocalizedStringKey`（如 `Text("settings.tab.account")`）或 `String(localized:)`，并在 bundle 里放 `Base.lproj/Localizable.strings` + `zh-Hans.lproj/Localizable.strings`。`project.yml` 要声明 `INFOPLIST_KEY_CFBundleLocalizations: ["en", "zh-Hans"]` bundle 才会加载。
- **`convertFromSnakeCase` 不智能**：处理 `html_url` → `htmlUrl`（错，我们要 `htmlURL`）+ 不给 `prerelease` 加 `is` 前缀（错，我们要 `isPrerelease`）。遇 GitHub API 等 snake_case 第三方必须手动 `enum CodingKeys: String, CodingKey` 显式映射。
- **JSONDecoder 不会自动 snake_case → camelCase**：GitHub API 字段是 `tag_name` / `html_url` / `prerelease`，Swift Codable 默认 `keyDecodingStrategy = .useDefaultKeys` 直接 keyNotFound → "data couldn't be read"。**不要**用 `.convertFromSnakeCase`（处理不了 `URL` 缩写和 `is` 前缀），必须手动 `enum CodingKeys: String, CodingKey` 显式映射。
- **ISO8601 日期可能带 fractional seconds**：`published_at = "2024-01-15T12:34:56.789Z"` 时 `JSONDecoder.dateDecodingStrategy = .iso8601` 会抛。要自定义 strategy 先试 `withFractionalSeconds` 再 fallback `withInternetDateTime`。
- **`NavigationSplitView` 里的 `if let ... ? ... : ...` 三元表达式**必须包 `Group { ... }`，否则编译器在 view builder 上下文里推不出类型。
- **`onChange` 在 macOS 14+ 是 `(of: value) -> Void` 单参数 closure**，老 API 形式不再用。
- **AVURLAsset 的 Referer/Cookie 注入**没有官方入口；如果 CDN 收紧校验，要切到 `AVAssetResourceLoader` 自实现。当前 eapi 返回的 URL 已带签名，校验是放行的，先这么跑。
- **`URLSession` 默认 60s 超时对一首 30MB 歌曲够用**；4K 视频无损（如杜比）可能 30+ MB/首，128 KB/s 缓冲基本够。
- **XCTest 没配**：Swift Package 单元测试在 macOS SwiftUI app 上配起来复杂，ncm 也没强依赖测试覆盖率；后续要加可单开 `ncm-mac-tests` SPM 仓库再 link。
- **强制刷新按钮的清理范围**：清 `local-index.json`（本地音乐扫描索引）、下载目录下的 `.part` 临时文件、登出账号（清 Keychain session）。**保留** `settings.json`（用户偏好）、`playback.json`（续播+播放计数）、`ncm.deviceId`（eapi 签名靠它，换了会让服务端判异常）、已下载的歌曲和歌词。

## 同步到 ncm 时的差异

- ncm 的 eapi host pool 三个（interface / interface3 / music）；这里一致。
- ncm 用 `request_id` 是 `str(int(time.time() * 1000))`；这里一致。
- ncm 的 `parseLRC` 跳过「作词/作曲/编曲」前缀；这里一致。
- ncm 的下载时间配额用了 `requests` 流式写 + `.part`；这里用 `URLSessionDownloadDelegate`。
- ncm 的 `localmusic.py` 用 `(mtime, size)` 缓存键；这里一致。
- ncm 的 `mediaserver` 不需要带过来。
- ncm 的 `bridge.py`（pywebview ↔ Python 桥接）不需要带过来。
- ncm 的 i18n（`zh_cn.json` + `en_us.json`）未来要补 `Localizable.strings`（en / zh-Hans），当前 AppLanguage 只暴露给设置，不挂字符串。