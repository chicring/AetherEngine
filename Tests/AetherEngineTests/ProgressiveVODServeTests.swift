import Testing
import Foundation
import AetherLibavformat
import AetherLibavcodec
import AetherLibavutil
@testable import AetherEngine

/// progressive VOD serve: the engine hands AVPlayer a VOD segment WHILE it is still being produced,
/// streaming the muxer's staging file per flushed fragment instead of blocking on the whole segment
/// (the /tmp/llhls A/B measured 1.9-3.9 s off startup, zero stalls). Playlist/segment/restart
/// semantics are untouched; these suites pin the delivery mechanics: the commit board, the cache
/// adoption handshake, the muxer's publish points, and the server's chunked relay.
@Suite("progressive VOD serve: ProgressiveSegmentBoard")
struct ProgressiveSegmentBoardTests {

    private func url(_ name: String) -> URL {
        URL(fileURLWithPath: "/tmp/\(name)-\(UUID().uuidString)")
    }

    private func join(_ t: Thread, timeout: TimeInterval = 30) {
        let deadline = Date().addingTimeInterval(timeout)
        while !t.isFinished && Date() < deadline { Thread.sleep(forTimeInterval: 0.005) }
    }

    private final class LockedProgress: @unchecked Sendable {
        private let lock = NSLock()
        private var progress: ProgressiveSegmentBoard.Progress?
        func set(_ p: ProgressiveSegmentBoard.Progress?) {
            lock.lock(); progress = p; lock.unlock()
        }
        var value: ProgressiveSegmentBoard.Progress? {
            lock.lock(); defer { lock.unlock() }; return progress
        }
    }

    @Test("commit advances the boundary and wakes a parked waiter")
    func commitWakesWaiter() {
        let board = ProgressiveSegmentBoard()
        let path = url("b")
        board.commit(index: 0, path: path, bytes: 0)
        guard let h = board.handle(for: 0) else {
            Issue.record("committed entry must vend a handle")
            return
        }
        let seen = LockedProgress()
        let t = Thread {
            seen.set(h.wait(beyond: 0, until: Date().addingTimeInterval(10)))
        }
        t.start()
        // Let the waiter park, then advance.
        Thread.sleep(forTimeInterval: 0.05)
        board.commit(index: 0, path: path, bytes: 1234)
        join(t)
        #expect(seen.value == .committed(1234))
    }

    @Test("bytes are monotone per path; a stale lower commit is ignored")
    func commitMonotone() {
        let board = ProgressiveSegmentBoard()
        let path = url("b")
        board.commit(index: 0, path: path, bytes: 100)
        board.commit(index: 0, path: path, bytes: 50)
        let h = board.handle(for: 0)
        #expect(h?.wait(beyond: -1, until: Date()) == .committed(100))
    }

    @Test("complete is terminal; abandon is terminal")
    func terminalStates() {
        let board = ProgressiveSegmentBoard()
        let pathA = url("a"), pathB = url("b")
        board.commit(index: 0, path: pathA, bytes: 10)
        let h0 = board.handle(for: 0)
        board.complete(index: 0, path: pathA, bytes: 99)
        #expect(h0?.wait(beyond: 10, until: Date()) == .completed(99))
        // A completed entry no longer vends handles (the file was renamed away).
        #expect(board.handle(for: 0) == nil)

        board.commit(index: 1, path: pathB, bytes: 10)
        let h1 = board.handle(for: 1)
        board.abandon(index: 1, path: pathB)
        #expect(h1?.wait(beyond: 0, until: Date()) == .abandoned)
        #expect(board.handle(for: 1) == nil)
    }

    @Test("complete/abandon under a different path are ignored")
    func pathMismatchIgnored() {
        let board = ProgressiveSegmentBoard()
        let path = url("real"), other = url("other")
        board.commit(index: 0, path: path, bytes: 10)
        board.complete(index: 0, path: other, bytes: 999)
        board.abandon(index: 0, path: other)
        let h = board.handle(for: 0)
        #expect(h != nil, "mismatched terminal calls must not kill the live entry")
        #expect(h?.wait(beyond: -1, until: Date()) == .committed(10))
    }

