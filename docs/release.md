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

未做 Apple Developer 签名。Release notes 由 `softprops/action-gh-release` 自动生成。

## 校验

发版前本地必须：

1. `xcodegen generate && xcodebuild ... -configuration Debug build` 通过
2. eapi 签名 byte-level 校验：`/opt/anaconda3/envs/xijianBase/bin/python scripts/gen_test_vectors.py` 生成向量，再用独立 Swift 校验器（参考 `/tmp/ncm-mac-test/verify_crypto.swift`）跑断言；当前应有 10/10 通过
3. 真实启动一次：登录 → 拉一个公开歌单 → 选一首歌下载 → 播 → 看歌词
4. `Settings → Update → Check` 触发一次 Release 检查（确认 GitHub token / 网络可达）

CI 也会跑一次冒烟（启动 4s 后 kill），但正式版本产物需要在本地实跑确认 eapi 加密与播放 URL 能命中（CI 不知道用户的 Cookie）。