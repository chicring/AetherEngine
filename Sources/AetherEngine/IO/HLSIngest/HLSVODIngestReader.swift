import CommonCrypto
import Foundation

/// The reader resolves one immutable ENDLIST playlist and exposes its segments
/// as a blocking MPEG-TS stream. Unlike `HLSLiveIngestReader`, seeks restart the
/// same source at the segment preceding the requested playlist time. Demuxer
/// packet gating then discards frames before the exact target.
///
/// Its seek axis is ELAPSED MEDIA TIME (the EXTINF sum), not the container's PTS: an MPEG-TS VOD
/// carries an arbitrary PTS origin, so `Demuxer` strips that origin before positioning the reader.
final class HLSVODIngestReader: TimeSeekableIOReader, @unchecked Sendable {
    private struct ResolvedMedia {
        let url: URL
        let segments: [HLSMediaSegment]
        let starts: [Double]
        let duration: Double
    }

    /// FIFO ceiling, matched to `HLSLiveIngestReader`: the producer parks here until the demuxer drains.
    private static let maximumBufferedBytes = 16 * 1024 * 1024
    private static let maximumPlaylistBytes = 2 * 1024 * 1024
    /// Carriage-probe ceiling. A conforming muxer repeats PAT + PMT at the head of every segment and
    /// the probe stops at its first definitive verdict, so this bound is only reached by a source that
    /// hides its PMT; 128 KiB is ~700 TS packets deep and keeps the rejected (H.264) case cheap.
    private static let maximumCarriageProbeBytes = 128 * 1024
    /// Probe verdict granularity: re-inspect after this much fresh payload, packet-aligned.
    private static let carriageProbeChunkBytes = 188 * 32
    private static let maxConcurrentSegmentFetches = 4
    /// Segment bytes the prefetch window may hold in memory. 4K VOD segments run 15-25 MB, so a fixed
    /// window of four would peak near 100 MB on a device that also holds decode buffers; the window
    /// narrows once the first segment's real size is known (AE#255: bound by bytes, not by count).
    private static let maximumInFlightBytes = 24 * 1024 * 1024

    private let playlistURL: URL
    private let httpHeaders: [String: String]
    private let session: URLSession
    private let ownsSession: Bool
    private let condition = NSCondition()
    private let keyCacheLock = NSLock()
    private var keyCache: [String: Data] = [:]

    private var resolved: ResolvedMedia?
    private var queue: [Data] = []
    private var headOffset = 0
    private var bufferedBytes = 0
    private var bytePosition: Int64 = 0
    private var generation: UInt64 = 0
    private var started = false
    private var finished = false
    private var failed = false
    private var closed = false
    private var producer: Task<Void, Never>?
    /// Playlist index the running producer opened at; lets a reposition onto that same segment, before
    /// any byte was consumed, resolve without refetching it.
    private var producerStartIndex: Int?

    init(
        playlistURL: URL,
        httpHeaders: [String: String],
        session: URLSession? = nil
    ) {
        self.playlistURL = playlistURL
        self.httpHeaders = httpHeaders
        if let session {
            self.session = session
            ownsSession = false
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 15
            configuration.timeoutIntervalForResource = 45
            configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            configuration.urlCache = nil
            self.session = URLSession(configuration: configuration)
            ownsSession = true
        }
    }

