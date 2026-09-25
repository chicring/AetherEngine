import Testing
import Foundation
@testable import AetherEngine

/// Weak-origin startup hypotheses, measured against the shipped reader policy.
///
/// Field evidence (2026-09-24, 23 device logs): CDN TTFB lands between 2 s and 5.3 s, while the
/// reader ends a never-delivered connection at ~5.2 s (`firstByteWitnessDelay` in both
/// `checkDeliveryGap` and the read loop's fast-stall ladder). The hypotheses under test:
///
/// - H1: an origin whose TTFB exceeds the witness delay can never start — every generation is
///   killed ~5.2 s in, before its first byte can arrive.
/// - H2: the read loop's stall branch judges on the READER-level clock
///   (`secondsSinceNetworkDelivery()`): once the reader has been silent past `connStallTimeout`
///   (20 s), each new generation is pronounced stalled at the first ~1 s poll, so a source that
///   recovers cannot deliver within the window it is given.
/// - H3: readers keep opening connections after `engine.stop()`.
///
/// These are reproduction tests, not fixes: on the current Sources the failing assertions ARE the
/// evidence. `WEAKNET` lines are printed for the harness, one per case.
@Suite("weak-origin startup reproduction", .serialized)
struct WeakOriginStartupTests {

    private static let totalSize: Int64 = 256 * 1024 * 1024
    private static let oneMB = 1024 * 1024

    /// Timestamped EngineLog capture, process-global by nature — the suite is `.serialized`, and
    /// each test filters to its own reader label / origin port before reading anything.
    private final class LogTap: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [(t: Date, line: String)] = []
        private let previous: ((String) -> Void)?

        init() {
            previous = EngineLog.handler
            EngineLog.handler = { [self] line in
                lock.lock()
                entries.append((Date(), line))
                lock.unlock()
            }
        }

        func restore() { EngineLog.handler = previous }

