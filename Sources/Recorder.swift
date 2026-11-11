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

    /// 最近的下载速率（KB/s），用于画小趋势图
    @Published private(set) var speedHistory: [Double] = []
    @Published private(set) var speed: Double = 0
    /// 多少秒没收到数据了（卡住预警）
    @Published private(set) var stalledSeconds = 0
    /// 最近一次错误（红字显示）
    @Published private(set) var lastError = ""
    /// 解析出来的流地址，方便核对
    @Published private(set) var streamURL = ""

    /// 0 表示不限时长
    var limitMinutes: Int = 0
    /// 播放页地址，很多 CDN 校验 Referer
    var referer: String = ""

    var progress: Double? {
        guard limitMinutes > 0 else { return nil }
        return min(1.0, duration / Double(limitMinutes * 60))
    }

    private var task: Task<Void, Never>?
    private var watcher: Task<Void, Never>?
    private var bgTask: UIBackgroundTaskIdentifier = .invalid

    private let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 15
        cfg.timeoutIntervalForResource = 45
        cfg.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        cfg.waitsForConnectivity = false
        cfg.httpMaximumConnectionsPerHost = 2
        return URLSession(configuration: cfg)
    }()

    var isBusy: Bool { phase == .resolving || phase == .running || phase == .finishing }

    // MARK: - 控制

    func markResolving(_ url: String = "") {
        phase = .resolving
        message = "解析流地址…"
        streamURL = url
        lastError = ""
    }

    func start(playlistURL: URL) {
        guard task == nil else { return }
        streamURL = playlistURL.absoluteString
        let limitSeconds = limitMinutes > 0 ? Double(limitMinutes * 60) : 0

        watcher = Task { [weak self] in
            var lastBytes: Int64 = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self else { return }
                let now = self.bytes
                let kbps = Double(now - lastBytes) / 1024.0
                lastBytes = now
                self.speed = kbps
                self.speedHistory.append(kbps)
                if self.speedHistory.count > 60 { self.speedHistory.removeFirst() }
                if kbps <= 0.01 && self.phase == .running {
                    self.stalledSeconds += 1
                } else {
                    self.stalledSeconds = 0
                }
            }
        }

        task = Task { [weak self] in
            guard let self else { return }
            await self.runLoop(indexURL: playlistURL, limitSeconds: limitSeconds)
            await MainActor.run {
                self.task = nil
                self.watcher?.cancel()
                self.watcher = nil
                self.endBackground()
            }
        }
    }

    func stop() {
        task?.cancel()
        if phase == .resolving { phase = .done; message = "已取消" }
    }

    func reset() {
        task?.cancel(); watcher?.cancel()
        task = nil; watcher = nil
        phase = .idle
        segmentsDone = 0
        bytes = 0
        duration = 0
        message = ""
        outputURL = nil
        speed = 0
        speedHistory = []
        stalledSeconds = 0
        lastError = ""
        streamURL = ""
    }

    // MARK: - 主循环

    private func runLoop(indexURL: URL, limitSeconds: Double) async {
        phase = .running
        message = "正在拉取播放列表…"
        beginBackground()

        let outURL = Self.documentsDir.appendingPathComponent(Self.fileName())
        FileManager.default.createFile(atPath: outURL.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: outURL) else {
            phase = .failed
            lastError = "无法创建文件"
            return
        }
        defer { try? handle.close() }

        var currentIndex = indexURL
        var lastSeq = -1
        var consecutiveFail = 0
        var segFailStreak = 0
        var wroteInit = false
        var lastInitURI = ""

        while !Task.isCancelled {
            if limitSeconds > 0 && duration >= limitSeconds {
                message = "已到设定时长"
                break
            }

            let (text, code, finalURL) = await fetchText(currentIndex)
            guard let text else {
                consecutiveFail += 1
                lastError = "拉取播放列表失败（HTTP \(code)），第 \(consecutiveFail) 次重试"
                message = "重试中…（\(consecutiveFail)/30）"
                if consecutiveFail > 30 {
                    phase = .failed
                    lastError = "连续 30 次拉不到播放列表，链接可能已过期"
                    break
                }
                try? await sleep(2)
                continue
            }
            consecutiveFail = 0
            lastError = ""

            let playlist = M3U8.parse(text, base: finalURL)
            if finalURL != indexURL || currentIndex != indexURL {
                streamURL = finalURL.absoluteString
            }

            // 主列表（多码率）：挑第一个子流继续
            if playlist.segments.isEmpty, let v = playlist.variants.first, let vu = URL(string: v) {
                currentIndex = vu
                lastError = ""
                continue
            }
            if playlist.encrypted {
                phase = .failed
                lastError = "该流带 AES-128 加密，暂不支持"
                break
            }

            // fMP4 初始化段（EXT-X-MAP），只写一次
            if let mapURI = playlist.initSegmentURI, mapURI != lastInitURI {
                if let u = M3U8.absoluteURL(mapURI, base: finalURL),
                   let data = await fetchData(u), !data.isEmpty {
                    try? handle.write(contentsOf: data)
                    bytes += Int64(data.count)
                    wroteInit = true
                    lastInitURI = mapURI
                }
            }
            _ = wroteInit

            for (i, seg) in playlist.segments.enumerated() {
                if Task.isCancelled { break }
                let seq = playlist.mediaSequence + i
                if seq <= lastSeq { continue }
                if limitSeconds > 0 && duration >= limitSeconds { break }

                if let data = await fetchData(seg.url), !data.isEmpty {
                    do {
                        try handle.write(contentsOf: data)
                        try? handle.synchronize()
                    } catch {
                        phase = .failed
                        lastError = "写文件失败：\(error.localizedDescription)"
                        return
                    }
                    bytes += Int64(data.count)
                    segmentsDone += 1
                    duration += seg.duration
                    segFailStreak = 0
                    message = "录制中"
                } else {
                    segFailStreak += 1
                    if segFailStreak >= 5 {
                        lastError = "连续 \(segFailStreak) 个切片下载失败，请检查链接是否过期"
                    } else {
                        lastError = "切片 \(seq) 下载失败，重试中"
                    }
                    break
                }
                lastSeq = seq
            }

            if playlist.ended { message = "直播已结束"; break }

            try? await sleep(max(1.0, min(3.0, playlist.targetDuration / 2)))
        }

        if Task.isCancelled { message = "已手动停止" }
        else if message.isEmpty { message = "结束" }
        outputURL = outURL
        phase = .done
    }

    // MARK: - 网络

    private func fetchText(_ url: URL) async -> (String?, Int, URL) {
        var req = URLRequest(url: url)
        req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)", forHTTPHeaderField: "User-Agent")
        req.setValue("*/*", forHTTPHeaderField: "Accept")
        if !referer.isEmpty { req.setValue(referer, forHTTPHeaderField: "Referer") }
        do {
            let (data, resp) = try await session.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            // 关键：跟随 302 之后，基准地址必须用最终 URL，
            // 否则相对切片会被拼到旧域名上导致全部 404
            let final = resp.url ?? url
            guard (200..<300).contains(code) else { return (nil, code, final) }
            return (String(data: data, encoding: .utf8), code, final)
        } catch {
            return (nil, (error as NSError).code, url)
        }
    }

    private func fetchData(_ url: URL) async -> Data? {
        var req = URLRequest(url: url)
        req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)", forHTTPHeaderField: "User-Agent")
        if !referer.isEmpty { req.setValue(referer, forHTTPHeaderField: "Referer") }
        do {
            let (data, resp) = try await session.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            guard (200..<300).contains(code), !data.isEmpty else { return nil }
            return data
        } catch {
            return nil
        }
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
        return exporter.status == .completed ? out : nil
    }
}