    /// Returns a pre-resolved reader only when the finite playlist has positive
    /// content evidence for HEVC in MPEG-TS. Unknown, live, fMP4, H.264 and
    /// demuxed-audio shapes stay on the existing native remote-HLS route.
    static func makeIfHEVCMPEGTS(
        playlistURL: URL,
        httpHeaders: [String: String],
        session: URLSession? = nil
    ) async throws -> HLSVODIngestReader? {
        let reader = HLSVODIngestReader(
            playlistURL: playlistURL,
            httpHeaders: httpHeaders,
            session: session
        )
        var accepted = false
        defer {
            if !accepted { reader.close() }
        }
        do {
            let media = try await reader.resolveMedia()
            guard let first = media.segments.first,
                  first.crypt == nil,
                  let segmentURL = HLSPlaylistParser.resolve(
                    uri: first.uri,
                    against: media.url
                  ) else {
                return nil
            }
            guard try await reader.probeCarriage(segmentURL) == .hevcInMPEGTS else {
                return nil
            }
            reader.condition.withLock {
                reader.resolved = media
            }
            accepted = true
            return reader
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if Task.isCancelled { throw CancellationError() }
            EngineLog.emit(
                "[HLSVODIngest] carriage probe inconclusive: \(error)",
                category: .engine
            )
            return nil
        }
    }

    var mediaDuration: Double {
        condition.withLock { resolved?.duration ?? 0 }
    }

