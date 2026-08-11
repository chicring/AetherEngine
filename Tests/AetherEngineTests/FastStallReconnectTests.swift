import Testing
import Foundation
@testable import AetherEngine

/// Fast-stall 1s 检测 + give-up 预算保护。
///
/// Field 背景: 完全静默的连接（建连成功但零字节）曾被 `winCond.wait(until: connStallTimeout)`
/// 一次阻塞 20s 架空——fastStallTimeout=1s 的检查要等 wait 返回后才评估, 所以静默 1s 检测
/// 实际退化成 20s（日志: "no servable data for 20.0s ... (fast-stall)"）。且 fast-stall 分支
/// 直接 `continue`, 绕过 give-up 预算, 静默源只能靠与 #309 watchdog 竞争才有预算兜底。
///
/// 修复: wait 按 min(fastStallTimeout, connStallTimeout) 轮询, fast-stall 重建挂上
/// recordReconnectAndShouldGiveUp（失败上限 + 512KB 进展清零）。
@Suite("Fast-stall 1s reconnect", .serialized)
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

    /// 完全静默（headers 无 body）的连接在 ~1s 内被 fast-stall 重建并继续,
    /// 而不是等 connStallTimeout=20s 的 wait 返回。6s 读预算足以区分两条路径。
    @Test("a silent connection is rebuilt within ~1s, not after the 20s conn-stall wait",
          .timeLimit(.minutes(2)))
    func silentConnectionRebuiltWithinOneSecond() async throws {
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

        // 等初始 range 落地, 消费到 frontier, 让会被静默的 refill 请求发出。
        try await Self.waitUntil(10) { !reader.hasLiveConnectionForTesting }
        #expect(Self.read(reader, bytes: Int(Self.firstRange)) == Int(Self.firstRange))
        try await Self.waitUntil(5) { server.requestedRanges.contains { $0.start == Self.firstRange } }

        // 跨过静默段: 旧实现要 20s 才重建（read 超时只拿到 2MB）,
        // 新实现 ~1s 重建、后续正常 serve, 6s 内读满 4MB。
        let target = 4 * 1024 * 1024
        let got = Self.read(reader, bytes: target, deadline: 6)
        #expect(got == target, "read stopped at \(got / 1024) KB of \(target / 1024) KB")
    }

    /// 对「读取中途变静默」的源, fast-stall 重建必须受 give-up 预算约束:
    /// 有限次后放弃, 而不是每秒一次无限重建。open 阶段正常（首个 range 有数据），
    /// 静默发生在后续 refill——即线上「播放中连接静默」的形态。
    @Test("a mid-stream silent origin exhausts the fast-stall budget instead of looping forever",
          .timeLimit(.minutes(2)))
    func midStreamSilentOriginGivesUp() async throws {
        let serverMaybe = ThrottledOriginServer(
            totalSize: Self.totalSize,
            respond: { _, offset, _ in
                offset < Self.firstRange ? .serve206 : .serveThenGoSilent(afterBytes: 0)
            })
        let server = try #require(serverMaybe)
        defer { server.stop() }
        let reader = AVIOReader(url: URL(string: "http://127.0.0.1:\(server.port)/movie.bin")!,
                                boundedInitialFetch: Self.firstRange)
        defer { reader.markClosed(); reader.close() }
        try reader.open()

        // 目标超过首个 range: 前 2MB 从窗口读走, 之后的 refill 全部静默。
        let target = 4 * 1024 * 1024
        let t0 = Date()
        let got = Self.read(reader, bytes: target, deadline: 25)
        let readElapsed = Date().timeIntervalSince(t0)
        // 只能拿到静默前的 2MB, 且必须干净失败（不是无限转圈）。
        #expect(got == Int(Self.firstRange),
                "expected to stop at the served \(Self.firstRange / 1024) KB, got \(got / 1024) KB")
        #expect(readElapsed < 20, "give-up took \(readElapsed)s: fast-stall budget should bound it")

        // 重建有界: 已产出源预算(12) + 初始/探测余量。无限循环会远超此值。
        let rebuilds = server.requestedRanges.filter { $0.end == 32 * 1024 * 1024 - 1 }.count
        #expect(rebuilds <= 14, "silent origin rebuilt \(rebuilds) times without budget")
    }
}
