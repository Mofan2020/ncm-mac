import Foundation
import SwiftUI
import Combine

/// 歌词服务。对应 ncm/src/core/lyrics.py。
///
/// 提供：
///   - 在线拉歌词并合并翻译
///   - 本地 LRC 文件读取（优先） / 兜底走在线
///   - 当前行匹配（按 ms）
///   - 序列化保存成 LRC（含双语）
@MainActor
final class LyricsService: ObservableObject {
    @Published private(set) var current: SongLyrics?
    @Published private(set) var isLoading: Bool = false
    @Published private(set) var lastError: String?

    private let api: NeteaseAPI
    private let settings: SettingsStore
    private var fetchTask: Task<Void, Never>?

    init(api: NeteaseAPI, settings: SettingsStore) {
        self.api = api
        self.settings = settings
    }

    /// 给定一首在线歌曲 + 它的本地文件 URL（若有），加载歌词。
    /// 优先读同目录 `.lrc`，否则调 eapi /song/lyric；并保存到本地（除非已有）。
    func loadLyrics(for song: Song, localAudioURL: URL? = nil) async {
        fetchTask?.cancel()
        isLoading = true
        lastError = nil
        let task = Task { [weak self] in
            guard let self else { return }
            defer { Task { @MainActor in self.isLoading = false } }
            do {
                if let localAudioURL = localAudioURL {
                    let lrcURL = localAudioURL.deletingPathExtension().appendingPathExtension("lrc")
                    if let cached = try? String(contentsOf: lrcURL, encoding: .utf8),
                       let parsed = Self.parse(content: cached) {
                        await MainActor.run {
                            self.current = SongLyrics(
                                songId: song.id, lines: parsed, hasTranslation: parsed.contains(where: { $0.translation != nil })
                            )
                        }
                        return
                    }
                }
                let lyrics = try await self.api.fetchLyrics(songId: song.id)
                if let localAudioURL = localAudioURL {
                    let lrcURL = localAudioURL.deletingPathExtension().appendingPathExtension("lrc")
                    let serialized = Self.serialize(lyrics)
                    if !FileManager.default.fileExists(atPath: lrcURL.path) {
                        try? serialized.write(to: lrcURL, atomically: true, encoding: .utf8)
                    }
                }
                await MainActor.run { self.current = lyrics }
            } catch {
                await MainActor.run {
                    self.lastError = error.localizedDescription
                    self.current = nil
                }
            }
        }
        fetchTask = task
        await task.value
    }

    /// 清空显示。
    func clear() {
        current = nil
        lastError = nil
    }

    /// 给定当前播放位置（秒），找最近的小于等于这个时间的那一行下标。
    /// 返回 -1 表示还没到第一行。
    func currentLineIndex(at seconds: TimeInterval) -> Int {
        guard let lines = current?.lines, !lines.isEmpty else { return -1 }
        let ms = Int(seconds * 1000)
        var best = -1
        for (i, line) in lines.enumerated() {
            if line.timeMs <= ms {
                best = i
            } else {
                break
            }
        }
        return best
    }

    // MARK: - LRC parsing

    /// 解析一份 LRC 文本。原歌词与翻译都识别（合并后调用方负责关联）。
    /// 这里只按时间戳切成行，返回所有 (timeMs, text) 对。
    static func parse(content: String) -> [LyricLine]? {
        let lines = Self.parseLRC(content)
        return lines.isEmpty ? nil : lines
    }

    /// 给定 SongLyrics，序列化成 LRC（含翻译行），用 [mm:ss.xx] 前缀。
    static func serialize(_ lyrics: SongLyrics) -> String {
        var out: [String] = []
        out.append("[ti:歌词]")
        for line in lyrics.lines {
            let t = formatTime(ms: line.timeMs)
            out.append("\(t)\(line.text)")
            if let tr = line.translation, !tr.isEmpty {
                out.append("\(t)\(tr)")
            }
        }
        return out.joined(separator: "\n")
    }

    static func formatTime(ms: Int) -> String {
        let m = ms / 60_000
        let s = (ms % 60_000) / 1000
        let cs = (ms % 1000) / 10
        return String(format: "[%02d:%02d.%02d]", m, s, cs)
    }

    static func parseLRC(_ text: String) -> [LyricLine] {
        guard !text.isEmpty else { return [] }
        var lines: [LyricLine] = []
        let pattern = #"\[(\d{2}):(\d{2})\.(\d{2,3})\](.*)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return []
        }
        for raw in text.components(separatedBy: .newlines) {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            let nsLine = trimmed as NSString
            let matches = regex.matches(in: trimmed, range: NSRange(location: 0, length: nsLine.length))
            for match in matches where match.numberOfRanges == 5 {
                let min = Int(nsLine.substring(with: match.range(at: 1))) ?? 0
                let sec = Int(nsLine.substring(with: match.range(at: 2))) ?? 0
                let fracRange = match.range(at: 3)
                let frac = Int(nsLine.substring(with: fracRange)) ?? 0
                let ms: Int = fracRange.length == 3 ? frac : frac * 10
                let textRange = match.range(at: 4)
                let lineText = nsLine.substring(with: textRange).trimmingCharacters(in: .whitespaces)
                // 跳过元数据
                if lineText.isEmpty
                    || lineText.hasPrefix("作词")
                    || lineText.hasPrefix("作曲")
                    || lineText.hasPrefix("编曲")
                    || lineText.hasPrefix("[") { // 防御性：保留 [ti:…] 之类
                    continue
                }
                let timeMs = min * 60_000 + sec * 1000 + ms
                lines.append(LyricLine(timeMs: timeMs, text: lineText, translation: nil))
            }
        }
        return lines.sorted { $0.timeMs < $1.timeMs }
    }
}