    func read(_ buffer: UnsafeMutablePointer<UInt8>?, size: Int32) -> Int32 {
        guard let buffer, size > 0 else { return -1 }
        startIfNeeded()
        condition.lock()
        defer { condition.unlock() }
        while queue.isEmpty, !finished, !failed, !closed {
            condition.wait()
        }
        guard !failed, !closed else { return -1 }
        guard !queue.isEmpty else { return 0 }

        let available = queue[0].count - headOffset
        let count = min(available, Int(size))
        queue[0].withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            buffer.update(
                from: base.assumingMemoryBound(to: UInt8.self)
                    .advanced(by: headOffset),
                count: count
            )
        }
        headOffset += count
        bufferedBytes -= count
        bytePosition += Int64(count)
        if headOffset == queue[0].count {
            queue.removeFirst()
            headOffset = 0
        }
        condition.broadcast()
        return Int32(count)
    }

    /// Byte seeks are deliberately unsupported: the concatenated segment stream has no address space
    /// the reader could honour, and claiming one would let libavformat binary-search over HTTP. Only a
    /// no-op reposition succeeds, which is what `CustomIOReaderBridge.open`'s SEEK_SET(0) capability
    /// handshake asks at position 0; answering 0 unconditionally would report a rewind that never
    /// happened. Real positioning crosses the `TimeSeekableIOReader` seam in `Demuxer`.
    func seek(offset: Int64, whence: Int32) -> Int64 {
        condition.withLock {
            if whence == SEEK_SET, offset == bytePosition { return bytePosition }
            if whence == SEEK_CUR, offset == 0 { return bytePosition }
            return -1
        }
    }

    func seek(to seconds: Double) -> Bool {
        guard seconds.isFinite, seconds >= 0 else { return false }
        startIfNeeded()

        condition.lock()
        while resolved == nil, !failed, !closed {
            condition.wait()
        }
        guard let resolved, !failed, !closed else {
            condition.unlock()
            return false
        }
        let startIndex = Self.restartSegmentIndex(forElapsed: seconds, starts: resolved.starts)
        // A reposition onto the segment the running producer opened at, with nothing consumed since,
        // is where the ingest already stands. Scrub churn lands here: consecutive targets inside one
        // segment would otherwise cancel and refetch that segment per reposition.
        if startIndex == producerStartIndex, bytePosition == 0, !finished {
            condition.unlock()
            return true
        }
        let previous = producer
        generation &+= 1
        let currentGeneration = generation
        queue.removeAll(keepingCapacity: true)
        headOffset = 0
        bufferedBytes = 0
        bytePosition = 0
        finished = false
        failed = false
        producerStartIndex = startIndex
        producer = Task.detached(priority: .userInitiated) { [self] in
            await produce(
                resolved: resolved,
                startIndex: startIndex,
                generation: currentGeneration
            )
        }
        condition.broadcast()
        condition.unlock()
        previous?.cancel()

        let targetText = String(format: "%.2f", seconds)
        let startText = String(format: "%.2f", resolved.starts[startIndex])
        EngineLog.emit(
            "[HLSVODIngest] seek elapsed=\(targetText)s "
                + "segment=\(startIndex) segmentStart=\(startText)s",
            category: .engine
        )
        return true
    }

    /// Segment the ingest restarts at for `elapsed` seconds of media time: the segment containing the
    /// target, minus one. A playlist need not declare EXT-X-INDEPENDENT-SEGMENTS, so the extra segment
    /// buys the decoder a random-access point ahead of the target; landing early is the reader's
    /// contract and the engine's packet gate drops what precedes the exact target. A target past the
    /// end clamps to the last segment rather than failing, which keeps a rounding overshoot at the
    /// final boundary playable.
    static func restartSegmentIndex(forElapsed elapsed: Double, starts: [Double]) -> Int {
        guard !starts.isEmpty else { return 0 }
        let containing = starts.lastIndex(where: { $0 <= elapsed }) ?? 0
        return max(0, containing - 1)
    }

    func cancel() {
        condition.lock()
        failed = true
        let task = producer
        producer = nil
        condition.broadcast()
        condition.unlock()
        task?.cancel()
    }

    func close() {
        condition.lock()
        guard !closed else {
            condition.unlock()
            return
        }
        closed = true
        let task = producer
        producer = nil
        queue.removeAll()
        bufferedBytes = 0
        condition.broadcast()
        condition.unlock()
        task?.cancel()
        if ownsSession {
            session.invalidateAndCancel()
        }
    }

    /// No independent cursor: a second reader would mean a second full HTTP ingest of the same VOD
    /// (its own playlist resolve, its own segment fetches from wherever it is positioned), and the
    /// features that ask for one, side-demuxed subtitles and scrub previews, are not worth that
    /// bandwidth on a source the host is already streaming once. The engine skips them for nil.
    func makeIndependentReader() -> IOReader? { nil }

    private func startIfNeeded() {
        condition.lock()
        guard !started, !closed else {
            condition.unlock()
            return
        }
        started = true
        generation &+= 1
        let currentGeneration = generation
        let preResolved = resolved
        producerStartIndex = 0
        producer = Task.detached(priority: .userInitiated) { [self] in
            do {
                let media: ResolvedMedia
                if let preResolved {
                    media = preResolved
                } else {
                    media = try await resolveMedia()
                }
                let accepted = condition.withLock { () -> Bool in
                    guard generation == currentGeneration, !closed else {
                        return false
                    }
                    resolved = media
                    condition.broadcast()
                    return true
                }
                guard accepted else {
                    return
                }
                let durationText = String(format: "%.2f", media.duration)
                EngineLog.emit(
                    "[HLSVODIngest] resolved finite MPEG-TS VOD segments=\(media.segments.count) "
                        + "duration=\(durationText)s",
                    category: .engine
                )
                await produce(
                    resolved: media,
                    startIndex: 0,
                    generation: currentGeneration
                )
            } catch is CancellationError {
            } catch {
                fail(error, generation: currentGeneration)
            }
        }
        condition.unlock()
    }

    private func produce(
        resolved: ResolvedMedia,
        startIndex: Int,
        generation: UInt64
    ) async {
        do {
            let remaining = Array(resolved.segments[startIndex...])
            try await ingestSegmentBatch(
                remaining,
                mediaURL: resolved.url,
                generation: generation
            )
            condition.withLock {
                if self.generation == generation, !closed {
                    finished = true
                    producer = nil
                    condition.broadcast()
                }
            }
        } catch is CancellationError {
        } catch {
            fail(error, generation: generation)
        }
    }

    /// Prefetch depth for an observed segment size: the count cap, narrowed so the segments held in
    /// memory stay inside `maximumInFlightBytes`, never below one.
    static func prefetchWindow(forSegmentBytes bytes: Int) -> Int {
        guard bytes > 0 else { return maxConcurrentSegmentFetches }
        return max(1, min(maxConcurrentSegmentFetches, maximumInFlightBytes / bytes))
    }

    private func ingestSegmentBatch(
        _ segments: [HLSMediaSegment],
        mediaURL: URL,
        generation: UInt64
    ) async throws {
        let resolvedSegments: [(HLSMediaSegment, URL)] = try segments.map { segment in
            guard let url = HLSPlaylistParser.resolve(uri: segment.uri, against: mediaURL) else {
                throw HLSIngestError.playlistInvalid(reason: "unresolvable segment URI")
            }
            return (segment, url)
        }

        try await withThrowingTaskGroup(of: (Int, Data).self) { group in
            var nextToSpawn = 0
            var nextToCommit = 0
            var ready: [Int: Data] = [:]

            func spawn(_ index: Int) {
                let item = resolvedSegments[index]
                group.addTask {
                    let bytes = try await self.fetch(item.1)
                    guard let crypt = item.0.crypt else { return (index, bytes) }
                    return (
                        index,
                        try await self.decrypt(bytes, crypt: crypt, baseURL: mediaURL)
                    )
                }
            }

            var window = Self.maxConcurrentSegmentFetches
            while nextToSpawn < resolvedSegments.count, nextToSpawn < window {
                spawn(nextToSpawn)
                nextToSpawn += 1
            }
            while nextToCommit < resolvedSegments.count {
                try Task.checkCancellation()
                guard let (index, bytes) = try await group.next() else { break }
                ready[index] = bytes
                while let head = ready.removeValue(forKey: nextToCommit) {
                    if nextToCommit == 0 {
                        guard LiveSegmentFormat.classify(head) == .mpegts else {
                            throw HLSIngestError.unsupportedSegmentFormat
                        }
                        window = Self.prefetchWindow(forSegmentBytes: head.count)
                    }
                    nextToCommit += 1
                    guard append(head, generation: generation) else {
                        group.cancelAll()
                        return
                    }
                    while nextToSpawn < resolvedSegments.count,
                          nextToSpawn < nextToCommit + window {
                        spawn(nextToSpawn)
                        nextToSpawn += 1
                    }
                }
            }
        }
    }

    private func append(_ data: Data, generation: UInt64) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        while self.generation == generation,
              !closed,
              bufferedBytes >= Self.maximumBufferedBytes {
            condition.wait()
        }
        guard self.generation == generation, !closed else { return false }
        queue.append(data)
        bufferedBytes += data.count
        condition.broadcast()
        return true
    }

    private func fail(_ error: Error, generation: UInt64) {
        condition.lock()
        guard self.generation == generation, !closed else {
            condition.unlock()
            return
        }
        failed = true
        producer = nil
        condition.broadcast()
        condition.unlock()
        EngineLog.emit("[HLSVODIngest] terminal: \(error)", category: .engine)
    }

    private func resolveMedia() async throws -> ResolvedMedia {
        let (root, rootURL) = try await fetchPlaylist(playlistURL)
        let media: HLSMediaPlaylist
        let mediaURL: URL
        switch root {
        case .media(let value):
            media = value
            mediaURL = rootURL
        case .master(let master):
            guard let best = master.variants.max(by: { $0.bandwidth < $1.bandwidth }),
                  best.audioGroupID == nil,
                  let url = HLSPlaylistParser.resolve(uri: best.uri, against: rootURL) else {
                throw HLSIngestError.demuxedAudioNotSupported
            }
            let (selected, selectedURL) = try await fetchPlaylist(url)
            guard case .media(let value) = selected else {
                throw HLSIngestError.playlistInvalid(reason: "selected variant is not a media playlist")
            }
            media = value
            mediaURL = selectedURL
        }

        guard media.hasEndList else {
            throw HLSIngestError.playlistInvalid(reason: "finite VOD requires EXT-X-ENDLIST")
        }
        guard !media.hasMap else { throw HLSIngestError.unsupportedSegmentFormat }
        guard !media.hasUnsupportedEncryption else {
            throw HLSIngestError.encryptedNotSupported
        }
        var starts: [Double] = []
        starts.reserveCapacity(media.segments.count)
        var duration = 0.0
        for segment in media.segments {
            guard segment.duration.isFinite, segment.duration > 0 else {
                throw HLSIngestError.playlistInvalid(reason: "segment duration must be positive")
            }
            starts.append(duration)
            duration += segment.duration
        }
        return ResolvedMedia(
            url: mediaURL,
            segments: media.segments,
            starts: starts,
            duration: duration
        )
    }

    private func makeRequest(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        for (field, value) in httpHeaders {
            request.setValue(value, forHTTPHeaderField: field)
        }
        return request
    }

    private func fetchPlaylist(_ url: URL) async throws -> (HLSPlaylist, URL) {
        let (data, response) = try await session.data(for: makeRequest(url))
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(status) else {
            throw HLSIngestError.playlistUnreachable(status: status)
        }
        guard data.count <= Self.maximumPlaylistBytes,
              let text = String(data: data, encoding: .utf8) else {
            throw HLSIngestError.playlistInvalid(reason: "playlist is not bounded UTF-8")
        }
        return (try HLSPlaylistParser.parse(text), response.url ?? url)
    }

    private func fetch(_ url: URL) async throws -> Data {
        let (data, response) = try await session.data(for: makeRequest(url))
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(status), !data.isEmpty else {
            throw HLSIngestError.playlistUnreachable(status: status)
        }
        return data
    }

    /// Reads the head of the first segment and classifies its carriage. The body is streamed and
    /// abandoned at the first definitive verdict, so a conforming segment costs the two packets that
    /// carry PAT and PMT rather than the full ceiling; an origin that ignores the Range request is
    /// bounded the same way, by cancelling the task instead of buffering the segment.
    private func probeCarriage(_ url: URL) async throws -> MPEGTransportStreamCodecProbe.Verdict {
        var request = makeRequest(url)
        request.setValue(
            "bytes=0-\(Self.maximumCarriageProbeBytes - 1)",
            forHTTPHeaderField: "Range"
        )
        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard status == 200 || status == 206 else {
            throw HLSIngestError.playlistUnreachable(status: status)
        }
        var data = Data()
        data.reserveCapacity(Self.carriageProbeChunkBytes)
        var nextVerdictAt = Self.carriageProbeChunkBytes
        for try await byte in bytes {
            data.append(byte)
            guard data.count >= nextVerdictAt else { continue }
            let verdict = MPEGTransportStreamCodecProbe.classify(data)
            if verdict != .inconclusive { return verdict }
            guard data.count < Self.maximumCarriageProbeBytes else { break }
            nextVerdictAt = min(
                Self.maximumCarriageProbeBytes,
                data.count + Self.carriageProbeChunkBytes
            )
        }
        guard !data.isEmpty else {
            throw HLSIngestError.unsupportedSegmentFormat
        }
        return MPEGTransportStreamCodecProbe.classify(data)
    }

    private func decrypt(
        _ ciphertext: Data,
        crypt: HLSSegmentCrypt,
        baseURL: URL
    ) async throws -> Data {
        guard let keyURL = HLSPlaylistParser.resolve(uri: crypt.keyURI, against: baseURL) else {
            throw HLSIngestError.segmentDecryptFailed(reason: "unresolvable key URI")
        }
        let key: Data
        if let cached = keyCacheLock.withLock({ keyCache[keyURL.absoluteString] }) {
            key = cached
        } else {
            let fetched = try await fetch(keyURL)
            guard fetched.count == kCCKeySizeAES128 else {
                throw HLSIngestError.segmentDecryptFailed(reason: "key length is not 16 bytes")
            }
            keyCacheLock.withLock { keyCache[keyURL.absoluteString] = fetched }
            key = fetched
        }
        guard let plaintext = HLSSegmentDecryptor.decryptAES128CBC(
            ciphertext,
            key: key,
            iv: crypt.iv
        ) else {
            throw HLSIngestError.segmentDecryptFailed(reason: "AES-128-CBC failed")
        }
        return plaintext
    }
}

