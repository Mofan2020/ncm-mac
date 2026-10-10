# Release

## 流程

```bash
# 1. 改完代码、build 绿、自测过
xcodegen generate
xcodebuild -project NeteaseMusicDownloader.xcodeproj \
  -scheme NeteaseMusicDownloader -configuration Debug \
  -destination 'platform=macOS' build

# 2. 在 Xcode 里手动测一遍：登录 → 下载 → 播放 → 设置
#    （自动更新用 Settings → Update → Check 触发一次）

# 3. 升 version（不要自动改，本项目偏好手动 bump）
#    编辑 project.yml 的 MARKETING_VERSION（与 Info.plist 的 CFBundleShortVersionString 对齐）

# 4. commit
git add -A
git commit -m "release: vX.Y.Z"

# 5. push tag（触发 macOS workflow 发 Release）
git push origin main
git tag vX.Y.Z
git push origin vX.Y.Z
```

`main` 分支 push 也会跑 build job（不上传 release，仅验证 build）。tag push 才触发 release job。

## CI workflow

`.github/workflows/macos.yml`：

- 矩阵：macos-26 runner × {arm64, x86_64}
- 步骤：brew install xcodegen → xcodegen generate → xcodebuild Debug（冒烟）→ xcodebuild Release → `ditto` 打包 → zip → self-test（启动后 kill）→ upload artifact
- tag 触发：把两份 zip 上传为 GitHub Release 资产（用 softprops/action-gh-release）
- 降级：若 macos-26 不可用，把矩阵里 `runner: macos-26` 改成 `runner: macos-15`，SDK 26 在 macos-15 runner 上也能 build（Xcode 27 已支持）

## 构建产物

每个架构生成：

```
NeteaseMusicDownloader-macOS-arm64.zip
└── NeteaseMusicDownloader.app/
NeteaseMusicDownloader-macOS-x64.zip
└── NeteaseMusicDownloader.app/
```

未做 Apple Developer 签名。Release notes 由 `softprops/action-gh-release` 自动生成。workflow 跑完立刻用 `gh release edit <tag> --prerelease` 标 Pre-release（见下方规则）。

## 发版规则（硬性）

> 没经用户实测确认的版本只能做 Pre-release，不可作为正式版。

`softprops/action-gh-release` 默认创建正式版，但本项目规则是**没经用户手测 → 必须 Pre-release**。流程：

1. commit + push 修复 → CI 跑过 → `project.yml` 改 `MARKETING_VERSION` + commit + push main
2. `git tag vX.Y.Z && git push origin vX.Y.Z` 触发 release workflow
3. **workflow 创建 release 后立刻** `gh release edit vX.Y.Z --prerelease`（CI 推送 release 资产后第一时间）
4. 通知用户去测，等用户回复"通过"
5. 用户确认后 `gh release edit vX.Y.Z --prerelease=false` 升正式版

如果实测发现新 bug，按 `bump version` 走下一个小版本（v1.0.0 → v1.0.1 → v1.0.2 ...），不要复用已发布的 tag。

## 版本日志

- **v1.0.3 (Pre-release)** — 修复设置跳 tab + 语言切换 + 检查更新 snake_case
- **v1.0.2 (Pre-release)** — 修复 4 个 UI 残 bug + 强制刷新全部缓存按钮
- **v1.0.1 (Pre-release)** — 修复扫码登录 + 设置页 5 个 UI 问题
- **v1.0.0** — 首版

## 校验

发版前本地必须：

1. `xcodegen generate && xcodebuild ... -configuration Debug build` 通过
2. eapi 签名 byte-level 校验：`/opt/anaconda3/envs/xijianBase/bin/python scripts/gen_test_vectors.py` 生成向量，再用独立 Swift 校验器（参考 `/tmp/ncm-mac-test/verify_crypto.swift`）跑断言；当前应有 10/10 通过
3. 真实启动一次：登录 → 拉一个公开歌单 → 选一首歌下载 → 播 → 看歌词
4. `Settings → Update → Check` 触发一次 Release 检查（确认 GitHub token / 网络可达）

CI 也会跑一次冒烟（启动 4s 后 kill），但正式版本产物需要在本地实跑确认 eapi 加密与播放 URL 能命中（CI 不知道用户的 Cookie）。