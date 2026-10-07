# 网易云音乐 macOS 客户端

SwiftUI 写的网易云音乐桌面客户端，专为 macOS 26+ 设计，目标平台 Apple Silicon 和 Intel 都覆盖。

![Platform](https://img.shields.io/badge/Platform-macOS%2026%2B-blue.svg)
![Swift](https://img.shields.io/badge/Swift-5.9-orange.svg)
![License](https://img.shields.io/badge/License-MIT-yellow.svg)

下载 + 播放 + 账号登录三件套在同一个窗口里。原生 AVPlayer 跑音频，原生 Keychain 存 cookie，原生 NSOpenPanel 选目录，没有 WebView。

## 功能

### 下载
- 粘贴歌单 ID 或链接拉曲目，>1000 首自动分批
- 五档音质：标准 / 较高 / 极高 / 无损 / Hi-Res，不可用时自动降级
- 1–3 路并发下载，进度条 + 速度
- 先写 `.part` 临时文件再原子改名，校验字节数后才算完成
- 失败任务独立列出，可单条重试
- 可选同时下载 `.lrc` 歌词

### 播放
- 在线 / 本地两种来源，在线切到本地优先可在设置里开
- 三种播放模式：列表循环 / 单曲循环 / 随机（真随机）
- 歌词面板：原文 + 翻译同步滚动高亮，本地优先读同目录 `.lrc`，否则从网易云拉并落盘
- 续播：退出时记下队列、当前曲目和位置
- 上一首 / 下一首 + 进度条 + 音量
- 播放次数本地计数，开关上报到云端

### 账号
- 扫码：拉 unikey → 展示二维码 → 轮询扫码状态
- 手机验证码（带国家码）
- 直接粘贴浏览器 cookie（MUSIC_U=…）
- 登录后 cookie 存到 Keychain，下次启动免登录

### 本地音乐
- 多个文件夹管理
- 扫描结果按 (mtime, size) 缓存到 `local-index.json`，下次启动只重读改过的文件
- 支持容器：mp3 / flac / m4a / aac / wav / ogg / opus / wma / ape / aiff / alac
- 元数据解析零依赖：自写 ID3v2、Vorbis comments、MP4 atoms 三套
- 嵌入封面 / 嵌入歌词按需拉，扫描时不读 payload

### 外观
- macOS 26 液态玻璃标题栏
- 浅色 / 深色 / 跟随系统三档
- 玻璃效果可关（老设备省 GPU）

### 自动更新
- 启动后可选静默检查 GitHub Releases
- 更新通道：正式版 / 预发布
- 在「设置 → 更新」里手动触发、查看 changelog、跳转下载页
- 不引入 Sparkle：直接用 GitHub Releases API + 版本号对比

## 下载安装

到 [Releases](https://github.com/Mofan2020/ncm-mac/releases/latest) 选对应架构的 zip：

| 机型 | 文件 |
|------|------|
| Apple Silicon (M 系列) | `NeteaseMusicDownloader-macOS-arm64.zip` |
| Intel | `NeteaseMusicDownloader-macOS-x64.zip` |

构建产物未做 Apple Developer 签名。首次打开请右键 → 打开，或在终端：

```bash
xattr -dr com.apple.quarantine /Applications/NeteaseMusicDownloader.app
```

## 从源码运行

需要 macOS 26+、Xcode 27（SDK 27）、Swift 5.9。

```bash
git clone https://github.com/Mofan2020/ncm-mac.git
cd ncm-mac
brew install xcodegen
xcodegen generate
open NeteaseMusicDownloader.xcodeproj
```

在 Xcode 里 ⌘R 跑。配置与缓存写在：

```
~/Library/Application Support/NeteaseMusicDownloader/
├── settings.json        # 业务设置（下载目录、音质、并发…）
├── playback.json        # 续播会话与本地播放次数
└── local-index.json     # 本地音乐扫描缓存
```

cookie 走 Keychain `service: com.mofan2020.neteasemusicdownloader.cookie`。

## 开发

代码按职责分三层：

```
Sources/
├── App/                 # 应用启动 + AppState 聚合
├── Models/              # 数据结构（Song、Playlist、AudioQuality…）
├── Services/            # 业务（API、下载、播放、歌词、本地音乐、自动更新…）
└── Views/               # SwiftUI 视图（5 个标签页 + 设置）
```

具体架构与设计取舍见 `docs/architecture.md`。

## License

MIT — 见 [LICENSE](LICENSE)。