    @Test("a new epoch (same index, new path) wakes the old handle as abandoned")
    func newEpochAbandonsOldHandle() {
        let board = ProgressiveSegmentBoard()
        let old = url("old"), new = url("new")
        board.commit(index: 0, path: old, bytes: 10)
        let oldHandle = board.handle(for: 0)
        board.commit(index: 0, path: new, bytes: 0)
        #expect(oldHandle?.wait(beyond: 0, until: Date()) == .abandoned)
        #expect(board.handle(for: 0)?.path == new)
    }

    @Test("abandonAll terminates every in-production entry")
    func abandonAllTerminates() {
        let board = ProgressiveSegmentBoard()
        board.commit(index: 0, path: url("a"), bytes: 5)
        board.commit(index: 1, path: url("b"), bytes: 5)
        let h0 = board.handle(for: 0), h1 = board.handle(for: 1)
        board.abandonAll()
        #expect(h0?.wait(beyond: 0, until: Date()) == .abandoned)
        #expect(h1?.wait(beyond: 0, until: Date()) == .abandoned)
    }

    @Test("a wait with no progress returns nil at the deadline")
    func waitTimesOut() {
        let board = ProgressiveSegmentBoard()
        board.commit(index: 0, path: url("a"), bytes: 7)
        let h = board.handle(for: 0)
        let start = Date()
        #expect(h?.wait(beyond: 7, until: Date().addingTimeInterval(0.1)) == nil)
        #expect(Date().timeIntervalSince(start) >= 0.09)
    }
}

@Suite("progressive VOD serve: SegmentCache adoption handshake")
struct ProgressiveSegmentCacheTests {

    /// A staging file inside the cache's own session dir, like the muxer leaves it.
    private func stagingFile(in cache: SegmentCache, index: Int, bytes: Int) -> URL {
        let url = cache.sessionDir.appendingPathComponent("staging-seg-\(index)-test.tmp")
        FileManager.default.createFile(atPath: url.path, contents: Data(repeating: 0xAB, count: bytes))
        return url
    }

    @Test("adopt success completes the board entry with the adopted byte count")
    func adoptCompletes() {
        let cache = SegmentCache(forwardWindow: 5, backwardWindow: 5)
        defer { cache.close() }
        let path = stagingFile(in: cache, index: 3, bytes: 64)
        cache.progressive.commit(index: 3, path: path, bytes: 40)
        guard let h = cache.progressive.handle(for: 3) else {
            Issue.record("in-production entry must vend a handle")
            return
        }
        cache.adopt(index: 3, stagingPath: path, byteCount: 64)
        #expect(h.wait(beyond: 40, until: Date()) == .completed(64))
        #expect(cache.progressive.handle(for: 3) == nil)
    }

    @Test("adopt failure abandons the board entry")
    func adoptFailureAbandons() {
        let cache = SegmentCache(forwardWindow: 5, backwardWindow: 5)
        defer { cache.close() }
        // A staging path that does not exist: moveItem throws, adopt fails.
        let path = cache.sessionDir.appendingPathComponent("staging-seg-4-missing.tmp")
        cache.progressive.commit(index: 4, path: path, bytes: 10)
        let h = cache.progressive.handle(for: 4)
        cache.adopt(index: 4, stagingPath: path, byteCount: 10)
        #expect(h?.wait(beyond: 0, until: Date()) == .abandoned)
    }

    @Test("close abandons every in-production entry")
    func closeAbandonsAll() {
        let cache = SegmentCache(forwardWindow: 5, backwardWindow: 5)
        let path = stagingFile(in: cache, index: 2, bytes: 10)
        cache.progressive.commit(index: 2, path: path, bytes: 10)
        let h = cache.progressive.handle(for: 2)
        cache.close()
        #expect(h?.wait(beyond: 0, until: Date()) == .abandoned)
    }
}

@Suite("progressive VOD serve: MP4SegmentMuxer commit boundaries")
struct MP4SegmentMuxerProgressiveCommitTests {