        func lines(containing needle: String) -> [(t: Date, line: String)] {
            lock.lock()
            defer { lock.unlock() }
            return entries.filter { $0.line.contains(needle) }
        }
    }

    /// Same shape as Issue309SilentTransportDeathTests.read: synchronous window reads with a
    /// wall-clock deadline so a dead source cannot park the test forever.
    private static func read(_ reader: AVIOReader, bytes target: Int,
                             deadline: TimeInterval = 60) -> Int {
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: 256 * 1024)
        defer { buf.deallocate() }
        var got = 0
        let stopAt = Date().addingTimeInterval(deadline)
        while got < target && Date() < stopAt {
            let n = reader.read(into: buf, size: Int32(min(256 * 1024, target - got)))
            if n <= 0 { break }
            got += Int(n)
        }
        return got
    }

    /// Per-generation wall time, measured on the log: a generation's life runs from its
    /// `conn start gen=N` line to the line that retires it (`ending it` / `ended with error`),
    /// or to the next `conn start` when no explicit end was logged.
    private static func generationLifetimes(_ lines: [(t: Date, line: String)]) -> [Double] {
        var starts: [Int: Date] = [:]
        var lifetimes: [Int: Double] = [:]
        var order: [Int] = []
        var lastStart: (gen: Int, t: Date)? = nil
        for entry in lines {
            let line = entry.line
            guard let g = genNumber(in: line) else { continue }
            if line.contains("conn start gen=") {
                if let last = lastStart, lifetimes[last.gen] == nil {
                    lifetimes[last.gen] = entry.t.timeIntervalSince(last.t)
                }
                if starts[g] == nil { order.append(g) }
                starts[g] = entry.t
                lastStart = (g, entry.t)
                continue
            }
            if (line.contains("no delivery") && line.contains("ending it"))
                || line.contains("ended with error"),
               let s = starts[g], lifetimes[g] == nil {
                lifetimes[g] = entry.t.timeIntervalSince(s)
            }
        }
        return order.map { lifetimes[$0].map { ($0 * 10).rounded() / 10 } ?? -1 }
    }

    /// First `gen=<digits>` in the line, or nil.
    private static func genNumber(in line: String) -> Int? {
        guard let r = line.range(of: "gen=") else { return nil }
        var digits = ""
        for c in line[r.upperBound...] {
            if c.isNumber { digits.append(c) } else { break }
        }
        return Int(digits)
    }

    /// Locked mutable cell for @Sendable server closures (the respond/firstByteDelay hooks run on
    /// the origin's serving threads).
    private final class Box<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var v: T
        init(_ v: T) { self.v = v }
        var value: T {
            get { lock.lock(); defer { lock.unlock() }; return v }
            set { lock.lock(); defer { lock.unlock() }; v = newValue }
        }
        /// Returns true exactly once (first call wins), for "the first non-suffix request".
        func claimOnce() -> Bool where T == Bool {
            lock.lock(); defer { lock.unlock() }
            if !v { return false }
            v = false
            return true
        }
    }

    // MARK: - T1: every request answers 7 s late, just past the 5.2 s witness delay

    /// H1. The origin is alive but slow: TTFB 7 s on every request. A healthy reader would hold
    /// each connection for its TTFB and complete in ~7–9 s; the shipped policy ends every
    /// generation at ~5.2 s, so the read can only fail or ride out the unproductive cap.
    @Test("T1 slowAlive: a 7 s TTFB origin still starts", .timeLimit(.minutes(3)))
    func slowAlive() throws {
        // Built into a local first: `#require` wraps its expression in a @Sendable closure, which
        // a server initialiser carrying non-Sendable closures cannot cross (same shape as #309).
        let tap = LogTap()
        defer { tap.restore() }
        let serverMaybe = ThrottledOriginServer(
            totalSize: Self.totalSize, throttleUs: 0,
            firstByteDelayUs: { _ in 7_000_000 })
        let server = try #require(serverMaybe)
        defer { server.stop() }
        let reader = AVIOReader(url: URL(string: "http://127.0.0.1:\(server.port)/movie.bin")!,
                                label: "weaknet")
        defer { reader.markClosed(); reader.close() }

        let t0 = Date()
        var opened = true
        do { try reader.open() } catch { opened = false }
        let got = opened ? Self.read(reader, bytes: Self.oneMB, deadline: 60) : 0
        let elapsed = Date().timeIntervalSince(t0)
        let requests = server.requestLog.count
        for entry in tap.lines(containing: "weaknet").prefix(50) {
            print("WEAKNET T1 log +\(String(format: "%.1f", entry.t.timeIntervalSince(t0)))s "
                  + entry.line)
        }
        print("WEAKNET T1 elapsed=\(String(format: "%.1f", elapsed)) requests=\(requests) "
              + "outcome=\(got >= Self.oneMB ? "ok" : "fail")")
        #expect(got == Self.oneMB, "read \(got / 1024)KB of 1MB in \(elapsed)s, \(requests) requests")
        #expect(elapsed <= 9, "the slow-alive read took \(elapsed)s")
    }

    // MARK: - T2: blackholes put the reader-level clock past connStallTimeout

    /// H2. The first 5 requests are blackholes (~5.2 s each = ~26 s of reader silence); from
    /// request 6 on the origin answers with a healthy 3 s TTFB. A per-generation clock would
    /// give each recovery attempt its full 5.2 s; the reader-level `secondsSinceNetworkDelivery()`
    /// is already past `connStallTimeout`, so the stall branch retires each new generation at the
    /// first ~1 s poll — inside its own 3 s TTFB.
    @Test("T2 staleReaderGap: recovery after a silent stretch", .timeLimit(.minutes(3)))
    func staleReaderGap() async throws {
        let tap = LogTap()
        defer { tap.restore() }
        let serverMaybe = ThrottledOriginServer(
            totalSize: Self.totalSize, throttleUs: 0,
            firstByteDelayUs: { _ in 3_000_000 },
            respond: { idx, _, _ in idx < 5 ? .blackhole : .serve206 })
        let server = try #require(serverMaybe)
        defer { server.stop() }
        let reader = AVIOReader(url: URL(string: "http://127.0.0.1:\(server.port)/movie.bin")!,
                                label: "weaknet")
        defer { reader.markClosed(); reader.close() }

        let t0 = Date()
        var opened = true
        do { try reader.open() } catch { opened = false }
        let got = opened ? Self.read(reader, bytes: Self.oneMB, deadline: 60) : 0
        let elapsed = Date().timeIntervalSince(t0)
        let requests = server.requestLog.count

        let weaknetLines = tap.lines(containing: "weaknet")
        let lifetimes = Self.generationLifetimes(weaknetLines)
        print("WEAKNET T2 genLifetimes=\(lifetimes)")
        // connStartLogGate suppresses repeated conn-start lines at the same offset, so the
        // lifetimes above can be short; the raw per-generation lines are the primary evidence.
        for entry in weaknetLines.prefix(40) {
            print("WEAKNET T2 log +\(String(format: "%.1f", entry.t.timeIntervalSince(t0)))s "
                  + entry.line)
        }
        print("WEAKNET T2 elapsed=\(String(format: "%.1f", elapsed)) requests=\(requests) "
              + "outcome=\(got >= Self.oneMB ? "ok" : "fail")")
        #expect(got == Self.oneMB, "read \(got / 1024)KB of 1MB in \(elapsed)s, \(requests) requests")
    }

    // MARK: - T3: one blackholed first request, then fast answers (regression guard)

    /// The case the never-delivered cutoff exists for: the first DATA connection hangs (the suffix
    /// tail prefetch is excluded — it races ahead and is not the request the verdict is about), the
    /// witness delay ends it, the retry answers in 0.3 s and the read completes well inside the
    /// watchdog window.
    @Test("T3 blackholeFirst: one hung data request then a healthy origin", .timeLimit(.minutes(2)))
    func blackholeFirst() throws {
        let firstDataRequest = Box(true)
        let serverMaybe = ThrottledOriginServer(
            totalSize: Self.totalSize, throttleUs: 0,
            firstByteDelayUs: { _ in 300_000 },
            respondEx: { _, _, _, _, isSuffix in
                guard !isSuffix else { return nil }
                return firstDataRequest.claimOnce() ? .blackhole : nil
            })
        let server = try #require(serverMaybe)
        defer { server.stop() }
        let reader = AVIOReader(url: URL(string: "http://127.0.0.1:\(server.port)/movie.bin")!,
                                label: "weaknet")
        defer { reader.markClosed(); reader.close() }

        let t0 = Date()
        try reader.open()
        let got = Self.read(reader, bytes: Self.oneMB, deadline: 60)
        let elapsed = Date().timeIntervalSince(t0)
        let requests = server.requestLog.count
        print("WEAKNET T3 elapsed=\(String(format: "%.1f", elapsed)) requests=\(requests) "
              + "outcome=\(got >= Self.oneMB ? "ok" : "fail")")
        #expect(got == Self.oneMB, "read \(got / 1024)KB of 1MB in \(elapsed)s, \(requests) requests")
        #expect(elapsed <= 7, "the blackhole-then-healthy read took \(elapsed)s")
    }

    // MARK: - T2b: mid-stream silence ages the reader clock past connStallTimeout

    /// H2, in its field shape: the reader has delivered (so `read()` is parked inside
    /// readPersistent's forward wait), then the connection goes silent for longer than
    /// `connStallTimeout` (20 s). Every recovery connection after that is judged on the
    /// READER-level `secondsSinceNetworkDelivery()` — already past the timeout — so the stall
    /// branch retires each new generation at the first ~1 s poll, inside its own 3 s TTFB.
    /// A per-generation clock gives the recovery attempt its full window.
    ///
    /// Shape: the first data connection delivers 2 MB then closes (serveThenDrop), so the next
    /// read needs a refill. Every refill request is blackholed for ~22 s — past the reader-level
    /// `connStallTimeout` — then the origin recovers with a healthy 3 s TTFB. The read stays
    /// parked in readPersistent's forward wait across the recovery.
    @Test("T2b staleGapMidStream: recovery after a mid-stream silent stretch", .timeLimit(.minutes(3)))
    func staleGapMidStream() async throws {
        let tap = LogTap()
        defer { tap.restore() }
        let firstDataRequest = Box(true)
        let blackhole = Box(false)
        let recoveryDelayUs = Box<useconds_t>(0)
        let serverMaybe = ThrottledOriginServer(
            totalSize: Self.totalSize, throttleUs: 0,
            firstByteDelayUs: { isSuffix in isSuffix ? 0 : recoveryDelayUs.value },
            respondEx: { _, _, _, _, isSuffix in
                guard !isSuffix else { return nil }
                if blackhole.value { return .blackhole }
                // First data connection: 2 MB then a close, so the next read needs a refill.
                return firstDataRequest.claimOnce() ? .serveThenDrop(afterBytes: 2_000_000) : nil
            })
        let server = try #require(serverMaybe)
        defer { server.stop() }
        let reader = AVIOReader(url: URL(string: "http://127.0.0.1:\(server.port)/movie.bin")!,
                                label: "weaknet")
        defer { reader.markClosed(); reader.close() }

        let t0 = Date()
        try reader.open()
        // Recovery connections answer 3 s late; the blackout starts now — every refill until the
        // gate opens is a blackhole. 25 s carries the reader-level delivery clock past
        // connStallTimeout (20 s) before the first recovery attempt is judged.
        recoveryDelayUs.value = 3_000_000
        blackhole.value = true
        let readTask = Task.detached {
            Self.read(reader, bytes: 3 * 1024 * 1024, deadline: 60)
        }
        try await Task.sleep(for: .seconds(25))
        blackhole.value = false
        let got = await readTask.value
        let elapsed = Date().timeIntervalSince(t0)
        let requests = server.requestLog.count

        let weaknetLines = tap.lines(containing: "weaknet")
        let lifetimes = Self.generationLifetimes(weaknetLines)
        print("WEAKNET T2b genLifetimes=\(lifetimes)")
        for entry in weaknetLines.prefix(60) {
            print("WEAKNET T2b log +\(String(format: "%.1f", entry.t.timeIntervalSince(t0)))s "
                  + entry.line)
        }
        print("WEAKNET T2b elapsed=\(String(format: "%.1f", elapsed)) requests=\(requests) "
              + "outcome=\(got >= 3 * 1024 * 1024 ? "ok" : "fail")")
        #expect(got == 3 * 1024 * 1024,
                "read \(got / 1024)KB of 3MB in \(elapsed)s, \(requests) requests")
    }

    // MARK: - T5: standby hedging on a single-connection origin

    /// A connection-capped origin (509 over 1 in flight) whose first data connection answers 7 s
    /// late. The standby design holds the parked connection AND its replacement on the link, so
    /// the replacement is refused — the read must still come home (standby promotion or a retry
    /// once the cap frees), without the 509s running the rate-limit ladder to give-up.
    ///
    /// The suffix prefetch is armed off beforehand so the parked connection and its hedge are the
    /// ONLY two requests racing for the single slot — the shape under test.
    @Test("T5 standbyCapped: slow first byte on a one-connection origin", .timeLimit(.minutes(2)))
    func standbyCapped() throws {
        let tap = LogTap()
        defer { tap.restore() }
        let firstDataRequest = Box(true)
        let delayUs = Box<useconds_t>(0)
        let serverMaybe = ThrottledOriginServer(
            totalSize: Self.totalSize, throttleUs: 0,
            refuseAboveConcurrency: 1,
            // respondEx runs before the delay sleep for each request, so arming/clearing delayUs
            // there lands on the right request: 7 s on the first served data connection (the
            // large-range data GET, not the byte-0 size probe), then fast.
            firstByteDelayUs: { isSuffix in isSuffix ? 0 : delayUs.value },
            respondEx: { _, _, end, _, isSuffix in
                guard !isSuffix else { return nil }
                let isDataConn = (end ?? 0) > 1_000_000
                delayUs.value = (isDataConn && firstDataRequest.claimOnce()) ? 7_000_000 : 0
                return nil
            })
        let server = try #require(serverMaybe)
        defer { server.stop() }
        let url = URL(string: "http://127.0.0.1:\(server.port)/movie.bin")!
        SuffixRangeSupport.shared.denyForTesting(url)
        OriginRequestBudget.shared.resetForTesting()
        defer { SuffixRangeSupport.shared.resetForTesting() }

        let reader = AVIOReader(url: url, label: "weaknet")
        defer { reader.markClosed(); reader.close() }

        let t0 = Date()
        try reader.open()
        let got = Self.read(reader, bytes: Self.oneMB, deadline: 60)
        let elapsed = Date().timeIntervalSince(t0)
        let requests = server.requestLog.count
        for entry in tap.lines(containing: "weaknet").prefix(50) {
            print("WEAKNET T5 log +\(String(format: "%.1f", entry.t.timeIntervalSince(t0)))s "
                  + entry.line)
        }
        print("WEAKNET T5 elapsed=\(String(format: "%.1f", elapsed)) requests=\(requests) "
              + "refused=\(server.refusedForConcurrency) "
              + "outcome=\(got >= Self.oneMB ? "ok" : "fail")")
        #expect(got == Self.oneMB, "read \(got / 1024)KB of 1MB in \(elapsed)s, \(requests) requests")
        #expect(elapsed <= 9, "the capped-origin slow-start took \(elapsed)s")
    }

    // MARK: - T6: mixed TTFB

    /// Per-request TTFB cycling [1,7,2,9,3,6,1,8] s: every other connection crosses the witness
    /// delay. Standby hedging must keep the read under 12 s for 1 MB.
    @Test("T6 mixed: alternating fast and slow TTFB", .timeLimit(.minutes(2)))
    func mixedTTFB() throws {
        let pattern: [useconds_t] = [1, 7, 2, 9, 3, 6, 1, 8].map { $0 * 1_000_000 }
        let dataIndex = Box(0)
        let serverMaybe = ThrottledOriginServer(
            totalSize: Self.totalSize, throttleUs: 0,
            // firstByteDelayUs is consulted exactly once per request inside the handler, so the
            // data-connection ordinal increments here: pattern[i % 8] for data request i.
            firstByteDelayUs: { isSuffix in
                if isSuffix { return 0 }
                let i = dataIndex.value
                dataIndex.value = i + 1
                return pattern[i % pattern.count]
            })
        let server = try #require(serverMaybe)
        defer { server.stop() }
        let reader = AVIOReader(url: URL(string: "http://127.0.0.1:\(server.port)/movie.bin")!,
                                label: "weaknet")
        defer { reader.markClosed(); reader.close() }

        let t0 = Date()
        try reader.open()
        let got = Self.read(reader, bytes: Self.oneMB, deadline: 60)
        let elapsed = Date().timeIntervalSince(t0)
        let requests = server.requestLog.count
        print("WEAKNET T6 elapsed=\(String(format: "%.1f", elapsed)) requests=\(requests) "
              + "outcome=\(got >= Self.oneMB ? "ok" : "fail")")
        #expect(got == Self.oneMB, "read \(got / 1024)KB of 1MB in \(elapsed)s, \(requests) requests")
        #expect(elapsed <= 12, "the mixed-TTFB read took \(elapsed)s")
    }

    // MARK: - F4: a tail-prefetch timeout must not latch the origin off suffix ranges

    /// A blackholed suffix request ends in URLError.timedOut (~4 s, the request's own timeout):
    /// a transport event, not the origin answering the range form. Two such timeouts must NOT
    /// teach `SuffixRangeSupport` to skip the prefetch for the rest of the session — and a real
    /// non-206 answer must still latch after one occurrence.
    @Test("F4: suffix-range support survives timeouts, still latches on refusal", .timeLimit(.minutes(2)))
    func tailPrefetchTimeoutDoesNotLatch() throws {
        SuffixRangeSupport.shared.resetForTesting()
        defer { SuffixRangeSupport.shared.resetForTesting() }

        let serverMaybe = ThrottledOriginServer(
            totalSize: Self.totalSize, throttleUs: 0,
            respondEx: { _, _, _, _, isSuffix in isSuffix ? .blackhole : nil })
        let server = try #require(serverMaybe)
        defer { server.stop() }
        let url = URL(string: "http://127.0.0.1:\(server.port)/movie.bin")!

        func suffixRequestCount() -> Int {
            server.requestHeaders.filter { headers in
                headers["range"]?.hasPrefix("bytes=-") == true
            }.count
        }

        // Two opens on the same origin, each blackholing its suffix prefetch → two timeouts.
        for _ in 0..<2 {
            let reader = AVIOReader(url: url, label: "weaknet")
            try reader.open()
            reader.markClosed()
            reader.close()
        }
        // Wait for both prefetch requests to be logged, then past the prefetch timeout so both
        // URLError.timedOut outcomes have landed (2 transport strikes would latch on the unfixed
        // behaviour).
        let deadline = Date().addingTimeInterval(30)
        while suffixRequestCount() < 2 && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.2)
        }
        Thread.sleep(forTimeInterval: 8)
        print("WEAKNET F4 suffixRequests=\(suffixRequestCount()) "
              + "denied=\(SuffixRangeSupport.shared.denialReason(for: url) ?? "nil")")
        #expect(SuffixRangeSupport.shared.denialReason(for: url) == nil,
                "timeouts latched the origin off suffix ranges")

        // A real refusal (200 to a suffix range — the origin served the whole file instead)
        // must still latch immediately.
        let server2Maybe = ThrottledOriginServer(
            totalSize: Self.totalSize, throttleUs: 0,
            respondEx: { _, _, _, _, isSuffix in isSuffix ? .status(200) : nil })
        let server2 = try #require(server2Maybe)
        defer { server2.stop() }
        let url2 = URL(string: "http://127.0.0.1:\(server2.port)/movie.bin")!
        let reader2 = AVIOReader(url: url2, label: "weaknet")
        try reader2.open()
        let refusalDeadline = Date().addingTimeInterval(10)
        while SuffixRangeSupport.shared.denialReason(for: url2) == nil && Date() < refusalDeadline {
            Thread.sleep(forTimeInterval: 0.1)
        }
        reader2.markClosed()
        reader2.close()
        #expect(SuffixRangeSupport.shared.denialReason(for: url2) != nil,
                "a genuine suffix-range refusal did not latch")
    }

    // MARK: - T7: a promoted standby is not re-killed by a stale verdict

    /// The fixed-slow7 field defect: a parked generation answers and is promoted while the read
    /// loop's fast-stall verdict (armed before the promotion) is still standing — the backoff ends
    /// and `timedReconnect` cancels the connection that just started delivering. With the
    /// generation/epoch guard the reconnect is skipped and the 7 s TTFB is paid exactly once.
    @Test("T7 promotedNotKilled: a promotion during backoff survives the stale verdict", .timeLimit(.minutes(2)))
    func promotedNotKilled() throws {
        let tap = LogTap()
        defer { tap.restore() }
        let serverMaybe = ThrottledOriginServer(
            totalSize: Self.totalSize, throttleUs: 0,
            firstByteDelayUs: { _ in 7_000_000 })
        let server = try #require(serverMaybe)
        defer { server.stop() }
        let reader = AVIOReader(url: URL(string: "http://127.0.0.1:\(server.port)/movie.bin")!,
                                label: "weaknet")
        defer { reader.markClosed(); reader.close() }

        let t0 = Date()
        try reader.open()
        let got = Self.read(reader, bytes: 8 * 1024 * 1024, deadline: 60)
        let elapsed = Date().timeIntervalSince(t0)

        let weaknetLines = tap.lines(containing: "weaknet")
        var promotedGens: [Int] = []
        var promotedKilled: [String] = []
        var promotionSeen = false
        for entry in weaknetLines {
            if entry.line.contains("promoted"),
               let g = Self.genNumber(in: entry.line) {
                promotedGens.append(g)
                promotionSeen = true
                continue
            }
            if promotionSeen, entry.line.contains("ended with error: cancelled"),
               let g = Self.genNumber(in: entry.line), promotedGens.contains(g) {
                promotedKilled.append(entry.line)
            }
        }
        print("WEAKNET T7 elapsed=\(String(format: "%.1f", elapsed)) "
              + "requests=\(server.requestLog.count) promoted=\(promotedGens) "
              + "promotedKilled=\(promotedKilled.count) "
              + "outcome=\(got >= 8 * 1024 * 1024 ? "ok" : "fail")")
        for entry in weaknetLines.prefix(50) {
            print("WEAKNET T7 log +\(String(format: "%.1f", entry.t.timeIntervalSince(t0)))s "
                  + entry.line)
        }
        #expect(got == 8 * 1024 * 1024,
                "read \(got / 1024)KB of 8MB in \(elapsed)s")
        #expect(promotedKilled.isEmpty,
                "a promoted generation was cancelled afterwards: \(promotedKilled)")
        #expect(elapsed <= 10, "the promoted-standby read took \(elapsed)s")
    }

    // MARK: - T8: the speculative tail prefetch waits out a slow TTFB

    /// The tail prefetch raced the data connection's TTFB on a 7 s origin and was abandoned at
    /// its ~5.5 s detour budget, so the cues fetch fell to a serial detour round trip. The
    /// prefetch is parallel and slot-gated, so it can afford the longer patience.
    @Test("T8 tailPrefetchPatient: the suffix prefetch survives a 7 s TTFB", .timeLimit(.minutes(2)))
    func tailPrefetchPatient() throws {
        let tap = LogTap()
        defer { tap.restore() }
        let serverMaybe = ThrottledOriginServer(
            totalSize: Self.totalSize, throttleUs: 0,
            firstByteDelayUs: { _ in 7_000_000 })
        let server = try #require(serverMaybe)
        defer { server.stop() }
        let url = URL(string: "http://127.0.0.1:\(server.port)/movie.bin")!
        SuffixRangeSupport.shared.resetForTesting()
        defer { SuffixRangeSupport.shared.resetForTesting() }

        let reader = AVIOReader(url: url, label: "weaknet")
        defer { reader.markClosed(); reader.close() }

        let t0 = Date()
        try reader.open()
        // The prefetch lands at ~TTFB; give it the stall-timeout window to report.
        let deadline = Date().addingTimeInterval(20)
        var installed = false
        while Date() < deadline {
            if !tap.lines(containing: "weaknet tail prefetch installed").isEmpty {
                installed = true
                break
            }
            if !tap.lines(containing: "weaknet tail prefetch rejected").isEmpty { break }
            Thread.sleep(forTimeInterval: 0.2)
        }
        let rejected = tap.lines(containing: "weaknet tail prefetch rejected")
        print("WEAKNET T8 installed=\(installed) rejected=\(rejected.count) "
              + "elapsed=\(String(format: "%.1f", Date().timeIntervalSince(t0)))")
        #expect(installed, "the tail prefetch did not install its span on a 7 s origin")
        #expect(rejected.isEmpty, "the tail prefetch was rejected: \(rejected.map(\.line))")
    }
}

