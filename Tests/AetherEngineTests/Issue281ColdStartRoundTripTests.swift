import Testing
import Foundation
@testable import AetherEngine

/// #281: opening a non-faststart MP4 cost three sequential round trips before the frame rate was
/// known: the data connection from byte zero, a reconnect to the trailing `moov`, and a third one
/// back to the first sample. The second is inherent to the layout, the third was not: the seek to
/// the tail discarded a window that already held the bytes the return trip went back for.
///
/// These tests work in byte offsets rather than through a real container, so they pin the reader's
/// behaviour rather than one fixture's box layout.
@Suite("Cold-start round trips (#281)")
struct Issue281ColdStartRoundTripTests {

    private let fileSize: Int64 = 512 * 1024 * 1024

    private func makeReader(_ server: ThrottledOriginServer) -> AVIOReader {
        AVIOReader(url: URL(string: "http://127.0.0.1:\(server.port)/movie.bin")!)
    }

    private func read(_ reader: AVIOReader, _ size: Int) -> Int32 {
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
        defer { buf.deallocate() }
        return reader.read(into: buf, size: Int32(size))
    }

    /// Waits for the speculative fetch, which by design nothing blocks on.
    private func waitForTailSpan(_ server: ThrottledOriginServer, tailStart: Int64) async {
        for _ in 0..<100 {
            if server.requestedRanges.contains(where: { $0.start == tailStart }) { return }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    @Test("open issues a suffix range for the tail alongside the data connection")
    func openPrefetchesTail() async throws {
        let server = try #require(ThrottledOriginServer(totalSize: fileSize))
        defer { server.stop() }
        let reader = makeReader(server)
        defer { reader.markClosed(); reader.close() }
        try reader.open()

        let tailStart = fileSize - Int64(AVIOReader.tailPrefetchBytes)
        await waitForTailSpan(server, tailStart: tailStart)

        let tail = try #require(server.requestedRanges.first(where: { $0.start == tailStart }),
                                "no tail prefetch was issued: \(server.requestedRanges)")
        #expect(tail.end == fileSize - 1)
    }

    /// The half that removes a whole round trip on the reporter's source: the trailing object is
    /// read without the reader ever connecting to it.
    @Test("a read inside the prefetched tail costs no additional request")
    func tailReadIsServedFromThePrefetch() async throws {
        let server = try #require(ThrottledOriginServer(totalSize: fileSize))
        defer { server.stop() }
        let reader = makeReader(server)
        defer { reader.markClosed(); reader.close() }
        try reader.open()
        _ = read(reader, 64 * 1024)   // head, as a demuxer walking the box chain would

        let tailStart = fileSize - Int64(AVIOReader.tailPrefetchBytes)
        await waitForTailSpan(server, tailStart: tailStart)
        let requestsBefore = server.rangeRequestCount

        #expect(reader.seek(offset: tailStart + 1024, whence: SEEK_SET) == tailStart + 1024)
        let got = read(reader, 4096)

        #expect(got == 4096, "tail read returned \(got)")
        #expect(server.rangeRequestCount == requestsBefore,
                "tail read opened a connection despite the prefetch: \(server.requestedRanges)")
    }

