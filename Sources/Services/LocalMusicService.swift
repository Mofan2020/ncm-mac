import Foundation
import AVFoundation
import SwiftUI
import Combine

/// 本地音乐服务。对应 ncm/src/core/localmusic.py。
///
/// 关键设计（沿用 Python 版的策略）：
///   - **零依赖**：纯 Swift 写 ID3v2（mp3）、Vorbis comments（flac/ogg）、MP4 atoms（m4a/mp4）
///     三个解析器。读不到的走文件名兜底 "Artist - Title"。
///   - 只读文件**头部**（前几 MB），不读音频 payload。
///   - Cover / 嵌入歌词 **不**在扫描时读，单独方法按需拉（lazy），避免大库 20k 文件吃内存。
///   - 扫描结果缓存到 local-index.json，按 (mtime, size) 增量更新。
@MainActor
final class LocalMusicService: ObservableObject {
    @Published private(set) var folders: [URL] = []
    @Published private(set) var tracks: [LocalTrack] = []
    @Published private(set) var isScanning: Bool = false
    @Published private(set) var lastError: String?

    static let supportedExtensions: Set<String> = [
        "mp3", "flac", "m4a", "aac", "wav", "ogg", "oga", "opus", "wma", "ape", "aiff", "aif", "alac",
    ]

    /// 单次扫描上限，防止误指巨型目录。
    static let maxFilesPerScan = 30_000
    static let maxDepth = 8

    private let settings: SettingsStore
    private let appSupport: URL