/// T4 lives on the engine, which is @MainActor; the reader-level cases above stay off it so a
/// blocking read never sits on the main actor.
@Suite("weak-origin startup reproduction: engine stop (#H3)", .serialized)
@MainActor
struct WeakOriginEngineStopTests {

    /// H3. Every request blackholes, so the load is parked inside its probe/open when `stop()`
    /// runs. What matters is what the origin sees afterwards: a stopped session must not keep
    /// opening connections. The reader's post-stop log lines are captured verbatim for the report.
    @Test("T4 stopDuringOpen: no origin traffic after stop()", .timeLimit(.minutes(2)))
    func stopDuringOpen() async throws {
        final class Tap: @unchecked Sendable {
            private let lock = NSLock()
            private var entries: [(t: Date, line: String)] = []
            private let previous: ((String) -> Void)?
            init() {
                previous = EngineLog.handler
                EngineLog.handler = { [self] line in
                    lock.lock()
                    entries.append((Date(), line))
                    lock.unlock()
                }
            }
            func restore() { EngineLog.handler = previous }
            func avioLines(after t: Date) -> [String] {
                lock.lock()
                defer { lock.unlock() }
                return entries.filter { $0.t >= t && $0.line.contains("[AVIOReader]") }.map(\.line)
            }
            func preStopReaderLines(before t: Date) -> [String] {
                lock.lock()
                defer { lock.unlock() }
                return entries.filter {
                    $0.t < t && ($0.line.contains("[AVIOReader]") || $0.line.contains("[AetherEngine]")
                                 || $0.line.contains("[HLSVideoEngine]") || $0.line.contains("subtitle"))
                }.map(\.line)
            }
        }

        let serverMaybe = ThrottledOriginServer(
            totalSize: 256 * 1024 * 1024, throttleUs: 0,
            respond: { _, _, _ in .blackhole })
        let server = try #require(serverMaybe)
        defer { server.stop() }
        let tap = Tap()
        defer { tap.restore() }

        let engine = try AetherEngine()
        let url = URL(string: "http://127.0.0.1:\(server.port)/movie.mkv")!
        let t0 = Date()
        let loadTask = Task { [engine] in
            try? await engine.load(url: url,
                                   options: LoadOptions(probesize: 5_000_000,
                                                        maxAnalyzeDuration: 3_000_000))
        }
        try await Task.sleep(for: .seconds(3))
        let requestsAtStop = server.requestLog.count
        let stopStart = Date()
        engine.stop()
        let stopElapsed = Date().timeIntervalSince(stopStart)

        // A request already on the wire when stop() runs can still land inside the first second;
        // the verdict is what arrives once the stop has taken effect.
        try await Task.sleep(for: .seconds(1))
        let afterGrace = server.requestLog.count
        try await Task.sleep(for: .seconds(14))
        let requestsAfter = server.requestLog.count - afterGrace
        let postStopLines = tap.avioLines(after: stopStart)
        loadTask.cancel()

        print("WEAKNET T4 elapsed=\(String(format: "%.1f", Date().timeIntervalSince(t0))) "
              + "requests=\(server.requestLog.count) outcome=\(requestsAfter == 0 ? "ok" : "fail")")
        print("WEAKNET T4 requestsAtStop=\(requestsAtStop) "
              + "newAfterStop=\(server.requestLog.count - requestsAtStop) "
              + "newAfterStopPlus1s=\(requestsAfter) "
              + "stopReturnedIn=\(String(format: "%.2f", stopElapsed))s")
        for line in postStopLines.prefix(20) {
            print("WEAKNET T4 post-stop log: \(line)")
        }
        for line in tap.preStopReaderLines(before: stopStart).prefix(30) {
            print("WEAKNET T4 pre-stop log: \(line)")
        }
        #expect(requestsAfter == 0,
                "\(requestsAfter) new origin request(s) arrived more than 1 s after stop()")
    }
}
