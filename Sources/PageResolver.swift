import Foundation
import WebKit

/// 用隐藏的 WKWebView 打开网页，跑页面自带的 JS，把最终的 m3u8 地址读回来。
/// 适用于那些「给个页面链接、真正的流地址靠页面 JS 现算」的站。
@MainActor
final class PageResolver: NSObject, ObservableObject, WKNavigationDelegate {
    @Published private(set) var log = ""

    private var webView: WKWebView?
    private var pollTimer: Timer?
    private var deadline: Date = .distantFuture
    private var finished = false
    private var completion: ((String?) -> Void)?

    private static let probeJS = """
    (function(){
      try { if (window.QQurl) return window.QQurl; } catch(e) {}
      try { if (window.playurl) return window.playurl; } catch(e) {}
      try { if (window.videoUrl) return window.videoUrl; } catch(e) {}
      var f = document.querySelector('iframe');
      if (f && f.src) {
        var m = f.src.match(/[?&]url=([^&]+)/);
        if (m) { try { return decodeURIComponent(m[1]); } catch(e) {} }
        if (f.src.indexOf('.m3u8') > 0) return f.src;
      }
      var v = document.querySelector('video');
      if (v && v.src && v.src.indexOf('.m3u8') > 0) return v.src;
      var html = document.documentElement ? document.documentElement.innerHTML : '';
      var re = /https?:\\/\\/[^\\s"'<>\\\\]+\\.m3u8[^\\s"'<>\\\\]*/;
      if (html) { var mm = html.match(re); if (mm) return mm[0]; }
      return '';
    })()
    """

    func resolve(pageURL: String, timeout: TimeInterval = 25, completion: @escaping (String?) -> Void) {
        self.completion = completion
        finished = false
        deadline = Date().addingTimeInterval(timeout)
        log = "打开页面…"

        let cfg = WKWebViewConfiguration()
        cfg.allowsInlineMediaPlayback = true
        cfg.mediaTypesRequiringUserActionForPlayback = []

        let wv = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 700), configuration: cfg)
        wv.navigationDelegate = self
        wv.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
        wv.isHidden = true
        webView = wv

        guard let u = URL(string: pageURL) else { finish(nil); return }
        wv.load(URLRequest(url: u))

        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.probe() }
        }
    }

    func cancel() {
        finish(nil)
    }

    private func probe() {
        guard !finished, let wv = webView else { return }
        if Date() > deadline { finish(nil); return }

        wv.evaluateJavaScript(Self.probeJS) { [weak self] result, _ in
            guard let self else { return }
            guard let s = result as? String, !s.isEmpty else { return }
            var url = s
            if url.hasPrefix("//") { url = "https:" + url }
            if url.contains(".m3u8") {
                Task { @MainActor in self.finish(url) }
            }
        }
    }

    private func finish(_ url: String?) {
        guard !finished else { return }
        finished = true
        pollTimer?.invalidate()
        pollTimer = nil
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView = nil
        completion?(url)
        completion = nil
    }

    // MARK: - WKNavigationDelegate

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            self.log = "页面已加载，正在提取流地址…"
            self.probe()
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in self.log = "页面加载失败：\(error.localizedDescription)" }
    }
}
