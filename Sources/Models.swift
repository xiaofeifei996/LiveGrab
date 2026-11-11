import Foundation

struct Segment {
    let url: URL
    let duration: Double
}

struct Playlist {
    var segments: [Segment] = []
    var mediaSequence: Int = 0
    var targetDuration: Double = 4
    var ended: Bool = false
    var encrypted: Bool = false
    /// fMP4 流的初始化段（#EXT-X-MAP:URI="..."）
    var initSegmentURI: String? = nil
}

enum M3U8 {
    /// 解析 m3u8 文本。base 用于把相对路径补成绝对地址。
    static func parse(_ text: String, base: URL) -> Playlist {
        var p = Playlist()
        var pendingDuration: Double = 0

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }

            if line.hasPrefix("#EXT-X-MEDIA-SEQUENCE:") {
                let v = line.dropFirst("#EXT-X-MEDIA-SEQUENCE:".count)
                p.mediaSequence = Int(v.trimmingCharacters(in: .whitespaces)) ?? 0
            } else if line.hasPrefix("#EXT-X-TARGETDURATION:") {
                let v = line.dropFirst("#EXT-X-TARGETDURATION:".count)
                p.targetDuration = Double(v.trimmingCharacters(in: .whitespaces)) ?? 4
            } else if line.hasPrefix("#EXT-X-KEY:") {
                // METHOD=NONE 表示不加密；其余（AES-128 / SAMPLE-AES）暂不支持
                if !line.contains("METHOD=NONE") { p.encrypted = true }
            } else if line.hasPrefix("#EXTINF:") {
                let v = line.dropFirst("#EXTINF:".count)
                let head = v.split(separator: ",").first.map(String.init) ?? ""
                pendingDuration = Double(head.trimmingCharacters(in: .whitespaces)) ?? 0
            } else if line.hasPrefix("#EXT-X-MAP:") {
                if let r = line.range(of: "URI=\"") {
                    let rest = line[r.upperBound...]
                    if let endq = rest.firstIndex(of: "\"") {
                        p.initSegmentURI = String(rest[..<endq])
                    }
                }
            } else if line.hasPrefix("#EXT-X-ENDLIST") {
                p.ended = true
            } else if !line.hasPrefix("#") {
                if let u = absoluteURL(line, base: base) {
                    p.segments.append(Segment(url: u, duration: pendingDuration))
                }
                pendingDuration = 0
            }
        }
        return p
    }

    static func absoluteURL(_ raw: String, base: URL) -> URL? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return nil }
        if s.hasPrefix("//") {
            s = (base.scheme ?? "https") + ":" + s
        }
        if let u = URL(string: s), u.scheme != nil { return u }
        return URL(string: s, relativeTo: base)?.absoluteURL
    }

    /// 从任意文本/URL 里粗暴提取 m3u8 地址（用于兜底）
    static func findM3U8(in text: String) -> String? {
        guard let r = text.range(of: #"https?://[^\s"'<>\\]+\.m3u8[^\s"'<>\\]*"#, options: .regularExpression) else {
            return nil
        }
        return String(text[r])
    }
}

enum Fmt {
    static func bytes(_ n: Int64) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f.string(fromByteCount: n)
    }

    static func clock(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        return String(format: "%02d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }
}
