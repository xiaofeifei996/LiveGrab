import SwiftUI
import AVKit
import Photos

@main
struct LiveGrabApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

struct ContentView: View {
    @StateObject private var recorder = Recorder()
    @StateObject private var resolver = PageResolver()

    @State private var pageURL = "http://nba.toutiaozb.com/qq/qq-kbs.html?matchliveid="
    @State private var directURL = ""
    @State private var useDirect = false
    @State private var limitIndex = 0
    @State private var alert: String?
    @State private var converting = false
    @State private var convertProgress: Double = 0
    @State private var convertNote = ""
    @State private var shareItems: [Any] = []

    private let limits = [0, 10, 30, 60, 90, 120, 180]

    var body: some View {
        NavigationView {
            Form {
                Section {
                    Picker("输入方式", selection: $useDirect) {
                        Text("网页链接").tag(false)
                        Text("直链 m3u8").tag(true)
                    }
                    .pickerStyle(.segmented)

                    if useDirect {
                        TextField("https://…/index.m3u8", text: $directURL)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                            .font(.system(.footnote, design: .monospaced))
                    } else {
                        TextField("页面地址", text: $pageURL)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                            .font(.system(.footnote, design: .monospaced))
                    }
                } header: {
                    Text("直播源")
                } footer: {
                    Text(useDirect
                         ? "直接把 m3u8 播放列表地址填进来。"
                         : "打开页面后自动解析出真正的流地址。带 url= 参数的播放页会直接取参数。")
                }

                Section("录制时长") {
                    Picker("上限", selection: $limitIndex) {
                        ForEach(limits.indices, id: \.self) { i in
                            Text(limits[i] == 0 ? "不限（直到手动停止）" : "\(limits[i]) 分钟").tag(i)
                        }
                    }
                }

                Section {
                    if recorder.isBusy {
                        Button(role: .destructive) {
                            recorder.stop()
                        } label: {
                            Text("停止录制").frame(maxWidth: .infinity)
                        }
                    } else {
                        Button {
                            begin()
                        } label: {
                            Text("开始录制")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                        }
                        .disabled(useDirect ? directURL.isEmpty : pageURL.isEmpty)
                    }
                }

                if recorder.isBusy || recorder.phase != .idle {
                    Section("状态") {
                        StatusPanel(recorder: recorder)
                    }
                }

                if let out = recorder.outputURL {
                    Section("结果") {
                        Text(URL(fileURLWithPath: out.path).lastPathComponent)
                            .font(.system(.footnote, design: .monospaced))

                        if converting {
                            ProgressView(value: convertProgress) {
                                Text(convertNote).font(.caption)
                            }
                            .progressViewStyle(.linear)
                        } else {
                            Button("播放") { play(out) }
                            Button("转成 MP4") { remux(out) }
                            Button("存入相册") { saveToPhotos(out) }
                            Button("分享 / 导出到文件 App") { share(out) }
                        }

                        NavigationLink("已录文件列表") { FileList() }
                    }
                }

                if recorder.phase == .idle && recorder.outputURL == nil {
                    Section {
                        NavigationLink("已录文件列表") { FileList() }
                    }
                }
            }
            .navigationTitle("直播录制")
            .alert(item: Binding(
                get: { alert.map { AlertItem(text: $0) } },
                set: { if $0 == nil { alert = nil } }
            )) { item in
                Alert(title: Text(item.text))
            }
        }
        .navigationViewStyle(.stack)
        .onChange(of: limitIndex) { idx in
            recorder.limitMinutes = limits[idx]
        }
    }