    // MARK: - Harness (same fixture discipline as Issue222EAC3MoovPrimeTests)

    private final class Rig {
        let videoDemuxer = Demuxer()
        let audioDemuxer = Demuxer()
        let sessionDir: URL
        var initBytes: Data?
        var muxer: MP4SegmentMuxer?

        init() throws {
            sessionDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("aeprogmux-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        }

        deinit {
            muxer = nil
            videoDemuxer.close()
            audioDemuxer.close()
            try? FileManager.default.removeItem(at: sessionDir)
        }

        func open(audioFixture: String?) throws {
            try videoDemuxer.open(
                reader: DataIOReader(data: Rig.data(MP4SegmentMuxerProgressiveCommitTests.videoOnlyBase64)),
                formatHint: "mp4"
            )
            if let audioFixture {
                try audioDemuxer.open(reader: DataIOReader(data: Rig.data(audioFixture)), formatHint: "mp4")
            }
        }

        static func data(_ base64: String) -> Data {
            Data(base64Encoded: base64, options: .ignoreUnknownCharacters) ?? Data()
        }

        /// All video packets' payloads from the fixture; re-stamped on write so a tiny fixture can
        /// still span several seconds of muxer time.
        func videoPacketPayloads() throws -> [[UInt8]] {
            var out: [[UInt8]] = []
            let vIndex = videoDemuxer.videoStreamIndex
            while let pkt = try videoDemuxer.readPacket() {
                defer {
                    var p: UnsafeMutablePointer<AVPacket>? = pkt
                    trackedPacketFree(&p)
                }
                guard pkt.pointee.stream_index == vIndex, pkt.pointee.size > 0,
                      let data = pkt.pointee.data else { continue }
                out.append([UInt8](UnsafeBufferPointer(start: data, count: Int(pkt.pointee.size))))
            }
            return out
        }

        func firstAudioFrameBytes() throws -> [UInt8] {
            let idx = audioDemuxer.audioStreamIndex
            while true {
                guard let pkt = try audioDemuxer.readPacket() else { return [] }
                defer {
                    var p: UnsafeMutablePointer<AVPacket>? = pkt
                    trackedPacketFree(&p)
                }
                if pkt.pointee.stream_index == idx, pkt.pointee.size > 0, let data = pkt.pointee.data {
                    return [UInt8](UnsafeBufferPointer(start: data, count: Int(pkt.pointee.size)))
                }
            }
        }

        func makeMuxer(board: ProgressiveSegmentBoard?, withAudio: Bool) throws -> MP4SegmentMuxer {
            guard let vStream = videoDemuxer.stream(at: videoDemuxer.videoStreamIndex) else {
                throw RigError.noVideoStream
            }
            let video = MP4SegmentMuxer.VideoConfig(
                codecpar: UnsafePointer(vStream.pointee.codecpar),
                timeBase: vStream.pointee.time_base,
                codecTagOverride: nil
            )
            var audio: MP4SegmentMuxer.AudioConfig?
            if withAudio, let aStream = audioDemuxer.stream(at: audioDemuxer.audioStreamIndex) {
                audio = MP4SegmentMuxer.AudioConfig(
                    codecpar: UnsafePointer(aStream.pointee.codecpar),
                    timeBase: aStream.pointee.time_base
                )
            }
            let m = try MP4SegmentMuxer(
                initialSegmentIndex: 0,
                sessionDir: sessionDir,
                video: video,
                audio: audio,
                maxBufferedFragmentSeconds: HLSSegmentProducer.progressiveFragmentSeconds,
                progressiveBoard: board,
                onInitCaptured: { [self] bytes in self.initBytes = bytes }
            )
            muxer = m
            return m
        }

        /// Write one video sample at an explicit OUTPUT-TB dts, cycling the fixture's payloads.
        func writeVideoSample(_ payload: [UInt8], dts: Int64, key: Bool,
                              into muxer: MP4SegmentMuxer) throws {
            var pktOpt: UnsafeMutablePointer<AVPacket>? = av_packet_alloc()
            guard let pkt = pktOpt else { throw RigError.noVideoStream }
            defer { av_packet_free(&pktOpt) }
            guard av_new_packet(pkt, Int32(payload.count)) == 0, let dst = pkt.pointee.data else {
                throw RigError.noVideoStream
            }
            payload.withUnsafeBytes { src in
                if let base = src.baseAddress { memcpy(dst, base, payload.count) }
            }
            pkt.pointee.stream_index = muxer.videoOutputStreamIndex
            pkt.pointee.pts = dts
            pkt.pointee.dts = dts
            pkt.pointee.duration = 0
            if key { pkt.pointee.flags |= AV_PKT_FLAG_KEY }
            _ = muxer.writePacket(pkt)
        }

        /// Feed `count` video samples spaced `strideTicks` apart in the muxer's output time base.
        func feedVideo(into muxer: MP4SegmentMuxer, count: Int, strideTicks: Int64) throws {
            let payloads = try videoPacketPayloads()
            guard !payloads.isEmpty else { throw RigError.noVideoStream }
            for i in 0..<count {
                try writeVideoSample(payloads[i % payloads.count],
                                     dts: Int64(i) * strideTicks, key: i == 0, into: muxer)
            }
        }

        func writeAudioFrame(_ frame: [UInt8], dts: Int64, into muxer: MP4SegmentMuxer) throws {
            var pktOpt: UnsafeMutablePointer<AVPacket>? = av_packet_alloc()
            guard let pkt = pktOpt else { throw RigError.noVideoStream }
            defer { av_packet_free(&pktOpt) }
            guard av_new_packet(pkt, Int32(frame.count)) == 0, let dst = pkt.pointee.data else {
                throw RigError.noVideoStream
            }
            frame.withUnsafeBytes { src in
                if let base = src.baseAddress { memcpy(dst, base, frame.count) }
            }
            pkt.pointee.stream_index = muxer.audioOutputStreamIndex
            pkt.pointee.pts = dts
            pkt.pointee.dts = dts
            pkt.pointee.duration = 0
            pkt.pointee.flags |= AV_PKT_FLAG_KEY
            _ = muxer.writePacket(pkt)
        }
    }

    private enum RigError: Error { case noVideoStream }

    private static let videoOnlyBase64 = AtmosDetectionProbeIntegrationTests.videoOnlyBase64
    private static let eac3Base64 = AtmosDetectionProbeIntegrationTests.eac3PlainBase64

    /// True when `bytes` is exactly a sequence of (moof, mdat) pairs with no partial box at the
    /// tail — the invariant a progressive serve needs so AVPlayer never sees a torn fragment.
    private static func isWholeFragmentSequence(_ bytes: [UInt8]) -> Bool {
        func box(at off: Int) -> (size: Int, type: String)? {
            guard off + 8 <= bytes.count else { return nil }
            var size: UInt32 = 0
            for i in 0..<4 { size = (size << 8) | UInt32(bytes[off + i]) }
            let type = String(decoding: bytes[off + 4..<off + 8], as: UTF8.self)
            return (Int(size), type)
        }
        var off = 0
        var pairs = 0
        while off < bytes.count {
            guard let moof = box(at: off), moof.type == "moof", moof.size >= 8 else { return false }
            off += moof.size
            guard let mdat = box(at: off), mdat.type == "mdat", mdat.size >= 8 else { return false }
            off += mdat.size
            pairs += 1
        }
        return off == bytes.count && pairs > 0
    }

    private static func moofCount(_ bytes: [UInt8]) -> Int {
        var count = 0
        var off = 0
        while off + 8 <= bytes.count {
            var size: UInt32 = 0
            for i in 0..<4 { size = (size << 8) | UInt32(bytes[off + i]) }
            let type = String(decoding: bytes[off + 4..<off + 8], as: UTF8.self)
            if type == "moof" { count += 1 }
            guard size >= 8 else { break }
            off += Int(size)
        }
        return count
    }

    /// The board's currently committed byte count for `index` right now (zero-deadline wait reads
    /// the entry without parking; commits are made synchronously inside writePacket).
    private func committedNow(_ board: ProgressiveSegmentBoard, index: Int) -> Int? {
        guard let h = board.handle(for: index) else { return nil }
        guard case .committed(let n) = h.wait(beyond: -1, until: Date()) else { return nil }
        return n
    }

    /// ~0.4 s stride in output ticks, 10 samples = ~4 s of video: several interim flushes at the
    /// 1 s progressive bound. Stride is floored at one tick so a coarse muxer time base still
    /// produces an increasing dts.
    private func feedSpan(rig: Rig, muxer: MP4SegmentMuxer) throws {
        let tb = muxer.muxerVideoTimeBase
        let stride = max(1, Int64(Double(tb.den) * 0.4 / Double(tb.num)))
        try rig.feedVideo(into: muxer, count: 10, strideTicks: stride)
    }

    @Test("every commit lands on a fragment boundary; commits are strictly increasing; adopt covers them all")
    func commitsAreWholeFragments() throws {
        let cache = SegmentCache(forwardWindow: 5, backwardWindow: 5)
        defer { cache.close() }
        let rig = try Rig()
        try rig.open(audioFixture: nil)
        let muxer = try rig.makeMuxer(board: cache.progressive, withAudio: false)

        // Sample the board after every packet: commits are published synchronously inside
        // writePacket, so no watcher thread is needed and nothing can be missed.
        let payloads = try rig.videoPacketPayloads()
        #expect(!payloads.isEmpty, "fixture must contribute video packets")
        let tb = muxer.muxerVideoTimeBase
        let stride = max(1, Int64(Double(tb.den) * 0.4 / Double(tb.num)))
        var commits: [Int] = []
        for i in 0..<10 {
            try rig.writeVideoSample(payloads[i % payloads.count],
                                     dts: Int64(i) * stride, key: i == 0, into: muxer)
            if let n = committedNow(cache.progressive, index: 0), n != commits.last {
                commits.append(n)
            }
        }

        // The cut registers seg-1's staging file at 0 bytes immediately (moov is already flushed).
        guard case .completed(let seg0Path, let seg0Bytes) = muxer.cutFragmentForNextSegment(1) else {
            Issue.record("cut must complete")
            return
        }
        #expect(cache.progressive.handle(for: 1) != nil,
                "cut must register the next staging file right away")
        #expect(cache.progressive.handle(for: 1)?.wait(beyond: -1, until: Date()) == .committed(0))

        let seg0Handle = cache.progressive.handle(for: 0)
        cache.adopt(index: 0, stagingPath: seg0Path, byteCount: seg0Bytes)
        #expect(seg0Handle?.wait(beyond: -1, until: Date()) == .completed(seg0Bytes))

        #expect(commits.count >= 3,
                "a ~4 s segment at a 1 s flush bound must publish several fragments, got \(commits)")
        #expect(zip(commits, commits.dropFirst()).allSatisfy { $0 < $1 },
                "commits must be strictly increasing, got \(commits)")
        #expect((commits.last ?? 0) <= seg0Bytes,
                "the adopted byte count must cover the last published boundary")

        // Every published boundary is a whole number of (moof,mdat) pairs — read from the adopted
        // file (same bytes the staging file carried).
        let adopted = try Data(contentsOf: cache.sessionDir.appendingPathComponent("seg-0.m4s"))
        for n in commits {
            #expect(Self.isWholeFragmentSequence(Array(adopted.prefix(n))),
                    "commit \(n) is not a clean fragment boundary")
        }
        #expect(Self.moofCount(Array(adopted)) >= 3, "one segment must contain multiple moofs")
        #expect(Self.isWholeFragmentSequence(Array(adopted)))
    }

    @Test("no commit is published before moov is flushed (AE#222 EAC3 guard)")
    func noCommitBeforeMoov() throws {
        let board = ProgressiveSegmentBoard()
        let rig = try Rig()
        try rig.open(audioFixture: Self.eac3Base64)
        // No prime: the first segment carries video only, and the EAC3 sample entry needs a parsed
        // packet, so every interim flush must be refused until one audio packet lands.
        let muxer = try rig.makeMuxer(board: board, withAudio: true)

        try feedSpan(rig: rig, muxer: muxer)
        #expect(board.handle(for: 0) == nil,
                "bytes published before moov could be ftruncated by the moov prime")

        let frame = try rig.firstAudioFrameBytes()
        #expect(!frame.isEmpty, "fixture must yield a real EAC3 frame")
        try rig.writeAudioFrame(frame, dts: 0, into: muxer)

        // The audio packet's arrival primes moov via flushPendingFragment, which is also the first
        // publish point.
        guard let h = board.handle(for: 0) else {
            Issue.record("once moov is flushed the staging file must be published")
            return
        }
        guard case .committed(let n) = h.wait(beyond: -1, until: Date()) else {
            Issue.record("expected a committed boundary after the audio-primed flush")
            return
        }
        #expect(n > 0)
        #expect(rig.initBytes != nil, "the same flush emits init.mp4")
    }
}