    init(settings: SettingsStore) {
        self.settings = settings
        let fm = FileManager.default
        let dir = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("NeteaseMusicDownloader", isDirectory: true)) ?? fm.temporaryDirectory
        self.appSupport = dir
        self.folders = settings.localMusicFolders
        loadIndexCache()
    }

    // MARK: - Folder management

    func addFolder(_ url: URL) {
        let resolved = url.resolvingSymlinksInPath()
        if !folders.contains(resolved) {
            folders.append(resolved)
            settings.localMusicFolders = folders
        }
    }

    func removeFolder(_ url: URL) {
        folders.removeAll { $0.path == url.path }
        settings.localMusicFolders = folders
        // 清掉来自该文件夹的索引
        tracks.removeAll { $0.url.path.hasPrefix(url.path) }
    }

    // MARK: - Scan

    /// 重新扫描所有配置的文件夹。已有 (mtime, size) 的文件跳过（用缓存）。
    func rescan() async {
        isScanning = true
        lastError = nil
        defer { isScanning = false }

        let cached = loadIndexRows()
        var newRows: [IndexRow] = []
        var collected: [LocalTrack] = []

        for folder in folders {
            let files = collectFiles(
                in: folder,
                supported: Self.supportedExtensions,
                maxDepth: Self.maxDepth
            )
            for fileURL in files.prefix(Self.maxFilesPerScan) {
                let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
                let size = (attrs?[.size] as? Int64) ?? 0
                let mtime = (attrs?[.modificationDate] as? Date) ?? Date()
                let key = cacheKey(url: fileURL)
                if let cachedRow = cached[key],
                   cachedRow.size == size,
                   abs(cachedRow.mtime.timeIntervalSince(mtime)) < 0.5 {
                    // 命中缓存
                    let track = LocalTrack(
                        url: fileURL,
                        title: cachedRow.title,
                        artist: cachedRow.artist,
                        album: cachedRow.album,
                        duration: cachedRow.duration
                    )
                    collected.append(track)
                    newRows.append(cachedRow)
                    continue
                }
                let meta = readMetadata(fileURL: fileURL)
                let duration = readDuration(fileURL: fileURL)
                let track = LocalTrack(
                    url: fileURL,
                    title: meta.title,
                    artist: meta.artist,
                    album: meta.album,
                    duration: duration
                )
                collected.append(track)
                newRows.append(IndexRow(
                    url: fileURL,
                    size: size,
                    mtime: mtime,
                    title: meta.title,
                    artist: meta.artist,
                    album: meta.album,
                    duration: duration
                ))
            }
        }
        self.tracks = collected.sorted { $0.title.localizedCompare($1.title) == .orderedAscending }
        saveIndexRows(newRows)
    }

    /// 清空全部曲目记录（不会动磁盘文件）。
    func clearAll() {
        tracks.removeAll()
        try? FileManager.default.removeItem(at: indexURL)
    }

    // MARK: - Cover / Lyrics

    /// 读嵌入封面（如果有）。仅在用户播放时按需调用。
    func readCover(for url: URL) -> Data? {
        switch url.pathExtension.lowercased() {
        case "mp3": return ID3v2Parser.readCover(from: url)
        case "flac", "ogg", "oga", "opus": return VorbisParser.readCover(from: url)
        case "m4a", "mp4", "aac", "alac": return MP4Parser.readCover(from: url)
        default: return nil
        }
    }

    /// 同目录 .lrc 歌词（如果有）。
    func readSidecarLyrics(for url: URL) -> String? {
        let lrcURL = url.deletingPathExtension().appendingPathExtension("lrc")
        return try? String(contentsOf: lrcURL, encoding: .utf8)
    }

    /// 嵌入歌词（USLT for ID3, LYRICS for Vorbis, ©lyr for MP4）。
    func readEmbeddedLyrics(for url: URL) -> String? {
        switch url.pathExtension.lowercased() {
        case "mp3": return ID3v2Parser.readEmbeddedLyrics(from: url)
        case "flac", "ogg", "oga", "opus": return VorbisParser.readEmbeddedLyrics(from: url)
        case "m4a", "mp4", "aac", "alac": return MP4Parser.readEmbeddedLyrics(from: url)
        default: return nil
        }
    }

    // MARK: - Local music priority

    /// 把在线歌单 + 当前本地曲库合并：若 ``settings.preferredLocalPlay == true``，把本地已有的同名曲替换在线版。
    static func applyLocalPriority(to remote: [Song], local: [LocalTrack], preferredLocal: Bool) -> [Song] {
        guard preferredLocal else { return remote }
        var out: [Song] = []
        for song in remote {
            if let match = local.first(where: { sameSong($0, song) }) {
                // 用本地版本：替换 URL 为 file://
                let localSong = Song(
                    id: song.id,
                    name: song.name,
                    artists: song.artists,
                    album: song.album,
                    duration: Int(match.duration),
                    coverURL: song.coverURL,
                    source: .local
                )
                out.append(localSong)
            } else {
                out.append(song)
            }
        }
        return out
    }

    private static func sameSong(_ local: LocalTrack, _ remote: Song) -> Bool {
        if local.title.localizedCaseInsensitiveCompare(remote.name) != .orderedSame { return false }
        if remote.artists.isEmpty { return true }
        return local.artist.localizedCaseInsensitiveCompare(remote.artists.first?.name ?? "") == .orderedSame ||
               local.artist.isEmpty
    }

    // MARK: - Index cache

    private var indexURL: URL { appSupport.appendingPathComponent("local-index.json") }

    private struct IndexRow: Codable {
        let url: URL
        let size: Int64
        let mtime: Date
        let title: String
        let artist: String
        let album: String
        let duration: TimeInterval
    }

    private func cacheKey(url: URL) -> String { url.path }

    private func loadIndexRows() -> [String: IndexRow] {
        guard let data = try? Data(contentsOf: indexURL),
              let rows = try? JSONDecoder().decode([IndexRow].self, from: data) else {
            return [:]
        }
        var out: [String: IndexRow] = [:]
        for r in rows { out[cacheKey(url: r.url)] = r }
        return out
    }

    private func saveIndexRows(_ rows: [IndexRow]) {
        do {
            let data = try JSONEncoder().encode(rows)
            try data.write(to: indexURL, options: .atomic)
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func loadIndexCache() {
        let cached = loadIndexRows()
        self.tracks = cached.values.map {
            LocalTrack(
                url: $0.url,
                title: $0.title,
                artist: $0.artist,
                album: $0.album,
                duration: $0.duration
            )
        }.sorted { $0.title.localizedCompare($1.title) == .orderedAscending }
    }
}

// MARK: - Helpers

func readMetadata(fileURL: URL) -> (title: String, artist: String, album: String) {
    switch fileURL.pathExtension.lowercased() {
    case "mp3":
        return ID3v2Parser.readMetadata(from: fileURL) ?? parseFromFilename(fileURL)
    case "flac", "ogg", "oga", "opus":
        return VorbisParser.readMetadata(from: fileURL) ?? parseFromFilename(fileURL)
    case "m4a", "mp4", "aac", "alac":
        return MP4Parser.readMetadata(from: fileURL) ?? parseFromFilename(fileURL)
    default:
        return parseFromFilename(fileURL)
    }
}

func readDuration(fileURL: URL) -> TimeInterval {
    let asset = AVURLAsset(url: fileURL)
    let dur = CMTimeGetSeconds(asset.duration)
    return dur.isFinite ? dur : 0
}

private func parseFromFilename(_ url: URL) -> (title: String, artist: String, album: String) {
    let stem = url.deletingPathExtension().lastPathComponent
    let separators = [" - ", " – ", " — ", "－", "_-_"]
    var cleaned = stem
    // 去掉前导 "01 - " 之类的轨道号
    if let regex = try? NSRegularExpression(pattern: #"^\s*(?:cd\s*)?\d{1,3}\s*[-.、_)\]]\s*"#) {
        let range = NSRange(location: 0, length: (cleaned as NSString).length)
        cleaned = regex.stringByReplacingMatches(in: cleaned, range: range, withTemplate: "")
    }
    for sep in separators {
        if cleaned.contains(sep) {
            let parts = cleaned.components(separatedBy: sep)
            if parts.count >= 2 {
                let artist = parts[0].trimmingCharacters(in: .whitespaces)
                let title = parts.dropFirst().joined(separator: sep).trimmingCharacters(in: .whitespaces)
                if !artist.isEmpty && !title.isEmpty {
                    return (title: title, artist: artist, album: "")
                }
            }
        }
    }
    return (title: cleaned, artist: "", album: "")
}

private func collectFiles(in root: URL, supported: Set<String>, maxDepth: Int) -> [URL] {
    var out: [URL] = []
    let fm = FileManager.default
    guard let enumerator = fm.enumerator(
        at: root,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles]
    ) else { return [] }
    for case let url as URL in enumerator {
        // 深度限制
        let depth = url.pathComponents.count - root.pathComponents.count
        if depth > maxDepth { continue }
        guard let isFile = try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile, isFile else { continue }
        if supported.contains(url.pathExtension.lowercased()) {
            out.append(url)
        }
    }
    return out
}

