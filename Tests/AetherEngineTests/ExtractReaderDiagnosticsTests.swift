// Tests/AetherEngineTests/ExtractReaderDiagnosticsTests.swift
// The still extractor's reader (`label == "extract"`) reported its fetch failures on `.verbose` —
// which `EngineLog.handler` never receives — or not at all, so a scrub that produced no still ended
// in ffmpeg's bare "Read error" with no attributable cause in the host's playback log. These tests
// pin that the host handler now sees a sanitised line for each failure shape: HTTP refusal, request
// deadline, armed read deadline mid-fetch, and an origin slot wait that timed out — and that a
// non-extract reader stays off the channel.
import XCTest
@testable import AetherEngine

/// Captures `EngineLog` lines for one test. The handler is process-global, so it is restored on
/// every path; suites run in parallel, so assertions are on presence, never on absence of lines
/// other tests may legitimately emit.
private final class ExtractLogTap: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    private let previous: ((String) -> Void)?

    init() {
        previous = EngineLog.handler
        EngineLog.handler = { [self] line in
            lock.lock()
            lines.append(line)
            lock.unlock()
        }
    }

    func restore() { EngineLog.handler = previous }

    /// Only this feature's own channel: lines other suites happen to emit concurrently can match
    /// a bare needle, but cannot carry the extract tag.
    func extractLines() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return lines.filter { $0.contains("[AVIOReader:extract]") }
    }

    func extractMatching(_ needle: String) -> [String] {
        extractLines().filter { $0.contains(needle) }
    }
}

final class ExtractReaderDiagnosticsTests: XCTestCase {

    private var tap: ExtractLogTap!

    override func setUp() {
        super.setUp()
        tap = ExtractLogTap()
    }

    override func tearDown() {
        tap.restore()
        tap = nil
        super.tearDown()
    }

    private func makeReader(port: UInt16, label: String = "extract",
                            chunkRequestTimeout: TimeInterval = 3) -> AVIOReader {
        AVIOReader(url: URL(string: "http://127.0.0.1:\(port)/movie.bin")!,
                   label: label, chunkSize: 256 * 1024, prefetchEnabled: false,
                   chunkRequestTimeout: chunkRequestTimeout, chunkMaxRetries: 1)
    }

    /// The size probe asks `bytes=0-` (open-ended: `rangeEnd == nil`); every data fetch is bounded.
    /// Refusing only the bounded form keeps the reader seekable so the refusal lands on the chunk
    /// path under test rather than rerouting open() to the streaming reader.
    private let refuseChunks: @Sendable (Int, Int64, Int64?, String, Bool)
        -> ThrottledOriginServer.Directive? = { _, _, rangeEnd, _, _ in
            rangeEnd != nil ? .status(403) : nil
        }

    func testHTTPRefusalReachesTheHostHandler() throws {
        let origin = try XCTUnwrap(ThrottledOriginServer(
            totalSize: 4 * 1024 * 1024, throttleUs: 0,
            respondEx: refuseChunks))
        defer { origin.stop() }

        let reader = makeReader(port: origin.port)
        defer { reader.markClosed(); reader.close() }
        try reader.open()

        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
        defer { buf.deallocate() }
        XCTAssertEqual(reader.read(into: buf, size: 4096), FFmpegErr.eio)

        let refusals = tap.extractMatching("HTTP 403")
        XCTAssertFalse(refusals.isEmpty, "extract reader's 403 never reached the host handler")
        XCTAssertTrue(refusals.contains { $0.contains("offset 0") && $0.contains("via=src") },
                      "refusal line must name the Range offset and URL class: \(refusals)")
        for line in tap.extractLines() {
            XCTAssertFalse(line.contains("127.0.0.1"),
                           "extract diagnostics must never carry the URL: \(line)")
        }
    }

    /// Same wire behaviour on a playback-labelled reader: the refusal stays on `.verbose`, the
    /// host-visible channel must see nothing from this feature.
    func testNonExtractReaderStaysOffTheHostChannel() throws {
        let origin = try XCTUnwrap(ThrottledOriginServer(
            totalSize: 4 * 1024 * 1024, throttleUs: 0,
            respondEx: refuseChunks))
        defer { origin.stop() }

        let reader = makeReader(port: origin.port, label: "pump")
        defer { reader.markClosed(); reader.close() }
        try reader.open()

        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
        defer { buf.deallocate() }
        XCTAssertEqual(reader.read(into: buf, size: 4096), FFmpegErr.eio)
        XCTAssertTrue(tap.extractLines().isEmpty,
                      "non-extract reader must not emit on the extract channel: \(tap.extractLines())")
    }

