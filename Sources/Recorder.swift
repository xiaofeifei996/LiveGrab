import Foundation
import AVFoundation
import UIKit

@MainActor
final class Recorder: ObservableObject {
    enum Phase: Equatable {
        case idle, resolving, running, finishing, done, failed
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var segmentsDone = 0
    @Published private(set) var bytes: Int64 = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var message = ""
    @Published private(set) var outputURL: URL?

    /// 0 表示不限时长
    var limitMinutes: Int = 0

    private var task: Task<Void, Never>?
    private var bgTask: UIBackgroundTaskIdentifier = .invalid
    private let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 20
        cfg.timeoutIntervalForResource = 60
        cfg.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        cfg.httpMaximumConnectionsPerHost = 4
        return URLSession(configuration: cfg)
    }()

    var isBusy: Bool { phase == .resolving || phase == .running || phase == .finishing }

    // MARK: - 对外接口

    func start(playlistURL: URL) {
        guard task == nil else { return }
        let limitSeconds = limitMinutes > 0 ? Double(limitMinutes * 60) : 0
        task = Task { [weak self] in
            guard let self else { return }
            await self.runLoop(indexURL: playlistURL, limitSeconds: limitSeconds)
            await MainActor.run {
                self.task = nil
                self.endBackground()
            }
        }
    }

    func stop() {
        task?.cancel()
    }

    func markResolving() {
        phase = .resolving
        message = "解析中…"
    }

    func reset() {
        task?.cancel()
        task = nil
        phase = .idle
        segmentsDone = 0
        bytes = 0
        duration = 0
        message = ""
        outputURL = nil
    }

    // MARK: - 主循环

    private func runLoop(indexURL: URL, limitSeconds: Double) async {
        phase = .running
        message = "正在拉取直播切片…"
        beginBackground()

        let outURL = Self.documentsDir.appendingPathComponent(Self.fileName())
        FileManager.default.createFile(atPath: outURL.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: outURL) else {
            phase = .failed
            message = "无法创建文件"
            return
        }
        defer { try? handle.close() }

        var lastSeq = -1          // 已写盘的最后一个序号
        var consecutiveFail = 0

        while !Task.isCancelled {
            if limitSeconds > 0 && duration >= limitSeconds {
                message = "已到设定时长"
                break
            }

            guard let text = await fetchText(indexURL) else {
                consecutiveFail += 1
                if consecutiveFail > 30 {
                    phase = .failed
                    message = "连续 30 次拉不到播放列表，可能链接已过期"
                    return
                }
                message = "列表拉取失败，重试中…（\(consecutiveFail)/30）"
                try? await sleep(2)
                continue
            }
            consecutiveFail = 0

            let playlist = M3U8.parse(text, base: indexURL)
            if playlist.encrypted {
                phase = .failed
                message = "该流带 AES-128 加密，暂不支持"
                return
            }

            for (i, seg) in playlist.segments.enumerated() {
                if Task.isCancelled { break }
                let seq = playlist.mediaSequence + i
                if seq <= lastSeq { continue }
                if limitSeconds > 0 && duration >= limitSeconds { break }

                if let data = await fetchData(seg.url), !data.isEmpty {
                    do {
                        try handle.write(contentsOf: data)
                    } catch {
                        phase = .failed
                        message = "写文件失败：\(error.localizedDescription)"
                        return
                    }
                    bytes += Int64(data.count)
                    segmentsDone += 1
                    duration += seg.duration
                    message = "录制中… 已保存 \(Fmt.clock(duration))"
                } else {
                    // 单个切片失败：下一轮会重试（序号未推进）
                    break
                }
                lastSeq = seq
            }

            if playlist.ended { message = "直播已结束"; break }

            try? await sleep(max(1.0, playlist.targetDuration / 2))
        }

        if Task.isCancelled { message = "已手动停止" }
        outputURL = outURL
        phase = .done
    }

    // MARK: - 网络

    private func fetchText(_ url: URL) async -> String? {
        var req = URLRequest(url: url)
        req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)", forHTTPHeaderField: "User-Agent")
        guard let (data, resp) = try? await session.data(for: req) else { return nil }
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func fetchData(_ url: URL) async -> Data? {
        var req = URLRequest(url: url)
        req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)", forHTTPHeaderField: "User-Agent")
        guard let (data, resp) = try? await session.data(for: req) else { return nil }
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
        return data
    }

    private func sleep(_ seconds: Double) async throws {
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    // MARK: - 后台 & 工具

    private func beginBackground() {
        bgTask = UIApplication.shared.beginBackgroundTask(withName: "record") { [weak self] in
            Task { @MainActor in self?.endBackground() }
        }
    }

    private func endBackground() {
        if bgTask != .invalid {
            UIApplication.shared.endBackgroundTask(bgTask)
            bgTask = .invalid
        }
    }

    static var documentsDir: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    static func fileName() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd_HHmmss"
        return "live_\(f.string(from: Date())).ts"
    }

    /// .ts → .mp4（不转码，只换封装），失败返回 nil
    static func remuxToMP4(_ ts: URL) async -> URL? {
        let asset = AVURLAsset(url: ts)
        guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            return nil
        }
        let out = ts.deletingPathExtension().appendingPathExtension("mp4")
        try? FileManager.default.removeItem(at: out)
        exporter.outputURL = out
        exporter.outputFileType = .mp4
        exporter.shouldOptimizeForNetworkUse = false
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            exporter.exportAsynchronously { cont.resume() }
        }
        if exporter.status == .completed { return out }
        return nil
    }
}
