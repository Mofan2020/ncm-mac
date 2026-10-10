import Foundation
import SwiftUI
import Combine

/// 自动更新服务。直接调 GitHub Releases API，与 ncm / DeepSleep / TorSOCKS5 风格保持一致。
///
/// 行为：
///   - 拉 https://api.github.com/repos/Mofan2020/ncm-mac/releases?per_page=10
///   - 按设置里的 updateChannel（latest / prerelease）过滤
///   - 解析当前版本（Info.plist 的 CFBundleShortVersionString）
///   - 比较语义化版本（1.2.3），新版本高于当前时通过 ``state.updateAvailable`` 暴露
///   - UI 调用 ``openReleasePage()`` 跳到下载页（macOS 上未签名包由用户自行处理）
///
/// 设计：不引入 Sparkle / Squirrel 等；避免外部依赖；用户偏好。
@MainActor
final class UpdateService: ObservableObject {
    @Published private(set) var latest: ReleaseInfo?
    @Published private(set) var updateAvailable: Bool = false
    @Published private(set) var isChecking: Bool = false
    @Published private(set) var lastError: String?
    @Published private(set) var lastChecked: Date?

    /// GitHub 仓库（owner/repo）。
    static let repoOwner = "Mofan2020"
    static let repoName = "ncm-mac"

    /// 当前版本：先读 Info.plist；失败时返回 "0.0.0"（永远当作有可用更新）。
    static var currentVersion: String {
        let info = Bundle.main.infoDictionary
        return (info?["CFBundleShortVersionString"] as? String) ?? "0.0.0"
    }

    /// 启动时由 AppState 注入更新通道，避免循环依赖。
    var channel: UpdateChannel = .latest

    private var checkTask: Task<Void, Never>?

    init() {}

    // MARK: - Public API

    /// 主动触发一次检查。``silent=true`` 时不修改 lastError（用于启动后自动静默检查）。
    func check(silent: Bool = false) {
        checkTask?.cancel()
        isChecking = true
        if !silent { lastError = nil }
        checkTask = Task { [weak self] in
            guard let self else { return }
            defer { Task { @MainActor in self.isChecking = false } }
            do {
                let releases = try await self.fetchReleases()
                let eligible = releases.filter { rel in
                    self.channel == .prerelease ? true : !rel.isPrerelease
                }
                let currentVer = Self.currentVersion
                let newer = eligible.first { Self.compare($0.version, currentVer) > 0 }
                await MainActor.run {
                    self.latest = newer ?? eligible.first
                    self.updateAvailable = newer != nil
                    self.lastChecked = Date()
                }
            } catch {
                if !silent {
                    await MainActor.run { self.lastError = error.localizedDescription }
                }
            }
        }
    }

    /// 跳到 GitHub Release 页（用户在浏览器里手动下载）。
    func openReleasePage() {
        guard let url = latest?.htmlURL else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Networking

    private func fetchReleases() async throws -> [ReleaseInfo] {
        let urlString = "https://api.github.com/repos/\(Self.repoOwner)/\(Self.repoName)/releases?per_page=10"
        guard let url = URL(string: urlString) else { throw UpdateError.badURL }
        var req = URLRequest(url: url)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("ncm-mac", forHTTPHeaderField: "User-Agent")
        let (raw, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw UpdateError.http((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        let decoder = JSONDecoder()
        // GitHub API 字段是 snake_case（tag_name / html_url / published_at 等），
        // Swift Codable 不会自动转 camelCase。必须显式声明策略。
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        // published_at 形如 2024-01-15T12:34:56Z；带 fractional seconds 也要兼容。
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoNoFractional = ISO8601DateFormatter()
        isoNoFractional.formatOptions = [.withInternetDateTime]
        decoder.dateDecodingStrategy = .custom { dec in
            let str = try dec.singleValueContainer().decode(String.self)
            if let d = isoFormatter.date(from: str) { return d }
            if let d = isoNoFractional.date(from: str) { return d }
            throw DecodingError.dataCorruptedError(in: try dec.singleValueContainer(),
                                                   debugDescription: "Bad ISO8601 date: \(str)")
        }
        return try decoder.decode([ReleaseInfo].self, from: raw)
    }

    // MARK: - Version compare

    /// "v1.2.3" → 1.2.3；逐段数字比较，缺失段补 0；非数字段忽略。
    static func compare(_ lhs: String, _ rhs: String) -> Int {
        let l = numericSegments(lhs)
        let r = numericSegments(rhs)
        let n = max(l.count, r.count)
        for i in 0..<n {
            let a = i < l.count ? l[i] : 0
            let b = i < r.count ? r[i] : 0
            if a != b { return a < b ? -1 : 1 }
        }
        return 0
    }

    private static func numericSegments(_ s: String) -> [Int] {
        let stripped = s.hasPrefix("v") ? String(s.dropFirst()) : s
        let parts = stripped.split(separator: ".").map(String.init)
        return parts.compactMap { Int($0.filter { $0.isNumber }) }
    }
}

extension ReleaseInfo {
    /// 从 tagName 推导版本（去 v 前缀）。
    var version: String {
        hasPrefix(tagName, "v") ? String(tagName.dropFirst()) : tagName
    }

    private func hasPrefix(_ s: String, _ prefix: String) -> Bool {
        s.hasPrefix(prefix)
    }
}

enum UpdateError: LocalizedError {
    case badURL
    case http(Int)

    var errorDescription: String? {
        switch self {
        case .badURL: return "无效的更新地址"
        case .http(let code): return "GitHub 返回 HTTP \(code)"
        }
    }
}