// MARK: - ID3v2 parser (mp3)

enum ID3v2Parser {
    static func readMetadata(from url: URL) -> (title: String, artist: String, album: String)? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        guard data.count > 10 else { return nil }
        guard data[0] == 0x49, data[1] == 0x44, data[2] == 0x33 else { return nil } // "ID3"
        let version = data[3]
        let flags = data[5]
        // 同步安全大小：每字节 7 bit
        let size = (Int(data[6]) << 21) | (Int(data[7]) << 14) | (Int(data[8]) << 7) | Int(data[9])
        let tagStart = 10
        let tagEnd = min(tagStart + size, data.count)
        guard tagEnd > tagStart else { return nil }
        var title = ""
        var artist = ""
        var album = ""
        var pos = tagStart
        while pos + 10 <= tagEnd {
            let id = String(bytes: data[pos..<pos+4], encoding: .ascii) ?? ""
            if id.first == "\0" { break }
            let frameSize = (Int(data[pos+4]) << 24) | (Int(data[pos+5]) << 16) | (Int(data[pos+6]) << 8) | Int(data[pos+7])
            pos += 10
            if version >= 4 { _ = flags } // 暂略
            guard pos + frameSize <= tagEnd, frameSize > 0 else { break }
            let frame = data[pos..<pos+frameSize]
            let text = decodeText(frame) ?? ""
            switch id {
            case "TIT2": title = text
            case "TPE1": artist = text
            case "TALB": album = text
            default: break
            }
            pos += frameSize
        }
        if title.isEmpty && artist.isEmpty && album.isEmpty { return nil }
        return (title, artist, album)
    }

    static func readCover(from url: URL) -> Data? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        guard data.count > 10 else { return nil }
        guard data[0] == 0x49, data[1] == 0x44, data[2] == 0x33 else { return nil }
        let size = (Int(data[6]) << 21) | (Int(data[7]) << 14) | (Int(data[8]) << 7) | Int(data[9])
        let tagStart = 10
        let tagEnd = min(tagStart + size, data.count)
        var pos = tagStart
        while pos + 10 <= tagEnd {
            let id = String(bytes: data[pos..<pos+4], encoding: .ascii) ?? ""
            if id.first == "\0" { break }
            let frameSize = (Int(data[pos+4]) << 24) | (Int(data[pos+5]) << 16) | (Int(data[pos+6]) << 8) | Int(data[pos+7])
            pos += 10
            guard pos + frameSize <= tagEnd, frameSize > 0 else { break }
            if id == "APIC" {
                let frame = data[pos..<pos+frameSize]
                // APIC: encoding (1) + mime (null-terminated) + pic type (1) + data
                guard frame.count > 4 else { break }
                var idx = frame.startIndex + 1 // skip encoding
                // skip mime null-terminated
                while idx < frame.endIndex, frame[idx] != 0 { idx += 1 }
                idx += 1
                guard idx < frame.endIndex else { break }
                idx += 1 // pic type
                return Data(frame[idx..<frame.endIndex])
            }
            pos += frameSize
        }
        return nil
    }

    static func readEmbeddedLyrics(from url: URL) -> String? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        guard data.count > 10 else { return nil }
        guard data[0] == 0x49, data[1] == 0x44, data[2] == 0x33 else { return nil }
        let size = (Int(data[6]) << 21) | (Int(data[7]) << 14) | (Int(data[8]) << 7) | Int(data[9])
        let tagStart = 10
        let tagEnd = min(tagStart + size, data.count)
        var pos = tagStart
        while pos + 10 <= tagEnd {
            let id = String(bytes: data[pos..<pos+4], encoding: .ascii) ?? ""
            if id.first == "\0" { break }
            let frameSize = (Int(data[pos+4]) << 24) | (Int(data[pos+5]) << 16) | (Int(data[pos+6]) << 8) | Int(data[pos+7])
            pos += 10
            guard pos + frameSize <= tagEnd, frameSize > 0 else { break }
            if id == "USLT" {
                let frame = data[pos..<pos+frameSize]
                let text = decodeText(frame, skipLeading: 4) ?? ""
                return text
            }
            pos += frameSize
        }
        return nil
    }

    private static func decodeText(_ data: Data, skipLeading: Int = 1) -> String? {
        guard !data.isEmpty else { return nil }
        var idx = data.startIndex + skipLeading
        guard idx < data.endIndex else { return nil }
        let encoding = data[data.startIndex]
        let body = data[idx..<data.endIndex]
        switch encoding {
        case 0x00: // ISO-8859-1
            return String(bytes: body, encoding: .isoLatin1)
        case 0x01: // UTF-16 with BOM
            if body.count >= 2 {
                let b0 = body[body.startIndex]
                let b1 = body[body.startIndex + 1]
                if b0 == 0xFF && b1 == 0xFE {
                    return String(data: Data(body.dropFirst(2)), encoding: .utf16LittleEndian)
                } else if b0 == 0xFE && b1 == 0xFF {
                    return String(data: Data(body.dropFirst(2)), encoding: .utf16BigEndian)
                }
            }
            return String(data: body, encoding: .utf16)
        case 0x02: // UTF-16BE
            return String(data: body, encoding: .utf16BigEndian)
        case 0x03: // UTF-8
            return String(data: body, encoding: .utf8)
        default:
            return String(data: body, encoding: .utf8)
        }
    }
}

