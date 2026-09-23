import Testing
import Foundation
@testable import AetherEngine

/// Forward-seek re-anchor lead: a seek target on a non-resident segment past the march front by
/// more than `seekReanchorLeadSegments` re-anchors the producer at seek time instead of letting
/// the fetch wait out dead-ground production (measured: a +30 s scrub held 8.2 s while the march
/// filled five segments AVPlayer never requested). Resident targets keep the cache fast path,
/// and targets inside the lead keep the march wait.
struct SeekReanchorLeadTests {

    private func segments(_ n: Int) -> [HLSVideoEngine.Segment] {
        (0..<n).map { i in
            HLSVideoEngine.Segment(startPts: Int64(i) * 4000, endPts: Int64(i + 1) * 4000,
                                   startSeconds: Double(i) * 4.0, durationSeconds: 4.0)
        }
    }

    private func makeProvider(cache: SegmentCache, initialRestartIndex: Int) -> VideoSegmentProvider {
        VideoSegmentProvider(
            cache: cache, segments: segments(200), codecsString: "hvc1", supplementalCodecs: nil,
            resolution: (3840, 2160), videoRange: .sdr, frameRate: 24.0, hdcpLevel: nil,
            sourceBitrate: 60_000_000,
            restartHandler: { _ in },
            restartActivity: { false },
            activeProducerBase: { nil },
            producerFinished: { false },
            initialRestartIndex: initialRestartIndex,
            repositionWaitSlice: 0.05,
            repositionRideCapSeconds: 5.0,
            forwardBackpressureWaitSeconds: 0.3
        )
    }

    /// Producer anchored at 40 wrote through 46 (front=46). A seek target at seg49+ is dead
    /// ground the march would spend seconds producing; re-anchor. Targets at 47/48 are inside
    /// the lead and keep the wait.
    @Test("non-resident target past front+lead needs a re-anchor; inside the lead does not")
    func leadBoundary() {
        let cache = SegmentCache(forwardWindow: 60, backwardWindow: 60)
        defer { cache.close() }
        for i in 40...46 { cache.store(index: i, data: Data(repeating: 0xA9, count: 8)) }
        let provider = makeProvider(cache: cache, initialRestartIndex: 40)

        #expect(!provider.seekTargetNeedsReanchor(47))
        #expect(!provider.seekTargetNeedsReanchor(48))
        #expect(provider.seekTargetNeedsReanchor(49))
        #expect(provider.seekTargetNeedsReanchor(60))
    }

    /// A target already produced by the march is served by the cache fast path; re-anchoring
    /// there would discard a healthy producer for nothing.
    @Test("resident target never re-anchors even past the lead")
    func residentTargetKeepsProducer() {
        let cache = SegmentCache(forwardWindow: 60, backwardWindow: 60)
        defer { cache.close() }
        for i in 40...60 { cache.store(index: i, data: Data(repeating: 0xA9, count: 8)) }
        let provider = makeProvider(cache: cache, initialRestartIndex: 40)

        #expect(!provider.seekTargetNeedsReanchor(55))
        #expect(!provider.seekTargetNeedsReanchor(60))
    }

    /// Backward and behind-front targets are handled by the resident/backward-jump paths on
    /// request; the forward lead must never claim them.
    @Test("targets at or behind the front never re-anchor")
    func backwardTargetsExcluded() {
        let cache = SegmentCache(forwardWindow: 60, backwardWindow: 60)
        defer { cache.close() }
        for i in 40...46 { cache.store(index: i, data: Data(repeating: 0xA9, count: 8)) }
        let provider = makeProvider(cache: cache, initialRestartIndex: 40)

        #expect(!provider.seekTargetNeedsReanchor(46))
        #expect(!provider.seekTargetNeedsReanchor(30))
        #expect(!provider.seekTargetNeedsReanchor(0))
    }
}