/// Bounded MPEG-TS PMT inspection. HEVC is stream_type 0x24; no URL suffix or
/// response MIME type is treated as codec evidence.
enum MPEGTransportStreamCodecProbe {
    private static let packetSize = 188
    private static let hevcStreamType: UInt8 = 0x24

    enum Verdict: Equatable {
        /// PMT declares HEVC: AVFoundation builds no video track for this carriage (HLS Authoring
        /// Spec sanctions HEVC only in fMP4), so the source belongs on the ingest.
        case hevcInMPEGTS
        /// Not MPEG-TS at all, or a PMT that declares something AVPlayer carries itself.
        case otherCarriage
        /// Not enough evidence yet; read further or, at the ceiling, leave the source on its route.
        case inconclusive
    }

    /// Definitive as soon as one complete PMT section has been read; `inconclusive` while the head
    /// still parses as TS but no PMT has appeared. Callers treat a final `inconclusive` like
    /// `otherCarriage`: the reroute needs positive evidence, never an absence of it.
    static func classify(_ data: Data) -> Verdict {
        guard !data.isEmpty else { return .inconclusive }
        guard LiveSegmentFormat.classify(data) == .mpegts else { return .otherCarriage }
        let bytes = [UInt8](data)
        guard bytes.count >= packetSize else { return .inconclusive }
        var packetStart = 0
        var sawPMT = false
        while packetStart + packetSize <= bytes.count {
            guard bytes[packetStart] == 0x47 else { return .otherCarriage } // lost packet alignment
            switch programMapVerdict(bytes, packetStart: packetStart) {
            case .hevcInMPEGTS: return .hevcInMPEGTS
            case .otherCarriage: sawPMT = true
            case .inconclusive: break
            }
            packetStart += packetSize
        }
        return sawPMT ? .otherCarriage : .inconclusive
    }