@Suite("progressive VOD serve: HLSLocalServer chunked relay")
struct HLSLocalServerProgressiveServeTests {

    // MARK: - Stub provider + socket helpers (Issue93SlowSegmentServeTests discipline)

    private final class ProgressiveStubProvider: HLSSegmentProvider, @unchecked Sendable {
        let board = ProgressiveSegmentBoard()
        /// File the "muxer" is producing; the test appends and commits on its own thread.
        let stagingPath: URL
        let fallbackPayload: Data
        private let lock = NSLock()
        private var _progressiveCalls = 0
        var progressiveCalls: Int { lock.lock(); defer { lock.unlock() }; return _progressiveCalls }

        init(stagingPath: URL, fallbackPayload: Data) {
            self.stagingPath = stagingPath
            self.fallbackPayload = fallbackPayload
        }

        func initSegment() -> Data? { Data("ftypinit".utf8) }
        var segmentCount: Int { 4 }
        func segmentDuration(at index: Int) -> Double { 4.0 }
        var playlistType: HLSPlaylistType { .vod }

        func mediaSegmentURL(at index: Int) -> URL? { nil }

        func progressiveSegment(at index: Int) -> ProgressiveSegmentBoard.Handle? {
            lock.lock(); _progressiveCalls += 1; lock.unlock()
            return board.handle(for: index)
        }

