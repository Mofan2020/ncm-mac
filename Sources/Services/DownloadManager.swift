import Foundation
import SwiftUI
import Combine
import CryptoKit

/// 并发下载管理器。对应 ncm/src/core/downloader.py。
///
/// 关键设计：
///   - 默认并发数 1-3（设置可调），用 Swift TaskGroup 实现
///   - 写入流程：先写 ``.part`` 临时文件，校验字节数 = size 后原子 rename
///   - 单曲失败不阻塞其他；失败的歌曲列入 ``failedTasks`` 让 UI 单独展示
///   - 暂停 / 取消：URLSession 的下载任务是 async 的，暂停对应 ``cancel(byProducingResumeData:)``
///     （ncm 在 Python 端是直接读 bytes 然后写 .part，Swift 这边换 URLSession 真分块下载）
@MainActor
final class DownloadManager: NSObject, ObservableObject {
    @Published private(set) var tasks: [DownloadTask] = []
    @Published private(set) var runningCount: Int = 0
    @Published private(set) var failedTasks: [DownloadTask] = []

    private let api: NeteaseAPI
    private let settings: SettingsStore
    private let library: LibraryStore
    private var inFlight: [UUID: URLSessionDownloadTask] = [:]
    private var inFlightResumes: [UUID: Data] = [:]
    private var session: URLSession!
    private let maxConcurrent: Int