    private func begin() {
        recorder.reset()
        recorder.limitMinutes = limits[limitIndex]

        if useDirect {
            guard let u = URL(string: directURL) else { alert = "地址格式不对"; return }
            recorder.start(playlistURL: u)
            return
        }

        // 播放页直接把真地址放在 url= 参数里，先试这个，省掉整个 WebView 流程
        if let embedded = Self.extractURIParam(pageURL), embedded.contains(".m3u8"),
           let u = URL(string: embedded) {
            recorder.markResolving(embedded)
            recorder.referer = pageURL
            recorder.start(playlistURL: u)
            return
        }

        guard URL(string: pageURL) != nil else { alert = "页面地址格式不对"; return }
        recorder.markResolving()
        resolver.resolve(pageURL: pageURL) { result in
            guard let urlString = result, let u = URL(string: urlString) else {
                alert = "没能从页面里解析出 m3u8。\n可以切成「直链 m3u8」手动填入。"
                recorder.stop()
                recorder.reset()
                return
            }
            recorder.referer = pageURL
            recorder.start(playlistURL: u)
        }
    }

    /// 从 `?url=<encoded>` 里取出真正的流地址
    static func extractURIParam(_ s: String) -> String? {
        guard let r = s.range(of: "url=") else { return nil }
        var tail = String(s[r.upperBound...])
        if let amp = tail.firstIndex(of: "&") { tail = String(tail[..<amp]) }
        let decoded = tail.removingPercentEncoding ?? tail
        return decoded.hasPrefix("http") ? decoded : nil
    }

    private func play(_ url: URL) {
        let p = AVPlayer(url: url)
        let vc = AVPlayerViewController()
        vc.player = p
        topVC()?.present(vc, animated: true) { p.play() }
    }

    private func remux(_ ts: URL) {
        guard !converting else { return }
        converting = true
        convertProgress = 0
        convertNote = "开始转换…"

        Task {
            // 先体检，文件坏了直接说清楚，不要假装在转
            let info = Recorder.inspectTS(ts)
            if !info.syncOK {
                converting = false
                alert = "这个文件不是完整的 TS（同步字节校验不通过），\n可能录制过程中断流了。\n已录 \(Fmt.bytes(info.size))，可以试着直接分享导出。"
                return
            }

            Recorder.lastErrorText = ""
            let mp4 = await Recorder.remuxToMP4(ts) { p in
                Task { @MainActor in
                    self.convertProgress = p
                    self.convertNote = p <= 0.01 ? "无损换封装…" : "转换中 \(Int(p * 100))%"
                }
            }

            converting = false
            if let mp4 {
                alert = "已生成 \(mp4.lastPathComponent)"
            } else {
                let why = Recorder.lastErrorText
                alert = "转换失败\(why.isEmpty ? "" : "：\(why)")。\n可以点「分享 / 导出到文件 App」保存原始 .ts。"
            }
        }
    }

    private func share(_ url: URL) {
        guard let vc = topVC() else { return }
        let av = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        if let pop = av.popoverPresentationController {
            pop.sourceView = vc.view
            pop.sourceRect = CGRect(x: vc.view.bounds.midX, y: vc.view.bounds.midY, width: 0, height: 0)
            pop.permittedArrowDirections = []
        }
        vc.present(av, animated: true)
    }

    private func saveToPhotos(_ url: URL) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                Task { @MainActor in alert = "没有相册权限，请到设置里开启" }
                return
            }
            if url.pathExtension.lowercased() == "ts" {
                Task { @MainActor in
                    alert = "相册不支持 .ts 格式，请先转成 MP4；\n或者用「分享 / 导出到文件 App」保存原文件。"
                }
                return
            }
            PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
            } completionHandler: { ok, err in
                Task { @MainActor in
                    alert = ok ? "已保存到相册" : "保存失败：\(err?.localizedDescription ?? "未知错误")"
                }
            }
        }
    }

    private func topVC() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene
        var vc = scene?.windows.first(where: { $0.isKeyWindow })?.rootViewController
        while let p = vc?.presentedViewController { vc = p }
        return vc
    }
}

// MARK: - 状态面板（核心：进度条 + 速度 + 诊断）