    /// The other half: after a parse seek to the tail, coming back to the head is a copy out of the
    /// parked window rather than a third connection.
    @Test("returning to the head after a parse seek costs no additional request")
    func returnTripIsServedFromTheParkedWindow() async throws {
        let server = try #require(ThrottledOriginServer(totalSize: fileSize))
        defer { server.stop() }
        let reader = makeReader(server)
        defer { reader.markClosed(); reader.close() }
        try reader.open()
        _ = read(reader, 1 * 1024 * 1024)   // fill the window at the head

        // A parse seek far enough forward to leave the window and force a reconnect, but NOT into
        // the prefetched tail, so this exercises the parked window rather than the tail span.
        let farOffset = fileSize / 2
        #expect(reader.seek(offset: farOffset, whence: SEEK_SET) == farOffset)
        _ = read(reader, 64 * 1024)
        let requestsAfterSeek = server.rangeRequestCount

        // Back to the head, where the demuxer reads the first sample.
        #expect(reader.seek(offset: 4096, whence: SEEK_SET) == 4096)
        let got = read(reader, 32 * 1024)

        #expect(got == 32 * 1024, "return read returned \(got)")
        #expect(server.rangeRequestCount == requestsAfterSeek,
                "the return trip reconnected instead of using the parked window: \(server.requestedRanges)")
    }

    /// The parked window is an open-phase device. Once the demuxer is parsing no more, a far seek is
    /// a scrub, whose landing zone the old window cannot serve, and holding it would be pure cost.
    @Test("after the open phase the window is no longer parked")
    func parkingStopsAfterTheOpenPhase() async throws {
        let server = try #require(ThrottledOriginServer(totalSize: fileSize))
        defer { server.stop() }
        let reader = makeReader(server)
        defer { reader.markClosed(); reader.close() }
        try reader.open()
        _ = read(reader, 1 * 1024 * 1024)

        reader.markOpenPhaseFinished()

        let farOffset = fileSize / 2
        #expect(reader.seek(offset: farOffset, whence: SEEK_SET) == farOffset)
        _ = read(reader, 64 * 1024)
        let requestsAfterSeek = server.rangeRequestCount

        #expect(reader.seek(offset: 4096, whence: SEEK_SET) == 4096)
        _ = read(reader, 32 * 1024)

        #expect(server.rangeRequestCount > requestsAfterSeek,
                "the window was still parked after the open phase ended")
    }

    /// Suffix ranges are not universally implemented. An origin that does not do them answers the
    /// speculative request with 200 and the WHOLE file, and a speculative optimisation that
    /// downloads a feature film to discard it is worse than the round trip it saves. The fetch has
    /// to hang up at the response header, before the body.
    @Test("an origin that answers a suffix range with the whole file is hung up on at the header")
    func wholeFileAnswerIsRejectedAtTheHeader() async throws {
        let declared: Int64 = 4 * 1024 * 1024 * 1024      // a 4 GB "film"
        let bodyOnOffer = 32 * 1024 * 1024                // what the origin would happily write
        let server = try #require(ScriptedOriginServer { recorded in
            // Only the tail prefetch asks with a suffix range; answer that one as a Range-blind
            // origin does. Everything else keeps working so open() itself is unaffected.
            if recorded.range?.contains("bytes=-") == true {
                return .init(status: 200, declaredLength: declared, bodyBytes: bodyOnOffer)
            }
            return .init(status: 206,
                         declaredLength: Int64(1024 * 1024),
                         contentRange: "bytes 0-1048575/\(declared)",
                         bodyBytes: 1024 * 1024)
        })
        defer { server.stop() }

        let reader = AVIOReader(url: URL(string: "http://127.0.0.1:\(server.port)/big.mp4")!)
        defer { reader.markClosed(); reader.close() }
        try reader.open()

        // Give the fetch time to do the wrong thing if it is going to.
        try? await Task.sleep(nanoseconds: 500_000_000)

        #expect(server.requests.contains(where: { $0.range?.contains("bytes=-") == true }),
                "the tail prefetch never went out, so this proves nothing")
        // Some bytes may be in flight before the cancel lands; what must not happen is the body
        // being taken. Anything near bodyOnOffer means the response was accepted.
        #expect(server.bodyBytesWritten < 4 * 1024 * 1024,
                "the 200 body was being downloaded: \(server.bodyBytesWritten) bytes written")
    }

    /// A 206 that answers with some region other than the one asked for must not be installed at the
    /// requested offset. The header, not the request, says where bytes live.
    @Test("tail bytes are only accepted when Content-Range agrees with them")
    func suffixStartIsTakenFromTheHeader() throws {
        let url = URL(string: "http://example.invalid/movie.bin")!
        func response(_ contentRange: String?, length: Int) -> HTTPURLResponse {
            var headers: [String: String] = [:]
            if let contentRange { headers["Content-Range"] = contentRange }
            return HTTPURLResponse(url: url, statusCode: 206, httpVersion: "HTTP/1.1",
                                   headerFields: headers)!
        }

        #expect(AVIOReader.suffixRangeStart(response("bytes 900-999/1000", length: 100),
                                            expectedLength: 100) == 900)
        // Length disagrees with the header: a truncated or padded body, offsets unknowable.
        #expect(AVIOReader.suffixRangeStart(response("bytes 900-999/1000", length: 64),
                                            expectedLength: 64) == nil)
        #expect(AVIOReader.suffixRangeStart(response(nil, length: 100), expectedLength: 100) == nil)
        #expect(AVIOReader.suffixRangeStart(response("bytes */1000", length: 100),
                                            expectedLength: 100) == nil)
    }
}
