import Foundation

/// AE#293: reads a live HLS source's video carriage from its playlist and the first segment's PMT, so the
/// #168 verdict is available while the native mount is still inside its watchdog grace instead of 4 s
/// after it. Same evidence chain #268 uses for finite VOD, minus the VOD-only requirements (no
/// EXT-X-ENDLIST, no duration axis), so a rolling live window can be judged as well.
///
/// Never throws: a caller acts on positive evidence only, so every failure collapses to `inconclusive`
/// and leaves the source on the route it is already taking.
enum HLSCarriageProbe {
    /// Bounded like the VOD ingest's playlist fetch: a playlist larger than this is not one the ingest
    /// would serve either.
    static let maximumPlaylistBytes = 2 * 1024 * 1024
    /// Segment head the PMT must appear in; a conforming segment carries PAT and PMT in its first packets.
    static let maximumSegmentHeadBytes = 128 * 1024
    /// Probe verdict granularity: re-inspect after this much fresh payload, packet-aligned.
    static let segmentHeadChunkBytes = 188 * 32

    /// One process-wide session rather than one per probe: an uninvalidated `URLSession` outlives its
    /// caller. The request timeout is short because a verdict that arrives after the watchdog grace has
    /// already been overtaken by the grace it was meant to replace.
    private static let sharedSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        return URLSession(configuration: configuration)
    }()

    private enum PlaylistOutcome {
        case segment(URL)
        case settled(MPEGTransportStreamCodecProbe.Verdict)
    }

    /// Classifies the carriage behind a master or media playlist URL. Costs one playlist fetch for a
    /// media playlist, two for a master, plus a bounded ranged read of one segment head. An `EXT-X-MAP`
    /// settles it as fMP4 before any segment byte is fetched.
    static func classifyLiveCarriage(
        playlistURL: URL,
        httpHeaders: [String: String],
        session: URLSession? = nil
    ) async -> MPEGTransportStreamCodecProbe.Verdict {
        let session = session ?? sharedSession
        do {
            switch try await resolveFirstSegment(
                playlistURL: playlistURL, httpHeaders: httpHeaders, session: session
            ) {
            case .settled(let verdict):
                return verdict
            case .segment(let segmentURL):
                return try await classifySegmentHead(
                    url: segmentURL, httpHeaders: httpHeaders, session: session
                )
            }
        } catch {
            EngineLog.emit("[HLSCarriageProbe] carriage probe inconclusive: \(error)", category: .engine)
            return .inconclusive
        }
    }

    /// Reads the head of a segment and classifies its carriage. The body is streamed and abandoned at the
    /// first definitive verdict, so a conforming segment costs the two packets that carry PAT and PMT
    /// rather than the full ceiling; an origin that ignores the Range request is bounded the same way, by
    /// cancelling the task instead of buffering the segment.
    static func classifySegmentHead(
        url: URL,
        httpHeaders: [String: String],
        session: URLSession
    ) async throws -> MPEGTransportStreamCodecProbe.Verdict {
        var request = makeRequest(url, httpHeaders: httpHeaders)
        request.setValue("bytes=0-\(maximumSegmentHeadBytes - 1)", forHTTPHeaderField: "Range")
        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard status == 200 || status == 206 else {
            throw HLSIngestError.playlistUnreachable(status: status)
        }
        var data = Data()
        data.reserveCapacity(segmentHeadChunkBytes)
        var nextVerdictAt = segmentHeadChunkBytes
        for try await byte in bytes {
            data.append(byte)
            guard data.count >= nextVerdictAt else { continue }
            let verdict = MPEGTransportStreamCodecProbe.classify(data)
            if verdict != .inconclusive { return verdict }
            guard data.count < maximumSegmentHeadBytes else { break }
            nextVerdictAt = min(maximumSegmentHeadBytes, data.count + segmentHeadChunkBytes)
        }
        guard !data.isEmpty else {
            throw HLSIngestError.unsupportedSegmentFormat
        }
        return MPEGTransportStreamCodecProbe.classify(data)
    }

    /// Resolves the playlist down to the segment whose PMT answers the question, or settles the verdict
    /// on playlist evidence alone. The highest-bandwidth variant is the one probed, matching #268: a
    /// master's variants share their carriage, so one answer covers them all.
    private static func resolveFirstSegment(
        playlistURL: URL,
        httpHeaders: [String: String],
        session: URLSession
    ) async throws -> PlaylistOutcome {
        let (root, rootURL) = try await fetchPlaylist(playlistURL, httpHeaders: httpHeaders, session: session)
        let media: HLSMediaPlaylist
        let mediaURL: URL
        switch root {
        case .media(let value):
            media = value
            mediaURL = rootURL
        case .master(let master):
            guard let best = master.variants.max(by: { $0.bandwidth < $1.bandwidth }),
                  let variantURL = HLSPlaylistParser.resolve(uri: best.uri, against: rootURL) else {
                return .settled(.inconclusive)
            }
            let (selected, selectedURL) = try await fetchPlaylist(
                variantURL, httpHeaders: httpHeaders, session: session
            )
            guard case .media(let value) = selected else { return .settled(.inconclusive) }
            media = value
            mediaURL = selectedURL
        }
        // fMP4 carriage is what AVFoundation wants; the playlist says so before a segment is touched.
        guard !media.hasMap else { return .settled(.otherCarriage) }
        // An encrypted segment hides its PMT, and an absence of evidence never reroutes.
        guard let first = media.segments.first,
              first.crypt == nil,
              !media.hasUnsupportedEncryption,
              let segmentURL = HLSPlaylistParser.resolve(uri: first.uri, against: mediaURL) else {
            return .settled(.inconclusive)
        }
        return .segment(segmentURL)
    }

    private static func fetchPlaylist(
        _ url: URL,
        httpHeaders: [String: String],
        session: URLSession
    ) async throws -> (HLSPlaylist, URL) {
        let (data, response) = try await session.data(for: makeRequest(url, httpHeaders: httpHeaders))
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(status) else {
            throw HLSIngestError.playlistUnreachable(status: status)
        }
        guard data.count <= maximumPlaylistBytes, let text = String(data: data, encoding: .utf8) else {
            throw HLSIngestError.playlistInvalid(reason: "playlist is not bounded UTF-8")
        }
        return (try HLSPlaylistParser.parse(text), response.url ?? url)
    }

    private static func makeRequest(_ url: URL, httpHeaders: [String: String]) -> URLRequest {
        var request = URLRequest(url: url)
        for (field, value) in httpHeaders {
            request.setValue(value, forHTTPHeaderField: field)
        }
        return request
    }
}