        func mediaSegment(at index: Int) -> Data? { fallbackPayload }
        func mediaSegment(at index: Int, onSlow: (@Sendable () -> Void)?) -> Data? {
            fallbackPayload
        }
    }

    private static func rawGET(port: UInt16, path: String, deadline: TimeInterval,
                               extraHeaders: String = "")
    -> (bytes: Data, firstByteAfter: TimeInterval) {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        precondition(fd >= 0)
        defer { close(fd) }
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                connect(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        precondition(connected == 0)
        var tv = timeval(tv_sec: 0, tv_usec: 100_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        let request = "GET \(path) HTTP/1.1\r\nHost: 127.0.0.1\r\n\(extraHeaders)\r\n"
        _ = request.withCString { send(fd, $0, strlen($0), 0) }

        let start = DispatchTime.now()
        var firstByteAfter: TimeInterval = -1
        var collected = Data()
        var lastByteAt = DispatchTime.now()
        var buf = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = recv(fd, &buf, buf.count, 0)
            if n > 0 {
                if firstByteAfter < 0 {
                    firstByteAfter = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e9
                }
                collected.append(contentsOf: buf[0..<n])
                lastByteAt = DispatchTime.now()
            } else if n == 0 {
                break
            } else {
                let idle = Double(DispatchTime.now().uptimeNanoseconds - lastByteAt.uptimeNanoseconds) / 1e9
                if idle > deadline { break }
            }
        }
        return (collected, firstByteAfter)
    }

    private static func splitResponse(_ raw: Data) -> (header: String, body: Data) {
        guard let sep = raw.range(of: Data("\r\n\r\n".utf8)) else { return ("", Data()) }
        let header = String(data: raw[..<sep.lowerBound], encoding: .utf8) ?? ""
        return (header, Data(raw[sep.upperBound...]))
    }

    private static func decodeChunkedBody(_ body: Data) -> Data {
        var out = Data()
        var rest = body
        while let lineEnd = rest.range(of: Data("\r\n".utf8)) {
            let sizeStr = String(data: rest[..<lineEnd.lowerBound], encoding: .utf8) ?? ""
            guard let size = Int(sizeStr.trimmingCharacters(in: .whitespaces), radix: 16) else { break }
            if size == 0 { break }
            let chunkStart = lineEnd.upperBound
            let chunkEnd = rest.index(chunkStart, offsetBy: size, limitedBy: rest.endIndex) ?? rest.endIndex
            out.append(rest[chunkStart..<chunkEnd])
            let afterChunk = rest.index(chunkEnd, offsetBy: 2, limitedBy: rest.endIndex) ?? rest.endIndex
            rest = rest[afterChunk...]
        }
        return out
    }

    private func makeStagingFile() throws -> (dir: URL, path: URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("aeprogserve-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("staging-seg-1-test.tmp")
        FileManager.default.createFile(atPath: path.path, contents: nil)
        return (dir, path)
    }

    @Test("a segment written progressively arrives chunked, identical, first chunk before completion")
    func progressiveDelivery() throws {
        let (dir, path) = try makeStagingFile()
        defer { try? FileManager.default.removeItem(at: dir) }
        let payload = Data((0..<20_000).map { UInt8($0 % 251) })
        let provider = ProgressiveStubProvider(stagingPath: path, fallbackPayload: payload)
        provider.board.commit(index: 1, path: path, bytes: 0)
        let server = HLSLocalServer(provider: provider)
        try server.start()
        defer { server.stop() }

        // Producer thread: append + commit half the segment now, the rest after a beat, then
        // complete — exactly what muxer flush / cache.adopt publish.
        let writer = Thread {
            guard let fh = try? FileHandle(forWritingTo: path) else { return }
            fh.write(payload[0..<8000])
            provider.board.commit(index: 1, path: path, bytes: 8000)
            Thread.sleep(forTimeInterval: 0.4)
            fh.write(payload[8000...])
            provider.board.commit(index: 1, path: path, bytes: payload.count)
            try? fh.close()
            provider.board.complete(index: 1, path: path, bytes: payload.count)
        }
        writer.start()

        let (raw, firstByteAfter) = Self.rawGET(
            port: server.port, path: "/\(server.pathToken)/seg1.mp4", deadline: 2.0)
        while !writer.isFinished { Thread.sleep(forTimeInterval: 0.005) }
        let (header, body) = Self.splitResponse(raw)
        #expect(header.contains("Transfer-Encoding: chunked"))
        #expect(!header.contains("Content-Length"))
        #expect(Self.decodeChunkedBody(body) == payload)
        #expect(firstByteAfter >= 0)
        #expect(firstByteAfter < 0.4,
                "the first chunk must ride the first commit, not the completion (got \(firstByteAfter)s)")
        #expect(body.suffix(5).elementsEqual(Data("0\r\n\r\n".utf8)))
    }

    @Test("abandon after data went out closes the connection with no terminating chunk")
    func abandonAfterDataCloses() throws {
        let (dir, path) = try makeStagingFile()
        defer { try? FileManager.default.removeItem(at: dir) }
        let payload = Data(repeating: 0x42, count: 4096)
        let provider = ProgressiveStubProvider(stagingPath: path, fallbackPayload: payload)
        provider.board.commit(index: 1, path: path, bytes: 0)
        let server = HLSLocalServer(provider: provider)
        try server.start()
        defer { server.stop() }

        let writer = Thread {
            guard let fh = try? FileHandle(forWritingTo: path) else { return }
            fh.write(payload)
            provider.board.commit(index: 1, path: path, bytes: payload.count)
            try? fh.close()
            Thread.sleep(forTimeInterval: 0.3)   // let the serve send it
            provider.board.abandon(index: 1, path: path)
        }
        writer.start()

        let (raw, _) = Self.rawGET(port: server.port, path: "/\(server.pathToken)/seg1.mp4",
                                   deadline: 2.0)
        while !writer.isFinished { Thread.sleep(forTimeInterval: 0.005) }
        let (header, body) = Self.splitResponse(raw)
        #expect(header.contains("Transfer-Encoding: chunked"))
        #expect(Self.decodeChunkedBody(body) == payload)
        #expect(!body.suffix(16).contains(Data("0\r\n\r\n".utf8)),
                "an abandoned serve must look like a dropped connection, not a complete one")
    }