    /// One packet's contribution: `inconclusive` unless it opens a PMT section, which is then read for
    /// an HEVC elementary stream. A PMT split across packets is only judged on its first packet; a
    /// declaration hiding past that boundary reads as `otherCarriage` and keeps the native route.
    private static func programMapVerdict(
        _ bytes: [UInt8],
        packetStart: Int
    ) -> Verdict {
        guard bytes[packetStart + 1] & 0x40 != 0 else { return .inconclusive } // payload_unit_start
        let adaptationControl = (bytes[packetStart + 3] >> 4) & 0x03
        guard adaptationControl == 1 || adaptationControl == 3 else { return .inconclusive }
        var payload = packetStart + 4
        let packetEnd = packetStart + packetSize
        if adaptationControl == 3 {
            payload += 1 + Int(bytes[payload])
            guard payload < packetEnd else { return .inconclusive }
        }
        payload += 1 + Int(bytes[payload]) // pointer_field
        guard payload + 12 <= packetEnd, bytes[payload] == 0x02 else { return .inconclusive }

        let sectionLength =
            (Int(bytes[payload + 1] & 0x0F) << 8)
                | Int(bytes[payload + 2])
        let sectionEnd = min(packetEnd, payload + 3 + sectionLength - 4)
        let programInfoLength =
            (Int(bytes[payload + 10] & 0x0F) << 8)
                | Int(bytes[payload + 11])
        var stream = payload + 12 + programInfoLength
        while stream + 5 <= sectionEnd {
            if bytes[stream] == hevcStreamType { return .hevcInMPEGTS }
            let infoLength =
                (Int(bytes[stream + 3] & 0x0F) << 8)
                    | Int(bytes[stream + 4])
            stream += 5 + infoLength
        }
        return .otherCarriage
    }
}

private extension NSCondition {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
