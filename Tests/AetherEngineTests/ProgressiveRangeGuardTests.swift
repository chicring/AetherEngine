import Testing
import Foundation
@testable import AetherEngine

/// Range guard on progressive delivery: a byte-range request into a segment still being written
/// must not take the progressive reader path (a chunked transfer cannot express Content-Range),
/// so it falls back to the blocking whole-segment fetch and the responder applies the range.
@Suite("Progressive Range guard", .serialized)
struct ProgressiveRangeGuardTests {

    private func makeCache() -> SegmentCache {
        SegmentCache(baseDirectory: FileManager.default.temporaryDirectory
            .appendingPathComponent("progrange-\(UUID().uuidString)", isDirectory: true))
    }

    private func makeStaging(_ cache: SegmentCache, index: Int) throws -> (URL, FileHandle) {
        let url = cache.sessionDir.appendingPathComponent("staging-seg-\(index)-\(UUID().uuidString.prefix(8)).tmp")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        return (url, try FileHandle(forWritingTo: url))
    }

    /// Provider that records which of the two serve methods a request took.
    private final class RecordingProvider: HLSSegmentProvider, @unchecked Sendable {
        let cache: SegmentCache
        var sawProgressive = false
        var mediaSegmentCalls = 0
        var sourceCalls = 0
        init(cache: SegmentCache) { self.cache = cache }
        func initSegment() -> Data? { Data("ftypinit".utf8) }
        var segmentCount: Int { 4 }
        func segmentDuration(at index: Int) -> Double { 4.0 }
        var playlistType: HLSPlaylistType { .vod }
        func mediaSegment(at index: Int) -> Data? {
            VideoSegmentProvider.drain(mediaSegmentSource(at: index, onSlow: nil))
        }
        func mediaSegment(at index: Int, onSlow: (@Sendable () -> Void)?) -> Data? {
            mediaSegmentCalls += 1
            // The blocking whole-segment answer a Range request is routed to. Returns bytes
            // directly rather than through mediaSegmentSource so the two counters stay separate.
            return Data((0..<8192).map { UInt8(truncatingIfNeeded: $0) })
        }
        func mediaSegmentSource(at index: Int, onSlow: (@Sendable () -> Void)?) -> SegmentSource? {
            sourceCalls += 1
            return cache.fetchSource(index: index, timeout: 2, progressive: true)
        }
        func didDeliverProgressiveChunk(index: Int) { sawProgressive = true }
    }

    /// A Range request against a segment being written must not stream it progressively: the
    /// responder would send the whole body chunked instead of the requested 206 byte range.
    @Test("a Range request does not take the progressive path", .timeLimit(.minutes(1)))
    func rangeRequestSkipsProgressive() async throws {
        let cache = makeCache()
        defer { cache.close() }
        let (staging, handle) = try makeStaging(cache, index: 1)
        defer { try? handle.close() }
        let body = Data((0..<8192).map { UInt8(truncatingIfNeeded: $0) })
        handle.write(body)
        try handle.close()
        cache.beginInProgress(index: 1, stagingPath: staging)
        // Seal it so the plain cache path can also answer: the guard is what keeps the request off
        // the progressive branch, not the absence of a sealed segment.
        cache.adopt(index: 1, stagingPath: staging, byteCount: body.count)

        let provider = RecordingProvider(cache: cache)
        let server = HLSLocalServer(provider: provider)
        try server.start()
        defer { server.stop() }

        let raw = await Self.getWithRange(port: server.port, path: "/\(server.pathToken)/seg1.mp4",
                                          range: "bytes=0-1023")
        // Only the head is UTF-8 text; the body is arbitrary segment bytes, so decode up to the
        // header terminator rather than the whole response (the whole buffer fails UTF-8 decoding).
        let headEnd = raw.range(of: Data("\r\n\r\n".utf8))?.upperBound ?? min(raw.count, 4096)
        let header = String(data: raw.prefix(headEnd), encoding: .utf8) ?? ""
        // The guard keeps the Range fetch on the blocking whole-segment path, so the answer is a
        // length-delimited 200, never the progressive chunked body a byte range cannot ride on.
        // (This server answers a local segment's Range with a 200; a 206 only ever comes back from
        // an origin relay.)
        #expect(header.contains("200"),
                "a Range request got no usable response: \(header)")
        #expect(!header.contains("Transfer-Encoding: chunked"),
                "a Range request must not take the chunked progressive body: \(header)")
        // The guard routes a Range request to mediaSegment(at:onSlow:), not mediaSegmentSource.
        #expect(provider.mediaSegmentCalls == 1 && provider.sourceCalls == 0,
                "a Range request must take mediaSegment(at:onSlow:), got seg=\(provider.mediaSegmentCalls) src=\(provider.sourceCalls)")
        #expect(!provider.sawProgressive,
                "the progressive chunk counter must not move on a Range request")
        withExtendedLifetime(provider) {}
    }

    private static func getWithRange(port: UInt16, path: String, range: String?) async -> Data {
        await withCheckedContinuation { continuation in
            Thread.detachNewThread {
                let fd = socket(AF_INET, SOCK_STREAM, 0)
                precondition(fd >= 0)
                defer { close(fd) }
                var noSigPipe: Int32 = 1
                setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
                var addr = sockaddr_in()
                addr.sin_family = sa_family_t(AF_INET)
                addr.sin_port = port.bigEndian
                addr.sin_addr.s_addr = inet_addr("127.0.0.1")
                let conn = withUnsafePointer(to: &addr) { ptr in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
                precondition(conn == 0)
                var tv = timeval(tv_sec: 0, tv_usec: 100_000)
                setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
                var request = "GET \(path) HTTP/1.1\r\nHost: 127.0.0.1\r\n"
                if let range { request += "Range: \(range)\r\n" }
                request += "\r\n"
                _ = request.withCString { send(fd, $0, strlen($0), 0) }
                var collected = Data()
                var buf = [UInt8](repeating: 0, count: 64 * 1024)
                var lastByteAt = DispatchTime.now()
                while true {
                    let n = recv(fd, &buf, buf.count, 0)
                    if n > 0 {
                        collected.append(contentsOf: buf[0..<n])
                        lastByteAt = DispatchTime.now()
                        // A chunked body ends at the zero-length trailer; a length-delimited 200
                        // ends once Content-Length bytes past the header have arrived.
                        if collected.range(of: Data("\r\n0\r\n\r\n".utf8)) != nil { break }
                        if let headEnd = collected.range(of: Data("\r\n\r\n".utf8)),
                           let cl = Self.contentLength(in: collected.prefix(headEnd.lowerBound)),
                           collected.count - headEnd.upperBound >= cl { break }
                    } else if n == 0 {
                        break
                    } else if Double(DispatchTime.now().uptimeNanoseconds - lastByteAt.uptimeNanoseconds) / 1e9 > 5 {
                        break
                    }
                }
                continuation.resume(returning: collected)
            }
        }
    }

    private static func contentLength(in head: Data.SubSequence) -> Int? {
        guard let text = String(data: head, encoding: .utf8) else { return nil }
        for line in text.components(separatedBy: "\r\n")
        where line.lowercased().hasPrefix("content-length:") {
            return Int(line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces))
        }
        return nil
    }
}