// MARK: - Vorbis comments (flac / ogg)

enum VorbisParser {
    static func readMetadata(from url: URL) -> (title: String, artist: String, album: String)? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        let ext = url.pathExtension.lowercased()
        if ext == "flac" {
            return parseFLAC(data)
        } else {
            return parseOgg(data)
        }
    }

    static func readCover(from url: URL) -> Data? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        let ext = url.pathExtension.lowercased()
        let blocks: [VorbisBlock]
        if ext == "flac" {
            blocks = parseFLACBlocks(data)
        } else {
            blocks = parseOggBlocks(data)
        }
        for b in blocks {
            if b.type == 6 { // PICTURE
                return parseVorbisPicture(b.payload)
            }
        }
        return nil
    }

    static func readEmbeddedLyrics(from url: URL) -> String? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        let ext = url.pathExtension.lowercased()
        let blocks: [VorbisBlock]
        if ext == "flac" {
            blocks = parseFLACBlocks(data)
        } else {
            blocks = parseOggBlocks(data)
        }
        for b in blocks {
            if b.type == 4 { // COMMENT
                return parseVorbisCommentValue(b.payload, key: "LYRICS")
            }
        }
        return nil
    }

    private struct VorbisBlock { let type: UInt8; let payload: Data }

    // FLAC: "fLaC" + METADATA blocks (1 byte type + 3 byte size BE + payload)
    private static func parseFLACBlocks(_ data: Data) -> [VorbisBlock] {
        guard data.count > 4, data[0] == 0x66, data[1] == 0x4C, data[2] == 0x61, data[3] == 0x43 else {
            return []
        }
        var out: [VorbisBlock] = []
        var pos = 4
        while pos + 4 <= data.count {
            let type = data[pos]
            let size = (Int(data[pos+1]) << 16) | (Int(data[pos+2]) << 8) | Int(data[pos+3])
            pos += 4
            if type & 0x80 != 0 { break } // last-metadata-block flag
            guard pos + size <= data.count, size > 0 else { break }
            out.append(VorbisBlock(type: type, payload: data.subdata(in: pos..<pos+size)))
            pos += size
        }
        return out
    }

    private static func parseFLAC(_ data: Data) -> (title: String, artist: String, album: String)? {
        let blocks = parseFLACBlocks(data)
        for b in blocks where b.type == 4 {
            let title = parseVorbisCommentValue(b.payload, key: "TITLE") ?? ""
            let artist = parseVorbisCommentValue(b.payload, key: "ARTIST") ?? ""
            let album = parseVorbisCommentValue(b.payload, key: "ALBUM") ?? ""
            if title.isEmpty && artist.isEmpty && album.isEmpty { return nil }
            return (title, artist, album)
        }
        return nil
    }

    // Ogg: pages with vorbis comment header. 简化：跳过 79 bytes 抓包头，看 vendor + comments。
    private static func parseOggBlocks(_ data: Data) -> [VorbisBlock] {
        // 简化为：识别首页的 comment header (type 3)，后面 OGG 物理帧多页我们不再展开。
        // 直接搜索 vorbis comment 头："\x03vorbis"
        let sig = Data([0x03]) + "vorbis".data(using: .ascii)!
        guard let range = data.range(of: sig) else { return [] }
        let payload = data.subdata(in: range.upperBound..<min(data.count, range.upperBound + 64 * 1024))
        return [VorbisBlock(type: 4, payload: payload)]
    }

    private static func parseOgg(_ data: Data) -> (title: String, artist: String, album: String)? {
        let blocks = parseOggBlocks(data)
        guard let b = blocks.first else { return nil }
        let title = parseVorbisCommentValue(b.payload, key: "TITLE") ?? ""
        let artist = parseVorbisCommentValue(b.payload, key: "ARTIST") ?? ""
        let album = parseVorbisCommentValue(b.payload, key: "ALBUM") ?? ""
        if title.isEmpty && artist.isEmpty && album.isEmpty { return nil }
        return (title, artist, album)
    }

    /// Vorbis comment 字段：vendor length (LE u32) + vendor + count (LE u32) + entries (length LE u32 + "KEY=value" UTF-8)
    static func parseVorbisCommentValue(_ data: Data, key: String) -> String? {
        guard data.count >= 8 else { return nil }
        var cursor = 0
        let vendorLen = Int(readUInt32LE(data, at: cursor))
        cursor += 4
        cursor += vendorLen
        guard cursor + 4 <= data.count else { return nil }
        let count = Int(readUInt32LE(data, at: cursor))
        cursor += 4
        let needle = (key + "=").data(using: .utf8) ?? Data()
        for _ in 0..<count {
            guard cursor + 4 <= data.count else { break }
            let entryLen = Int(readUInt32LE(data, at: cursor))
            cursor += 4
            guard cursor + entryLen <= data.count else { break }
            let entry = data.subdata(in: cursor..<cursor+entryLen)
            if entry.starts(with: needle) {
                let value = entry.dropFirst(needle.count)
                return String(data: value, encoding: .utf8)
            }
            cursor += entryLen
        }
        return nil
    }

    private static func readUInt32LE(_ data: Data, at offset: Int) -> UInt32 {
        UInt32(data[offset]) | (UInt32(data[offset+1]) << 8) | (UInt32(data[offset+2]) << 16) | (UInt32(data[offset+3]) << 24)
    }

    /// Vorbis picture block（FLAC PICTURE 块）。
    static func parseVorbisPicture(_ data: Data) -> Data? {
        // 类型 (4) + mime len (LE u32) + mime + desc len (LE u32) + desc + ...
        guard data.count >= 4 + 4 else { return nil }
        var cursor = 4 // type
        let mimeLen = Int(readUInt32LE(data, at: cursor))
        cursor += 4 + mimeLen
        guard cursor + 4 <= data.count else { return nil }
        let descLen = Int(readUInt32LE(data, at: cursor))
        cursor += 4 + descLen
        cursor += 4 * 4 // width, height, depth, indexed
        cursor += 4 // pic data length
        guard cursor + 4 <= data.count else { return nil }
        let picLen = Int(readUInt32LE(data, at: cursor))
        cursor += 4
        guard cursor + picLen <= data.count else { return nil }
        return data.subdata(in: cursor..<cursor+picLen)
    }
}

