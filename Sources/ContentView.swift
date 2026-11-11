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
                    Text(useDirect ? "直接把 m3u8 播放列表地址填进来。" : "打开页面后自动解析出真正的流地址。")
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

                if recorder.phase != .idle || !resolver.log.isEmpty {
                    Section("状态") {
                        LabeledContent("进度", value: statusText)
                        if recorder.segmentsDone > 0 {
                            LabeledContent("切片", value: "\(recorder.segmentsDone) 个")
                            LabeledContent("已用时", value: Fmt.clock(recorder.duration))
                            LabeledContent("文件大小", value: Fmt.bytes(recorder.bytes))
                        }
                        if !resolver.log.isEmpty && recorder.phase == .resolving {
                            Text(resolver.log).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }

                if let out = recorder.outputURL {
                    Section("结果") {
                        Text(URL(fileURLWithPath: out.path).lastPathComponent)
                            .font(.system(.footnote, design: .monospaced))

                        Button("播放") { play(out) }
                        Button("转成 MP4（不转码）") { remux(out) }
                        Button("保存到相册") { saveToPhotos(out) }

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

    private var statusText: String {
        switch recorder.phase {
        case .idle: return "待机"
        case .resolving: return "解析中"
        case .running: return recorder.message
        case .finishing: return "收尾中"
        case .done: return recorder.message.isEmpty ? "完成" : recorder.message
        case .failed: return "失败"
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

        guard URL(string: pageURL) != nil else { alert = "页面地址格式不对"; return }
        recorder.markResolving()
        resolver.resolve(pageURL: pageURL) { result in
            guard let urlString = result, let u = URL(string: urlString) else {
                alert = "没能从页面里解析出 m3u8。\n可以切成「直链 m3u8」手动填入。"
                return
            }
            recorder.start(playlistURL: u)
        }
    }

    private func play(_ url: URL) {
        let p = AVPlayer(url: url)
        let vc = AVPlayerViewController()
        vc.player = p
        topVC()?.present(vc, animated: true) { p.play() }
    }

    private func remux(_ ts: URL) {
        Task {
            alert = "正在转换，请稍候…"
            let mp4 = await Recorder.remuxToMP4(ts)
            if let mp4 {
                alert = "已生成 \(mp4.lastPathComponent)"
            } else {
                alert = "转换失败（可能是 TS 封装头部不完整）"
            }
        }
    }

    private func saveToPhotos(_ url: URL) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                Task { @MainActor in alert = "没有相册权限，请到设置里开启" }
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
            ToolbarItem(placement: .topBarTrailing) {
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