    init(api: NeteaseAPI, library: LibraryStore, settings: SettingsStore) {
        self.api = api
        self.library = library
        self.settings = settings
        self.maxConcurrent = max(1, min(3, settings.concurrentDownloads))
        super.init()
        let config = URLSessionConfiguration.default
        config.httpMaximumConnectionsPerHost = 3
        config.waitsForConnectivity = true
        self.session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    // MARK: - Public API

    /// 添加一个下载任务（默认加入队列，立即尝试启动）。
    func enqueue(_ task: DownloadTask) {
        tasks.append(task)
        scheduleNext()
    }

    /// 批量入队（用于「下载当前歌单全部」）。
    func enqueueAll(_ newTasks: [DownloadTask]) {
        tasks.append(contentsOf: newTasks)
        scheduleNext()
    }

    func cancel(taskId: UUID) {
        if let inFlightTask = inFlight[taskId] {
            inFlightTask.cancel()
            inFlight.removeValue(forKey: taskId)
            inFlightResumes.removeValue(forKey: taskId)
        }
        if let idx = tasks.firstIndex(where: { $0.id == taskId }) {
            tasks[idx].status = .cancelled
        }
        scheduleNext()
    }

    func retry(taskId: UUID) {
        guard let idx = tasks.firstIndex(where: { $0.id == taskId }) else { return }
        tasks[idx].status = .queued
        tasks[idx].bytesDownloaded = 0
        tasks[idx].totalBytes = 0
        failedTasks.removeAll(where: { $0.id == taskId })
        scheduleNext()
    }

    /// 清空已完成任务。
    func clearFinished() {
        tasks.removeAll(where: {
            if case .finished = $0.status { return true }
            if case .cancelled = $0.status { return true }
            if case .failed = $0.status { return true }
            return false
        })
        failedTasks.removeAll()
    }

    func refreshQualityAvailability() {
        // 触发器：账号变化时调用，目前只需刷新任务列表即可（占位）
    }

    // MARK: - Scheduling

    private func scheduleNext() {
        while runningCount < maxConcurrent,
              let idx = tasks.firstIndex(where: { $0.status == .queued }) {
            let task = tasks[idx]
            tasks[idx].status = .downloading(progress: 0, speed: 0)
            startDownload(task: task)
        }
    }

    private func startDownload(task: DownloadTask) {
        runningCount += 1
        Task { [weak self] in
            guard let self else { return }
            do {
                // 1. 取播放 URL
                guard let songURL = try await self.api.fetchSongURL(songId: task.song.id, quality: task.quality) else {
                    throw DownloadError.unavailable(task.song.id)
                }
                guard let taskIdx = await self.taskIndex(id: task.id) else { return }
                self.tasks[taskIdx].totalBytes = songURL.size
                // 2. 启动 URLSession 真分块下载
                var request = URLRequest(url: songURL.url)
                request.setValue(self.api.cookie, forHTTPHeaderField: "Cookie")
                let downloadTask = self.session.downloadTask(with: request)
                self.inFlight[task.id] = downloadTask
                downloadTask.taskDescription = task.id.uuidString
                downloadTask.resume()
            } catch {
                await self.markFailed(taskId: task.id, error: error)
            }
        }
    }

    private func taskIndex(id: UUID) async -> Int? {
        tasks.firstIndex(where: { $0.id == id })
    }

    private func markFailed(taskId: UUID, error: Error) {
        if let idx = tasks.firstIndex(where: { $0.id == taskId }) {
            let t = tasks[idx]
            tasks[idx].status = .failed(message: error.localizedDescription)
            failedTasks.append(t)
        }
        runningCount = max(0, runningCount - 1)
        scheduleNext()
    }

    private func markFinished(taskId: UUID, fileURL: URL) {
        if let idx = tasks.firstIndex(where: { $0.id == taskId }) {
            tasks[idx].status = .finished(url: fileURL)
        }
        inFlight.removeValue(forKey: taskId)
        inFlightResumes.removeValue(forKey: taskId)
        runningCount = max(0, runningCount - 1)
        scheduleNext()
    }

    private func markProgress(taskId: UUID, written: Int64, total: Int64, speed: Double) {
        if let idx = tasks.firstIndex(where: { $0.id == taskId }) {
            tasks[idx].bytesDownloaded = written
            tasks[idx].totalBytes = total
            tasks[idx].status = .downloading(progress: Double(written) / Double(max(total, 1)), speed: speed)
        }
    }
}

// MARK: - URLSessionDownloadDelegate

extension DownloadManager: URLSessionDownloadDelegate {
    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let taskIdString = downloadTask.taskDescription,
              let taskId = UUID(uuidString: taskIdString) else {
            return
        }
        // 在 delegate 回调里必须立刻把文件挪到稳定位置（系统会清临时位置）。
        Task { @MainActor in
            guard let taskIdx = self.tasks.firstIndex(where: { $0.id == taskId }) else { return }
            let task = self.tasks[taskIdx]
            let partURL = task.url.appendingPathExtension("part")
            do {
                let fm = FileManager.default
                try fm.createDirectory(at: task.url.deletingLastPathComponent(), withIntermediateDirectories: true)
                if fm.fileExists(atPath: task.url.path) {
                    if self.settings.overwriteExisting {
                        try fm.removeItem(at: task.url)
                    } else {
                        try fm.removeItem(at: partURL)
                        self.markFinished(taskId: task.id, fileURL: task.url)
                        return
                    }
                }
                try fm.moveItem(at: location, to: partURL)
                // 校验大小
                let attrs = try fm.attributesOfItem(atPath: partURL.path)
                let size = (attrs[.size] as? Int64) ?? 0
                if task.totalBytes > 0 && size != task.totalBytes {
                    try? fm.removeItem(at: partURL)
                    self.markFailed(taskId: task.id, error: DownloadError.sizeMismatch(expected: task.totalBytes, actual: size))
                    return
                }
                try fm.moveItem(at: partURL, to: task.url)
                self.markFinished(taskId: task.id, fileURL: task.url)
                // 下载歌词（可选）
                if self.settings.downloadLyrics {
                    Task { await self.fetchLyrics(for: task) }
                }
            } catch {
                self.markFailed(taskId: task.id, error: error)
            }
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard let taskIdString = downloadTask.taskDescription,
              let taskId = UUID(uuidString: taskIdString) else {
            return
        }
        let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : 0
        let written = totalBytesWritten
        Task { @MainActor in
            self.markProgress(taskId: taskId, written: written, total: total, speed: 0)
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let taskIdString = task.taskDescription,
              let taskId = UUID(uuidString: taskIdString),
              let error else {
            return
        }
        // 取消是用户主动行为，不算失败
        if (error as NSError).code == NSURLErrorCancelled {
            return
        }
        Task { @MainActor in
            self.markFailed(taskId: taskId, error: error)
        }
    }

    private func fetchLyrics(for task: DownloadTask) async {
        do {
            let lyrics = try await api.fetchLyrics(songId: task.song.id)
            let lrcURL = task.url.deletingPathExtension().appendingPathExtension("lrc")
            let text = LyricsService.serialize(lyrics)
            try text.write(to: lrcURL, atomically: true, encoding: .utf8)
        } catch {
            // 歌词失败不阻塞主下载
        }
    }
}

// MARK: - Errors

enum DownloadError: LocalizedError {
    case unavailable(Int64)
    case sizeMismatch(expected: Int64, actual: Int64)

    var errorDescription: String? {
        switch self {
        case .unavailable(let id): return "歌曲 \(id) 暂无可用下载地址（可能需要 VIP）"
        case .sizeMismatch(let e, let a): return "下载文件大小不匹配（期望 \(e) 字节，实际 \(a) 字节）"
        }
    }
}