// MARK: - MP4 (m4a / mp4) atoms

enum MP4Parser {
    static func readMetadata(from url: URL) -> (title: String, artist: String, album: String)? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        var title = ""
        var artist = ""
        var album = ""
        walk(data: data, offset: 0, end: data.count) { atomType, payload in
            switch atomType {
            case "©nam": title = readString(payload) ?? title
            case "©ART": artist = readString(payload) ?? artist
            case "©alb": album = readString(payload) ?? album
            case "ilst":
                // ilst 内层是 data atom
                walk(data: payload, offset: 0, end: payload.count) { innerType, innerPayload in
                    if innerType == "data" {
                        // data: type (4) + locale (4) + value
                        guard innerPayload.count >= 8 else { return }
                        let valueType = readUInt32BE(innerPayload, at: 0)
                        let value = innerPayload.subdata(in: 8..<innerPayload.count)
                        if valueType == 1 {
                            let s = String(data: value, encoding: .utf8) ?? ""
                            // 需要外层 ilst 的 key 才知道是 title / artist / album；这里简化：靠 caller 调用 getMetadata
                            _ = s
                        }
                    }
                }
            default: break
            }
        }
        // 上面内层 mapping 留空；改用另一种方式：遍历 ilst 内每个子 atom。
        // 由于 nested walk 复杂，简化为二次扫描：
        if title.isEmpty { title = scanMP4IlstKey(data, key: "©nam") ?? "" }
        if artist.isEmpty { artist = scanMP4IlstKey(data, key: "©ART") ?? "" }
        if album.isEmpty { album = scanMP4IlstKey(data, key: "©alb") ?? "" }
        if title.isEmpty && artist.isEmpty && album.isEmpty { return nil }
        return (title, artist, album)
    }

    private static func scanMP4IlstKey(_ data: Data, key: String) -> String? {
        var result: String?
        walk(data: data, offset: 0, end: data.count) { atomType, payload in
            guard atomType == "ilst" else { return }
            walk(data: payload, offset: 0, end: payload.count) { childType, childPayload in
                guard childType == key else { return }
                walk(data: childPayload, offset: 0, end: childPayload.count) { grandType, grandPayload in
                    guard grandType == "data" else { return }
                    guard grandPayload.count >= 8 else { return }
                    let valueType = readUInt32BE(grandPayload, at: 0)
                    let value = grandPayload.subdata(in: 8..<grandPayload.count)
                    if valueType == 1 {
                        result = String(data: value, encoding: .utf8)
                    }
                }
            }
        }
        return result
    }

    static func readCover(from url: URL) -> Data? {
        guard let raw = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        var cover: Data?
        walk(data: raw, offset: 0, end: raw.count) { atomType, payload in
            guard atomType == "ilst" else { return }
            walk(data: payload, offset: 0, end: payload.count) { childType, childPayload in
                guard childType == "covr" else { return }
                walk(data: childPayload, offset: 0, end: childPayload.count) { grandType, grandPayload in
                    guard grandType == "data" else { return }
                    guard grandPayload.count >= 8 else { return }
                    cover = grandPayload.subdata(in: 8..<grandPayload.count)
                }
            }
        }
        return cover
    }

    static func readEmbeddedLyrics(from url: URL) -> String? {
        guard let raw = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        var lyrics: String?
        walk(data: raw, offset: 0, end: raw.count) { atomType, payload in
            guard atomType == "ilst" else { return }
            walk(data: payload, offset: 0, end: payload.count) { childType, childPayload in
                guard childType == "©lyr" else { return }
                walk(data: childPayload, offset: 0, end: childPayload.count) { grandType, grandPayload in
                    guard grandType == "data" else { return }
                    guard grandPayload.count >= 8 else { return }
                    lyrics = String(data: grandPayload.subdata(in: 8..<grandPayload.count), encoding: .utf8)
                }
            }
        }
        return lyrics
    }

    private static func readString(_ data: Data) -> String? {
        String(data: data, encoding: .utf8)?.trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
    }

    private static func readUInt32BE(_ data: Data, at offset: Int) -> UInt32 {
        UInt32(data[offset]) << 24 | UInt32(data[offset+1]) << 16 | UInt32(data[offset+2]) << 8 | UInt32(data[offset+3])
    }

    /// 递归走 MP4 atom 结构。每个 atom: size (4) + type (4) + payload。
    private static func walk(
        data: Data,
        offset: Int,
        end: Int,
        visit: (_ type: String, _ payload: Data) -> Void
    ) {
        var pos = offset
        while pos + 8 <= end {
            let size = Int(readUInt32BE(data, at: pos))
            let typeRange = (pos + 4)..<(pos + 8)
            let type = String(data: data.subdata(in: typeRange), encoding: .ascii) ?? ""
            if size < 8 { break }
            let payloadRange = (pos + 8)..<min(pos + size, end)
            visit(type, data.subdata(in: payloadRange))
            // container 递归
            if ["moov", "udta", "meta", "ilst"].contains(type) {
                walk(data: data, offset: payloadRange.lowerBound, end: payloadRange.upperBound, visit: visit)
            }
            pos += size
        }
    }
}