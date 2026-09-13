import Testing
import Foundation
@testable import AetherEngine

/// Fast-stall: a starved read rebuilds its generation on a delivery floor, not a gap.
///
/// Field case: an edge that answers the range and then drips a few KB every couple of
/// seconds re-arms the delivery-gap watchdog on every drip — one such stall held a read
/// for 153 s against a 20 s threshold. The demand-side ladder judges a generation by what
/// it moved the frontier while the read was starved: below `fastStallMinDelivery` inside
/// `fastStallTimeout` (or `firstByteWitnessDelay` for a generation that never produced a
/// first byte) it is rebuilt, and every rebuild pays the unproductive budget.
@Suite("Fast-stall reconnect", .serialized)
struct FastStallReconnectTests {

    private static let totalSize: Int64 = 64 * 1024 * 1024
    private static let firstRange: Int64 = 2 * 1024 * 1024

    private final class AttemptCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var counts: [Int64: Int] = [:]
        func next(for offset: Int64) -> Int {
            lock.lock(); defer { lock.unlock() }
            let n = (counts[offset] ?? 0) + 1
            counts[offset] = n
            return n
        }
    }

    private static func read(_ reader: AVIOReader, bytes target: Int, sliceCap: Int = 256 * 1024,
                             deadline: TimeInterval = 10) -> Int {
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: sliceCap)
        defer { buf.deallocate() }
        var got = 0
        let stopAt = Date().addingTimeInterval(deadline)
        while got < target && Date() < stopAt {
            let n = reader.read(into: buf, size: Int32(min(sliceCap, target - got)))
            if n <= 0 { break }
            got += Int(n)
        }
        return got
    }

    private static func waitUntil(_ budget: TimeInterval, _ condition: () -> Bool) async throws {
        let stopAt = Date().addingTimeInterval(budget)
        while Date() < stopAt {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    /// A generation that never delivers a first byte is rebuilt at firstByteWitnessDelay
    /// (5 s at the shipped threshold), not after the connStallTimeout delivery gap.
    @Test("a silent connection is rebuilt at the witness delay, not the 20 s gap",
          .timeLimit(.minutes(2)))
    func silentConnectionRebuiltAtWitnessDelay() async throws {
        let attempts = AttemptCounter()
        let serverMaybe = ThrottledOriginServer(
            totalSize: Self.totalSize,
            respond: { _, offset, _ in
                offset == Self.firstRange && attempts.next(for: offset) == 1
                    ? .serveThenGoSilent(afterBytes: 0) : .serve206
            })
        let server = try #require(serverMaybe)
        defer { server.stop() }
        let reader = AVIOReader(url: URL(string: "http://127.0.0.1:\(server.port)/movie.bin")!,
                                boundedInitialFetch: Self.firstRange)
        defer { reader.markClosed(); reader.close() }
        try reader.open()

        // Drain the initial range so the refill request lands on the silent directive.
        try await Self.waitUntil(10) { !reader.hasLiveConnectionForTesting }
        #expect(Self.read(reader, bytes: Int(Self.firstRange)) == Int(Self.firstRange))
        try await Self.waitUntil(5) { server.requestedRanges.contains { $0.start == Self.firstRange } }

        // Witness delay 5 s + a rebuilt connection serving at loopback speed: comfortably
        // under half the delivery-gap ladder's 20 s.
        let target = 4 * 1024 * 1024
        let t0 = Date()
        let got = Self.read(reader, bytes: target, deadline: 15)
        let elapsed = Date().timeIntervalSince(t0)
        #expect(got == target, "read stopped at \(got / 1024) KB of \(target / 1024) KB")
        #expect(elapsed < 12, "silent generation took \(elapsed)s to be replaced")
        #expect(server.requestedRanges.filter { $0.start == Self.firstRange }.count >= 2,
                "the silent generation was never rebuilt: \(server.requestedRanges)")
    }

    /// The fast-stall rebuild pays the give-up budget: a mid-stream silent origin gets a
    /// bounded number of retries, then the read fails cleanly instead of looping ~1 s
    /// rebuilds forever. Shortened connStallTimeout (4 s) shrinks the witness delay to 1 s
    /// and the backoff scale keeps the ladder fast.
    @Test("a mid-stream silent origin exhausts the fast-stall budget instead of looping forever",
          .timeLimit(.minutes(2)))
    func midStreamSilentOriginGivesUp() async throws {
        AetherEngine.reconnectBackoffScaleForTesting = 0.02
        defer { AetherEngine.reconnectBackoffScaleForTesting = 1.0 }
        let serverMaybe = ThrottledOriginServer(
            totalSize: Self.totalSize,
            respond: { _, offset, _ in
                offset < Self.firstRange ? .serve206 : .serveThenGoSilent(afterBytes: 0)
            })
        let server = try #require(serverMaybe)
        defer { server.stop() }
        let reader = AVIOReader(url: URL(string: "http://127.0.0.1:\(server.port)/movie.bin")!,
                                boundedInitialFetch: Self.firstRange,
                                connStallTimeout: 4)
        defer { reader.markClosed(); reader.close() }
        try reader.open()

        let target = 4 * 1024 * 1024
        let t0 = Date()
        let got = Self.read(reader, bytes: target, deadline: 60)
        let readElapsed = Date().timeIntervalSince(t0)
        #expect(got == Int(Self.firstRange),
                "expected to stop at the served \(Self.firstRange / 1024) KB, got \(got / 1024) KB")
        #expect(readElapsed < 45, "give-up took \(readElapsed)s: the budget should bound it")

        let rebuilds = server.requestedRanges.filter { $0.start == Self.firstRange }.count
        #expect(rebuilds <= 14, "silent origin rebuilt \(rebuilds) times without a budget")
    }

    /// The drip shape a servability clock cannot catch: the connection delivers its first
    /// bytes, then a tick every 1.6 s — each tick lands exactly where the read is waiting,
    /// so "the window cannot serve" never stays true for a second. The delivery floor
    /// judges the generation anyway: ~0.9 KB/s is below 4 KB per window.
    @Test("a trickling connection is rebuilt within ~1 s despite the drips",
          .timeLimit(.minutes(2)))
    func tricklingConnectionRebuilt() async throws {
        let attempts = AttemptCounter()
        let serverMaybe = ThrottledOriginServer(
            totalSize: Self.totalSize,
            respond: { _, offset, _ in
                offset == Self.firstRange && attempts.next(for: offset) == 1
                    ? .serveThenTrickle(afterBytes: 64 * 1024, tickBytes: 1400, tickUs: 1_600_000)
                    : .serve206
            })
        let server = try #require(serverMaybe)
        defer { server.stop() }
        let reader = AVIOReader(url: URL(string: "http://127.0.0.1:\(server.port)/movie.bin")!,
                                boundedInitialFetch: Self.firstRange)
        defer { reader.markClosed(); reader.close() }
        try reader.open()

        try await Self.waitUntil(10) { !reader.hasLiveConnectionForTesting }
        #expect(Self.read(reader, bytes: Int(Self.firstRange)) == Int(Self.firstRange))
        try await Self.waitUntil(5) { server.requestedRanges.contains { $0.start == Self.firstRange } }

        let target = 4 * 1024 * 1024
        let t0 = Date()
        let got = Self.read(reader, bytes: target, deadline: 15)
        let elapsed = Date().timeIntervalSince(t0)
        #expect(got == target, "read stopped at \(got / 1024) KB of \(target / 1024) KB")
        #expect(elapsed < 8, "the drip kept the ladder re-armed for \(elapsed)s")
        // The rebuild re-requests at the frontier the trickle died on, not at the refill
        // offset — a third range request (initial, refill, rebuild) is the proof it ran.
        #expect(server.requestedRanges.count >= 3,
                "the trickling generation was never rebuilt: \(server.requestedRanges)")
    }

    /// The floor's other half: a connection delivering 16 KB/s is slow, not dead — the
    /// slowest legitimate sustained delivery (~8 KB/s audio) sits above the 4 KB floor.
    /// The read completes without the generation being rebuilt once.
    @Test("a slow-but-alive connection is never rebuilt",
          .timeLimit(.minutes(2)))
    func slowConnectionIsNotRebuilt() async throws {
        let serverMaybe = ThrottledOriginServer(
            totalSize: Self.totalSize,
            respond: { _, offset, _ in
                offset < Self.firstRange
                    ? .serve206
                    : .serveThenTrickle(afterBytes: 0, tickBytes: 16 * 1024, tickUs: 1_000_000)
            })
        let server = try #require(serverMaybe)
        defer { server.stop() }
        let reader = AVIOReader(url: URL(string: "http://127.0.0.1:\(server.port)/movie.bin")!,
                                boundedInitialFetch: Self.firstRange)
        defer { reader.markClosed(); reader.close() }
        try reader.open()

        // 48 KB at 16 KB/s ≈ 3 s of perfectly legitimate slow delivery.
        let target = 48 * 1024
        let got = Self.read(reader, bytes: target + Int(Self.firstRange), deadline: 30)
        #expect(got == target + Int(Self.firstRange),
                "slow delivery was cut at \(got / 1024) KB")
        #expect(server.requestedRanges.filter { $0.start == Self.firstRange }.count == 1,
                "a slow live generation was rebuilt: \(server.requestedRanges)")
    }
}