    /// A blackhole origin (request accepted, nothing ever written) plus the still-extraction read
    /// deadline: the open fetch dies on a request-level timeout, the armed read then dies on the
    /// read deadline — the two classes must be distinguishable on the host channel.
    ///
    /// The open fetch's timeout has two equally legitimate reporters and they race by design:
    /// `awaitSignal`'s `budget` (the "request deadline" line) and URLSession's own
    /// `timeoutInterval`, which is set to the same value and surfaces the identical verdict as
    /// `NSURLErrorDomain(-1001)`. Which one fires first is scheduling, so the assertion is on the
    /// timeout CLASS, not on which mechanism got there first.
    func testReadDeadlineAbortIsNamedSeparatelyFromRequestDeadline() throws {
        let origin = try XCTUnwrap(ThrottledOriginServer(
            totalSize: 4 * 1024 * 1024, throttleUs: 0,
            respondEx: { _, _, rangeEnd, _, _ in rangeEnd != nil ? .blackhole : nil }))
        defer { origin.stop() }

        let reader = makeReader(port: origin.port, chunkRequestTimeout: 2)
        defer { reader.markClosed(); reader.close() }
        try reader.open()   // its fetchChunk(0) rides the blackhole until a 2s timeout lands

        reader.beginReadDeadline(secondsFromNow: 0.4)
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
        defer { buf.deallocate() }
        XCTAssertLessThanOrEqual(reader.read(into: buf, size: 4096), 0)

        let lines = tap.extractLines()
        let timedOut = lines.contains {
            $0.contains("request deadline") || $0.contains("NSURLErrorDomain(-1001)")
        }
        XCTAssertTrue(timedOut,
                      "the open fetch must surface a request-level timeout (either reporter): \(lines)")
        let deadlineLines = tap.extractMatching("read deadline")
        XCTAssertFalse(deadlineLines.isEmpty,
                       "the armed read deadline must be named on the host channel: \(lines)")
        // The classes must not be conflated: no line may carry both verdicts, and the deadline
        // lines must not borrow the timeout wording.
        XCTAssertFalse(deadlineLines.contains {
            $0.contains("request deadline") || $0.contains("NSURLErrorDomain")
        }, "read-deadline lines must not be reported as request timeouts: \(deadlineLines)")
    }

    /// A slot the origin budget cannot grant inside the wait still proceeds — but for the still
    /// extractor it must say so on the host channel, so a slow scrub can be told apart into
    /// "queued behind another request" vs "the origin itself was slow".
    func testUngrantedOriginSlotIsReported() throws {
        let budget = OriginRequestBudget.shared
        let previousQuietCap = budget.quietPeriodCapForTesting
        budget.quietPeriodCapForTesting = 0   // refusal sets limit=1 without arming the pacer
        defer { budget.quietPeriodCapForTesting = previousQuietCap }

        let origin = try XCTUnwrap(ThrottledOriginServer(totalSize: 4 * 1024 * 1024, throttleUs: 0))
        defer { origin.stop() }
        let sourceURL = URL(string: "http://127.0.0.1:\(origin.port)/movie.bin")!

        // Learn a concurrency ceiling of 1 for this origin. Upstream 7.32+ runs open()'s size
        // probes with requireGranted (no slot → cancel, no "proceeding uncounted"), so the
        // un-granted log lives on the post-open extract read path (syncRequest). Open first with
        // the slot free, then hold the slot and drive a read that must log its un-granted fetch.
        budget.noteRefusal(for: sourceURL, status: 503)
        let reader = makeReader(port: origin.port)
        defer { reader.markClosed(); reader.close() }
        try reader.open()

        let holder = budget.acquire(for: sourceURL, label: "test holder", timeout: 1)
        XCTAssertEqual(holder?.granted, true, "the test could not take the origin's only slot")
        defer { budget.release(holder) }

        // The open read already buffered the first chunk; seek past it so the read actually fetches.
        _ = reader.seek(offset: 1 * 1024 * 1024, whence: SEEK_SET)
        var buf = [UInt8](repeating: 0, count: 64 * 1024)
        _ = buf.withUnsafeMutableBufferPointer { reader.read(into: $0.baseAddress!, size: Int32($0.count)) }

        XCTAssertFalse(tap.extractMatching("origin slot wait timed out").isEmpty,
                       "an extract fetch proceeding without a slot must be logged: \(tap.extractLines())")
    }

    /// `extractErrorTag` is the sanitisation boundary: a whitelisted system/module domain prints
    /// verbatim, anything else is reduced to a deterministic fingerprint — a custom domain string
    /// can itself carry sensitive text and must never reach the log.
    func testErrorTagCarriesDomainAndCodeOnly() {
        let err = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut,
                          userInfo: [NSLocalizedDescriptionKey: "https://cdn.example/seg?token=abc123"])
        XCTAssertEqual(AVIOReader.extractErrorTag(err), "NSURLErrorDomain(-1001) timeout")

        // An engine error keeps its module-qualified domain.
        let engineTag = AVIOReader.extractErrorTag(AVIOReaderError.requestTimeout)
        XCTAssertTrue(engineTag.hasPrefix("AetherEngine."), engineTag)
        XCTAssertTrue(engineTag.hasSuffix(")"), engineTag)

        // A non-whitelisted domain is fingerprinted, not printed: the raw string is what carries
        // the leak, so the tag must not contain it in any form.
        let sensitive = "cdn.example/seg?token=abc123"
        let tag = AVIOReader.extractErrorTag(NSError(domain: sensitive, code: 42))
        XCTAssertFalse(tag.contains(sensitive), tag)
        XCTAssertTrue(tag.hasPrefix("domain#"), tag)
        XCTAssertTrue(tag.hasSuffix("(42)"), tag)
        // Stable: the same domain fingerprints identically, so repeat occurrences correlate.
        let tag7 = AVIOReader.extractErrorTag(NSError(domain: sensitive, code: 7))
        XCTAssertEqual(String(tag7.dropLast(3)), String(tag.dropLast(4)))
    }
}