struct StatusPanel: View {
    @ObservedObject var recorder: Recorder

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {

            // 进度条
            VStack(alignment: .leading, spacing: 6) {
                if let p = recorder.progress {
                    ProgressView(value: p)
                        .progressViewStyle(.linear)
                        .tint(p >= 1 ? .green : .accentColor)
                    HStack {
                        Text(Fmt.clock(recorder.duration)).font(.caption.monospacedDigit())
                        Spacer()
                        Text("\(Int(p * 100))% / 共 \(recorder.limitMinutes) 分钟")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    // 不限时长：不确定进度条，动起来就能看出还活着
                    ProgressView()
                        .progressViewStyle(.linear)
                    Text("不限时长 · 已录 \(Fmt.clock(recorder.duration))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // 速率 + 卡住预警
            HStack(spacing: 10) {
                Circle()
                    .fill(recorder.stalledSeconds > 5 ? Color.orange : Color.green)
                    .frame(width: 8, height: 8)
                Text(recorder.stalledSeconds > 5
                     ? "无数据 \(recorder.stalledSeconds)s，正在重试"
                     : String(format: "%.0f KB/s", recorder.speed))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(recorder.stalledSeconds > 5 ? .orange : .secondary)
                Spacer()
                Text(Fmt.bytes(recorder.bytes))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            // 速度趋势
            if recorder.speedHistory.count > 2 {
                Sparkline(values: recorder.speedHistory)
                    .frame(height: 28)
            }

            // 明细
            VStack(spacing: 6) {
                row("状态", recorder.message.isEmpty ? statusWord : recorder.message)
                row("切片", "\(recorder.segmentsDone) 个")
                if !recorder.streamURL.isEmpty {
                    Text(recorder.streamURL)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
            }

            if !recorder.lastError.isEmpty {
                Label(recorder.lastError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(.vertical, 4)
    }

    private var statusWord: String {
        switch recorder.phase {
        case .idle: return "待机"
        case .resolving: return "解析中"
        case .running: return "录制中"
        case .finishing: return "收尾中"
        case .done: return "完成"
        case .failed: return "失败"
        }
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack {
            Text(k).font(.subheadline)
            Spacer()
            Text(v).font(.subheadline).foregroundStyle(.secondary)
        }
    }
}

/// 极简速率曲线
struct Sparkline: View {
    let values: [Double]

    var body: some View {
        GeometryReader { geo in
            let maxV = max(values.max() ?? 1, 1)
            Path { p in
                let step = geo.size.width / CGFloat(max(values.count - 1, 1))
                for (i, v) in values.enumerated() {
                    let x = CGFloat(i) * step
                    let y = geo.size.height * (1 - CGFloat(v / maxV))
                    if i == 0 { p.move(to: CGPoint(x: x, y: y)) }
                    else { p.addLine(to: CGPoint(x: x, y: y)) }
                }
            }
            .stroke(Color.accentColor.opacity(0.7), lineWidth: 1.5)
        }
    }
}

struct AlertItem: Identifiable {
    let id = UUID()
    let text: String
}

struct FileList: View {
    @State private var files: [URL] = []

    var body: some View {
        List {
            if files.isEmpty {
                Text("还没有录制文件").foregroundStyle(.secondary)
            }
            ForEach(files, id: \.self) { f in
                VStack(alignment: .leading, spacing: 4) {
                    Text(f.lastPathComponent).font(.system(.footnote, design: .monospaced))
                    Text(sizeOf(f)).font(.caption).foregroundStyle(.secondary)
                }
            }
            .onDelete { idx in
                for i in idx { try? FileManager.default.removeItem(at: files[i]) }
                reload()
            }
        }
        .navigationTitle("已录文件")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("刷新") { reload() }
            }
        }
        .onAppear { reload() }
    }

    private func reload() {
        let dir = Recorder.documentsDir
        let all = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        files = all
            .filter { ["ts", "mp4"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    private func sizeOf(_ u: URL) -> String {
        let n = (try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return Fmt.bytes(Int64(n))
    }
}