    @Test("abandon before any data falls back to the ordinary serve")
    func abandonBeforeDataFallsBack() throws {
        let (dir, path) = try makeStagingFile()
        defer { try? FileManager.default.removeItem(at: dir) }
        let payload = Data(repeating: 0x77, count: 1024)
        let provider = ProgressiveStubProvider(stagingPath: path, fallbackPayload: payload)
        provider.board.commit(index: 1, path: path, bytes: 0)
        let server = HLSLocalServer(provider: provider)
        try server.start()
        defer { server.stop() }

        let writer = Thread {
            Thread.sleep(forTimeInterval: 0.15)
            provider.board.abandon(index: 1, path: path)
        }
        writer.start()

        let (raw, _) = Self.rawGET(port: server.port, path: "/\(server.pathToken)/seg1.mp4",
                                   deadline: 2.0)
        while !writer.isFinished { Thread.sleep(forTimeInterval: 0.005) }
        let (header, body) = Self.splitResponse(raw)
        // The progressive path wrote nothing, so the legacy mediaSegment serve answered.
        #expect(header.contains("200 OK"))
        #expect(header.contains("Content-Length: \(payload.count)"))
        #expect(body.prefix(payload.count) == payload)
    }

    @Test("a request with a Range header never takes the progressive path")
    func rangeRequestSkipsProgressive() throws {
        let (dir, path) = try makeStagingFile()
        defer { try? FileManager.default.removeItem(at: dir) }
        let payload = Data(repeating: 0x55, count: 2048)
        let provider = ProgressiveStubProvider(stagingPath: path, fallbackPayload: payload)
        provider.board.commit(index: 1, path: path, bytes: 0)
        let server = HLSLocalServer(provider: provider)
        try server.start()
        defer { server.stop() }

        let (raw, _) = Self.rawGET(port: server.port, path: "/\(server.pathToken)/seg1.mp4",
                                   deadline: 1.0, extraHeaders: "Range: bytes=0-100\r\n")
        let (header, body) = Self.splitResponse(raw)
        #expect(provider.progressiveCalls == 0,
                "Range requests must not even consult the progressive board")
        #expect(header.contains("Content-Length: \(payload.count)"))
        #expect(body.prefix(payload.count) == payload)
    }

    @Test("progressiveVODServe=false makes the provider vend no handle (exact legacy behaviour)")
    func killSwitchDisablesHandle() throws {
        let cache = SegmentCache(forwardWindow: 5, backwardWindow: 5)
        defer { cache.close() }
        let path = cache.sessionDir.appendingPathComponent("staging-seg-2-t.tmp")
        FileManager.default.createFile(atPath: path.path, contents: Data(count: 8))
        cache.progressive.commit(index: 2, path: path, bytes: 8)

        let segments = (0..<4).map {
            HLSVideoEngine.Segment(startPts: Int64($0) * 4000, endPts: Int64($0 + 1) * 4000,
                                   startSeconds: Double($0) * 4.0, durationSeconds: 4.0)
        }
        let provider = VideoSegmentProvider(
            cache: cache, segments: segments, codecsString: "hvc1", supplementalCodecs: nil,
            resolution: (1920, 1080), videoRange: .sdr, frameRate: 24.0, hdcpLevel: nil,
            sourceBitrate: 8_000_000,
            restartHandler: { _ in }, restartActivity: { false }
        )

        VideoSegmentProvider.progressiveVODServe = false
        defer { VideoSegmentProvider.progressiveVODServe = true }
        #expect(provider.progressiveSegment(at: 2) == nil)
        VideoSegmentProvider.progressiveVODServe = true
        #expect(provider.progressiveSegment(at: 2)?.path == path)
    }
}
