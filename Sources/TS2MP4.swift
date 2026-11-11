import Foundation

/// 自研 TS → MP4 封装器。
/// 不能用 AVAssetExportSession：AVFoundation 根本不支持裸 MPEG-TS 解复用
/// （只有 HLS 上下文里才行），所以必须自己拆包再重新封 MP4。
enum TS2MP4 {

    // MARK: - 字节工具

    @inline(__always) static func be16(_ v: Int) -> Data { Data([UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]) }
    @inline(__always) static func be32(_ v: Int) -> Data {
        Data([UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)])
    }
    @inline(__always) static func be32(_ v: UInt32) -> Data {
        Data([UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)])
    }
    @inline(__always) static func be64(_ v: UInt64) -> Data {
        var d = Data()
        for i in stride(from: 56, through: 0, by: -8) { d.append(UInt8((v >> UInt64(i)) & 0xFF)) }
        return d
    }

    static func box(_ type: String, _ payload: Data) -> Data {
        var d = be32(payload.count + 8)
        d.append(type.data(using: .ascii)!)
        d.append(payload)
        return d
    }

    static func fullbox(_ type: String, _ version: UInt8, _ flags: UInt32, _ payload: Data) -> Data {
        var p = Data([version, UInt8((flags >> 16) & 0xFF), UInt8((flags >> 8) & 0xFF), UInt8(flags & 0xFF)])
        p.append(payload)
        return box(type, p)
    }

    /// ESDS 用的变长长度编码
    static func desc(_ tag: UInt8, _ payload: Data) -> Data {
        var out = Data([tag])
        var len = payload.count
        while true {
            let b = UInt8(len & 0x7F)
            len >>= 7
            out.append(b | (len > 0 ? 0x80 : 0))
            if len == 0 { break }
        }
        out.append(payload)
        return out
    }

    static let matrix: Data = {
        var d = Data()
        for v: UInt32 in [0x10000, 0, 0, 0, 0x10000, 0, 0, 0, 0x40000000] { d.append(be32(v)) }
        return d
    }()

    // MARK: - 音视频样本

    struct VideoSample {
        let pts: Int64      // 90kHz
        let data: Data      // 长度前缀的 NAL 序列
        let isSync: Bool
    }
    struct AudioSample {
        let pts: Int64      // 90kHz
        let data: Data      // 裸 AAC 帧（无 ADTS）
    }

    // MARK: - TS 解复用

    struct Demuxed {
        var video: [VideoSample] = []
        var audio: [AudioSample] = []
        var sps: Data?
        var pps: Data?
        var audioProfile = 2      // AAC LC
        var audioSampleRateIndex = 4
        var audioChannels = 2
        var videoWidth = 0
        var videoHeight = 0
    }

    // MARK: - SPS 解析（只取宽高）

    private struct BitReader {
        let bytes: [UInt8]
        var pos = 0
        init(_ d: Data) { bytes = [UInt8](d) }
        mutating func bit() -> Int {
            guard pos < bytes.count * 8 else { return 0 }
            let b = (bytes[pos / 8] >> (7 - UInt8(pos % 8))) & 1
            pos += 1
            return Int(b)
        }
        mutating func bits(_ n: Int) -> Int {
            var v = 0
            for _ in 0..<n { v = (v << 1) | bit() }
            return v
        }
        mutating func ue() -> Int {
            var zeros = 0
            while bit() == 0 && zeros < 32 { zeros += 1 }
            if zeros == 0 { return 0 }
            return (1 << zeros) - 1 + bits(zeros)
        }
        mutating func se() -> Int {
            let k = ue()
            return (k % 2 == 0) ? -(k / 2) : (k + 1) / 2
        }
    }

    /// 从 SPS 里解出 width/height（含裁剪与宽高比修正）
    static func parseSPS(_ sps: Data) -> (Int, Int)? {
        // 去掉 NAL 头 + 防竞争字节 0x000003
        let raw = [UInt8](sps.dropFirst())
        var clean: [UInt8] = []
        var i = 0
        while i < raw.count {
            if i + 2 < raw.count && raw[i] == 0 && raw[i+1] == 0 && raw[i+2] == 3 {
                clean.append(0); clean.append(0); i += 3
            } else { clean.append(raw[i]); i += 1 }
        }
        var br = BitReader(Data(clean))
        _ = br.bits(8)                     // profile_idc
        _ = br.bits(8)                     // constraint flags
        _ = br.bits(8)                     // level_idc
        _ = br.ue()                        // seq_parameter_set_id
        let profile = Int(clean[0])
        var chromaFormat = 1
        if [100, 110, 122, 244, 44, 83, 86, 118, 128, 138, 139, 134].contains(profile) {
            chromaFormat = br.ue()
            if chromaFormat == 3 { _ = br.bit() }
            _ = br.ue(); _ = br.ue(); _ = br.bit()
            if br.bit() == 1 {
                let n = chromaFormat != 3 ? 8 : 12
                for k in 0..<n where br.bit() == 1 {
                    var size = k < 6 ? 16 : 64
                    var lastScale = 8, nextScale = 8
                    var j = 0
                    while j < size {
                        if nextScale != 0 {
                            let delta = br.se()
                            nextScale = (lastScale + delta + 256) % 256
                        }
                        lastScale = nextScale == 0 ? lastScale : nextScale
                        j += 1
                    }
                    _ = size
                }
            }
        }
        _ = br.ue()                        // log2_max_frame_num_minus4
        let pocType = br.ue()
        if pocType == 0 {
            _ = br.ue()
        } else if pocType == 1 {
            _ = br.bit(); _ = br.se(); _ = br.se()
            let n = br.ue()
            for _ in 0..<n { _ = br.se() }
        }
        _ = br.ue()                        // max_num_ref_frames
        _ = br.bit()                       // gaps_in_frame_num
        let wMbs = br.ue() + 1
        let hMapUnits = br.ue() + 1
        let frameMbsOnly = br.bit()
        if frameMbsOnly == 0 { _ = br.bit() }
        _ = br.bit()                       // direct_8x8
        var cropL = 0, cropR = 0, cropT = 0, cropB = 0
        if br.bit() == 1 {
            cropL = br.ue(); cropR = br.ue(); cropT = br.ue(); cropB = br.ue()
        }
        let subW = chromaFormat == 3 ? 1 : 2
        let subH = (chromaFormat == 1) ? 2 : 1
        var width = wMbs * 16
        var height = (2 - frameMbsOnly) * hMapUnits * 16
        width -= (cropL + cropR) * subW
        height -= (cropT + cropB) * subH * (2 - frameMbsOnly)
        return (width > 0 && height > 0) ? (width, height) : nil
    }

    static func demux(_ url: URL) throws -> Demuxed {
        guard let fh = try? FileHandle(forReadingFrom: url) else { throw Err.cannotOpen }
        defer { try? fh.close() }

        // 1) 先扫头部找 PAT/PMT，确定 PID
        var pmtPID: Int? = nil
        var videoPID: Int? = nil
        var audioPID: Int? = nil

        var headerScanned = false
        var carry = Data()

        func parseTables(_ chunk: Data) -> Bool {
            var i = 0
            let d = [UInt8](chunk)
            var pmtSearch = pmtPID == nil
            while i + 188 <= d.count {
                if d[i] == 0x47 {
                    let pid = (Int(d[i+1] & 0x1F) << 8) | Int(d[i+2])
                    let pusi = (d[i+1] & 0x40) != 0
                    let afc = (d[i+3] >> 4) & 3
                    var off = i + 4
                    if afc == 2 || afc == 3 { off = i + 5 + Int(d[i+4]) }
                    if (afc == 2 || off >= i + 188) == false, pusi {
                        if pid == 0 && pmtSearch {
                            let sec = extractSection(d, off, i + 188)
                            if sec.count > 12 {
                                let body = [UInt8](sec)
                                var j = 8
                                while j + 4 <= body.count - 4 {
                                    let prog = (Int(body[j]) << 8) | Int(body[j+1])
                                    let ppid = (Int(body[j+2] & 0x1F) << 8) | Int(body[j+3])
                                    if prog != 0 { pmtPID = ppid; pmtSearch = false; break }
                                    j += 4
                                }
                            }
                        } else if let pp = pmtPID, pid == pp, videoPID == nil {
                            let sec = extractSection(d, off, i + 188)
                            let b = [UInt8](sec)
                            if b.count > 12 {
                                let pinfo = (Int(b[10] & 0x0F) << 8) | Int(b[11])
                                var k = 12 + pinfo
                                let end = b.count - 4
                                while k + 5 <= end {
                                    let st = b[k]
                                    let epid = (Int(b[k+1] & 0x1F) << 8) | Int(b[k+2])
                                    let esinfo = (Int(b[k+3] & 0x0F) << 8) | Int(b[k+4])
                                    if st == 0x1B && videoPID == nil { videoPID = epid }
                                    if (st == 0x0F || st == 0x11) && audioPID == nil { audioPID = epid }
                                    k += 5 + esinfo
                                }
                            }
                        }
                    }
                }
                i += 188
            }
            return videoPID != nil
        }

        // 读前若干 MB 找表
        var scanned = 0
        let probeLimit = 4 * 1024 * 1024
        while !headerScanned && scanned < probeLimit {
            guard let chunk = try? fh.read(upToCount: 1024 * 1024), !chunk.isEmpty else { break }
            scanned += chunk.count
            _ = parseTables(chunk)
            if videoPID != nil { headerScanned = true }
        }
        guard let vpid = videoPID, let apid = audioPID else { throw Err.noStreams }

        // 2) 正式解复用全文件
        try fh.seek(toOffset: 0)
        var out = Demuxed()
        var vbuf = Data()
        var vpts: Int64 = -1
        var abuf: Data? = nil
        var apts: Int64 = -1
        var gotAudioParams = false

        func flushVideo() {
            if !vbuf.isEmpty && vpts >= 0 {
                let nals = splitAnnexB(vbuf)
                if !nals.isEmpty {
                    var payload = Data()
                    for n in nals {
                        payload.append(be32(n.count)); payload.append(n)
                        if n[0] & 0x1F == 7 && out.sps == nil { out.sps = n }
                        if n[0] & 0x1F == 8 && out.pps == nil { out.pps = n }
                    }
                    let sync = nals.contains { ($0[0] & 0x1F) == 5 }
                    out.video.append(VideoSample(pts: vpts, data: payload, isSync: sync))
                }
            }
            vbuf = Data(); vpts = -1
        }
        func flushAudio() {
            if let a = abuf, !a.isEmpty {
                let (frames, profile, sfi, ch) = splitADTS(a, basePTS: apts)
                if !gotAudioParams, let f = frames.first {
                    gotAudioParams = true
                    _ = f
                    out.audioProfile = profile
                    out.audioSampleRateIndex = sfi
                    out.audioChannels = ch
                }
                out.audio.append(contentsOf: frames.map { AudioSample(pts: $0.0, data: $0.1) })
            }
            abuf = nil; apts = -1
        }

        let readSize = 512 * 1024
        while true {
            guard let chunk = try? fh.read(upToCount: readSize), !chunk.isEmpty else { break }
            carry = chunk
            let d = [UInt8](carry)
            var i = 0
            while i + 188 <= d.count {
                guard d[i] == 0x47 else { i += 1; continue }
                let pid = (Int(d[i+1] & 0x1F) << 8) | Int(d[i+2])
                let pusi = (d[i+1] & 0x40) != 0
                let afc = (d[i+3] >> 4) & 3
                var off = i + 4
                if afc == 2 || afc == 3 { off = i + 5 + Int(d[i+4]) }
                let end = i + 188
                if afc == 2 || off >= end { i += 188; continue }

                if pid == vpid {
                    let payload = Data(d[off..<end])
                    if pusi {
                        flushVideo()
                        let (body, pts) = stripPES(payload)
                        if let p = pts { vpts = p }
                        vbuf.append(body)
                    } else {
                        vbuf.append(payload)
                    }
                } else if pid == apid {
                    let payload = Data(d[off..<end])
                    if pusi {
                        flushAudio()
                        let (body, pts) = stripPES(payload)
                        if let p = pts { apts = p }
                        abuf = body
                    } else if abuf != nil {
                        abuf!.append(payload)
                    }
                }
                i += 188
            }
        }
        flushVideo()
        flushAudio()

        guard !out.video.isEmpty, let sps = out.sps, out.pps != nil else { throw Err.noVideo }
        if let (w, h) = parseSPS(sps) {
            out.videoWidth = w
            out.videoHeight = h
        } else {
            out.videoWidth = 1280
            out.videoHeight = 720
        }
        if out.audio.isEmpty { throw Err.noAudio }
        return out
    }

    enum Err: Error, LocalizedError {
        case cannotOpen, noStreams, noVideo, noAudio, writeFailed
        var errorDescription: String? {
            switch self {
            case .cannotOpen: return "无法打开文件"
            case .noStreams: return "文件里找不到音视频轨道（可能录制不完整）"
            case .noVideo: return "找不到可用的 H.264 视频数据"
            case .noAudio: return "找不到可用的 AAC 音频数据"
            case .writeFailed: return "写入失败"
            }
        }
    }

    /// 从第一个字节起截出 PSI section（含 pointer_field 处理）
    static func extractSection(_ d: [UInt8], _ off: Int, _ end: Int) -> Data {
        guard off + 2 < end else { return Data() }
        let ptr = Int(d[off])
        let s = off + 1 + ptr
        guard s + 3 <= end else { return Data() }
        let slen = ((Int(d[s+1]) & 0x0F) << 8) | Int(d[s+2])
        let full = 3 + slen
        guard s + full <= end else { return Data(d[s..<end]) }
        return Data(d[s..<(s + full)])
    }

    /// 剥 TS 载荷里的 PES 头，返回 (ES 数据, PTS)
    static func stripPES(_ p: Data) -> (Data, Int64?) {
        guard p.count >= 9 else { return (p, nil) }
        let a = [UInt8](p)
        guard a[0] == 0, a[1] == 0, a[2] == 1 else { return (p, nil) }
        let flags = a[7]
        let hlen = Int(a[8])
        var pts: Int64? = nil
        if flags & 0x80 != 0 && p.count >= 14 {
            pts = (Int64((a[9] >> 1) & 0x07) << 30)
                | (Int64(a[10]) << 22)
                | (Int64((a[11] >> 1) & 0x7F) << 15)
                | (Int64(a[12]) << 7)
                | (Int64(a[13] >> 1) & 0x7F)
        }
        let start = 9 + hlen
        guard start <= p.count else { return (Data(), pts) }
        return (p.subdata(in: start..<p.count), pts)
    }

    /// Annex-B（00 00 01）切分
    static func splitAnnexB(_ data: Data) -> [Data] {
        let d = [UInt8](data)
        var starts: [Int] = []
        var i = 0
        while i + 3 <= d.count {
            if d[i] == 0 && d[i+1] == 0 && d[i+2] == 1 {
                starts.append(i + 3); i += 3
            } else { i += 1 }
        }
        var out: [Data] = []
        for (k, s) in starts.enumerated() {
            var e = (k + 1 < starts.count) ? starts[k+1] - 3 : d.count
            while e > s && d[e-1] == 0 { e -= 1 }
            if e > s { out.append(Data(d[s..<e])) }
        }
        return out
    }

    /// ADTS 拆帧 + 读参数；同 PES 内 PTS 按 1024 采样步进
    static func splitADTS(_ data: Data, basePTS: Int64) -> ([(Int64, Data)], Int, Int, Int) {
        let d = [UInt8](data)
        var frames: [(Int64, Data)] = []
        var profile = 2, sfi = 4, ch = 2
        var pts = basePTS
        var i = 0
        while i + 7 <= d.count {
            guard d[i] == 0xFF, (d[i+1] & 0xF0) == 0xF0 else { i += 1; continue }
            profile = Int((d[i+2] >> 6) & 0x03) + 1
            sfi = Int((d[i+2] >> 2) & 0x0F)
            ch = (Int(d[i+2] & 0x01) << 2) | Int((d[i+3] >> 6) & 0x03)
            let flen = (Int(d[i+3] & 0x03) << 11) | (Int(d[i+4]) << 3) | (Int(d[i+5]) >> 5)
            guard flen >= 7, i + flen <= d.count else { break }
            frames.append((pts >= 0 ? pts : 0, Data(d[(i+7)..<(i+flen)])))
            pts += 1024                 // ⚠ 必须逐帧推进，否则整段挤在同一时间点
            i += flen
        }
        return (frames, profile, sfi, ch)
    }

    // MARK: - 写 MP4

    static let sampleRates = [96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350]

    /// 分片写 MP4：每 fragFrames 个视频帧一个 moof+mdat，内存占用恒定
    static func convert(_ src: URL, to dst: URL, progress: ((Double) -> Void)? = nil) throws {
        let m = try demux(src)

        let vTimescale = 12800
        let srIndex = m.audioSampleRateIndex
        let aTimescale = sampleRates[min(srIndex, sampleRates.count - 1)]
        let vDelta = vTimescale / 25          // 25fps

        let ftyp = box("ftyp", "isom".data(using: .ascii)! + be32(0x200) + "isomiso5iso6mp41".data(using: .ascii)!)
        let moov = buildMoov(width: Int(m.videoWidth), height: Int(m.videoHeight),
                             sps: m.sps!, pps: m.pps!,
                             audioProfile: m.audioProfile,
                             sampleRateIndex: srIndex, channels: m.audioChannels,
                             vTimescale: vTimescale, aTimescale: aTimescale, vDelta: vDelta)

        guard let out = try? FileHandle(forWritingTo: dst) else { throw Err.writeFailed }
        // 覆盖已有内容
        try? out.truncate(atOffset: 0)
        try? out.write(contentsOf: ftyp)
        try? out.write(contentsOf: moov)

        let total = m.video.count
        var vi = 0, ai = 0
        var seq = 1
        let frag = 25

        while vi < total {
            let vEnd = min(vi + frag, total)
            let vChunk = Array(m.video[vi..<vEnd])
            let nextPTS = vEnd < total ? m.video[vEnd].pts : Int64.max

            var aChunk: [AudioSample] = []
            while ai < m.audio.count && m.audio[ai].pts < nextPTS {
                aChunk.append(m.audio[ai]); ai += 1
            }

            let vBase = Int64(Double(vChunk[0].pts) * Double(vTimescale) / 90000.0)
            let aBase = aChunk.isEmpty ? 0 : Int64(Double(aChunk[0].pts) * Double(aTimescale) / 90000.0)

            let mfhd = fullbox("mfhd", 0, 0, be32(seq))

            func traf(_ tid: Int, _ base: Int64, _ samples: [(Int, Data, Int)], _ dataOffset: Int) -> Data {
                let tfhd = fullbox("tfhd", 0, 0x020000, be32(tid))
                let tfdt = fullbox("tfdt", 1, 0, be64(UInt64(max(0, base))))
                var body = be32(samples.count) + be32(Int32(dataOffset))
                for (dur, d, fl) in samples {
                    body.append(be32(dur)); body.append(be32(d.count)); body.append(be32(UInt32(fl)))
                }
                let trun = fullbox("trun", 1, 0x000001 | 0x000100 | 0x000200 | 0x000400, body)
                return box("traf", tfhd + tfdt + trun)
            }

            let vSamples: [(Int, Data, Int)] = vChunk.map { (vDelta, $0.data, $0.isSync ? 0x02000000 : 0x01010000) }
            let aSamples: [(Int, Data, Int)] = aChunk.map { (1024, $0.data, 0x02000000) }

            // 先量 moof 长度（data offset 数值长度固定 4 字节，不影响总长）
            let vEmpty = traf(1, vBase, vSamples, 0)
            let aEmpty = aChunk.isEmpty ? Data() : traf(2, aBase, aSamples, 0)
            let moofLen = box("moof", mfhd + vEmpty + aEmpty).count

            let vOff = moofLen + 8
            let vBytes = vSamples.reduce(0) { $0 + $1.1.count }
            let aOff = vOff + vBytes          // ⚠ 音频要跳过视频数据

            let vTraf = traf(1, vBase, vSamples, vOff)
            let aTraf = aChunk.isEmpty ? Data() : traf(2, aBase, aSamples, aOff)
            let moof = box("moof", mfhd + vTraf + aTraf)

            var payload = Data()
            for s in vSamples { payload.append(s.1) }
            for s in aSamples { payload.append(s.1) }
            var mdat = be32(payload.count + 8)
            mdat.append("mdat".data(using: .ascii)!)
            mdat.append(payload)

            try? out.write(contentsOf: moof)
            try? out.write(contentsOf: mdat)

            vi = vEnd
            seq += 1
            progress?(Double(vi) / Double(total))
        }

        try? out.close()
    }

    static func buildMoov(width: Int, height: Int, sps: Data, pps: Data,
                          audioProfile: Int, sampleRateIndex: Int, channels: Int,
                          vTimescale: Int, aTimescale: Int, vDelta: Int) -> Data {

        func trak(_ tid: Int, isVideo: Bool, w: Int, h: Int, timescale: Int, entry: Data) -> Data {
            let hdlrType = isVideo ? "vide" : "soun"
            let hdlrName = isVideo ? "VideoHandler" : "SoundHandler"
            var hp = be32(0) + hdlrType.data(using: .ascii)!
            hp.append(Data(repeating: 0, count: 12))
            hp.append(hdlrName.data(using: .ascii)!)
            hp.append(0)
            let hdlr = fullbox("hdlr", 0, 0, hp)

            let mdhd = fullbox("mdhd", 0, 0, be32(0) + be32(0) + be32(timescale) + be32(0) + be16(0x55c4) + be16(0))

            let stsd = fullbox("stsd", 0, 0, be32(1) + entry)
            let stbl = box("stbl", stsd
                           + fullbox("stts", 0, 0, be32(0))
                           + fullbox("stsc", 0, 0, be32(0))
                           + fullbox("stsz", 0, 0, be32(0) + be32(0))
                           + fullbox("stco", 0, 0, be32(0)))

            let mediaHdr = isVideo
                ? fullbox("vmhd", 0, 1, Data(repeating: 0, count: 8))
                : fullbox("smhd", 0, 0, be16(0) + be16(0))
            let dinf = box("dinf", fullbox("dref", 0, 0, be32(1) + fullbox("url ", 0, 1, Data())))
            let minf = box("minf", mediaHdr + dinf + stbl)
            let mdia = box("mdia", mdhd + hdlr + minf)

            var tk = be32(0) + be32(0) + be32(tid) + be32(0) + be32(0)   // times 用 0，分片里给
            tk.append(Data(repeating: 0, count: 8))                       // reserved
            tk.append(be16(0))                                            // layer
            tk.append(be16(0))                                            // alt group
            tk.append(be16(isVideo ? 0x0100 : 0))                         // volume
            tk.append(be16(0))
            tk.append(matrix)
            tk.append(be32(isVideo ? w << 16 : 0))
            tk.append(be32(isVideo ? h << 16 : 0))
            let tkhd = fullbox("tkhd", 0, 0x000007, tk)

            return box("trak", tkhd + mdia)
        }

        // avcC
        var avcc = Data([0x01, sps[1], sps[2], sps[3], 0xFF, 0xE1])
        avcc.append(be16(sps.count)); avcc.append(sps)
        avcc.append(Data([0x01])); avcc.append(be16(pps.count)); avcc.append(pps)

        var vEntry = Data(repeating: 0, count: 6)
        vEntry.append(be16(1))                                   // data ref index
        vEntry.append(Data(repeating: 0, count: 16))             // reserved
        vEntry.append(be16(width)); vEntry.append(be16(height))
        vEntry.append(be32(0x480000)); vEntry.append(be32(0x480000))
        vEntry.append(be32(0))
        vEntry.append(be16(1))                                   // frame count
        vEntry.append(Data(repeating: 0, count: 32))             // compressor name
        vEntry.append(be16(0x0018))                              // depth
        vEntry.append(be16(0xFFFF))                              // -1
        vEntry.append(box("avcC", avcc))
        let vEntryBox = box("avc1", vEntry)

        // esds
        var asc = (audioProfile << 11) | (sampleRateIndex << 7) | (channels << 3)
        let ascData = Data([UInt8((asc >> 8) & 0xFF), UInt8(asc & 0xFF)])
        _ = asc
        let dsi = desc(0x05, ascData)
        var dcdPayload = Data([0x40, 0x15])
        dcdPayload.append(Data(repeating: 0, count: 3))          // ⚠ bufferSizeDB 是 3 字节
        dcdPayload.append(be32(128000)); dcdPayload.append(be32(128000))
        dcdPayload.append(dsi)
        let dcd = desc(0x04, dcdPayload)
        let slc = desc(0x06, Data([0x02]))
        let es = desc(0x03, be16(1) + Data([0x00]) + dcd + slc)
        let esds = fullbox("esds", 0, 0, es)

        let rate = sampleRates[min(sampleRateIndex, sampleRates.count - 1)]
        var aEntry = Data(repeating: 0, count: 6)
        aEntry.append(be16(1))
        aEntry.append(Data(repeating: 0, count: 8))
        aEntry.append(be16(channels)); aEntry.append(be16(16))
        aEntry.append(be16(0)); aEntry.append(be16(0))
        aEntry.append(be32(rate << 16))
        aEntry.append(esds)
        let aEntryBox = box("mp4a", aEntry)

        var mv = be32(0) + be32(0) + be32(1000) + be32(0)
        mv.append(be32(0x00010000))
        mv.append(be16(0x0100))
        mv.append(Data(repeating: 0, count: 10))
        mv.append(matrix)
        mv.append(Data(repeating: 0, count: 24))
        mv.append(be32(3))
        let mvhd = fullbox("mvhd", 0, 0, mv)

        let vTrak = trak(1, isVideo: true, w: width, h: height, timescale: vTimescale, entry: vEntryBox)
        let aTrak = trak(2, isVideo: false, w: 0, h: 0, timescale: aTimescale, entry: aEntryBox)

        let mvex = box("mvex",
                       fullbox("trex", 0, 0, be32(1) + be32(1) + be32(vDelta) + be32(0) + be32(0))
                       + fullbox("trex", 0, 0, be32(2) + be32(1) + be32(1024) + be32(0) + be32(0)))

        return box("moov", mvhd + vTrak + aTrak + mvex)
    }
}
