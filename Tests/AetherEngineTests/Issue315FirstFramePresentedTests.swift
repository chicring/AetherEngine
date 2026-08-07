import Testing
import Combine
@testable import AetherEngine

/// #315: `hasFirstFrameReadyForDisplay`, the load-scoped statement that the running path has a
/// picture. The layer property it folds needs a real AVPlayer / AVSampleBufferDisplayLayer, so the
/// end-to-end edge is measured with `aetherctl play` (native: layer ready t+0.05 s, published
/// t+0.16 s; software: ready after 6 enqueued frames) rather than here. What is testable here is
/// the fold, and the fold is where the two ways to get this wrong live: inheriting the previous
/// item's picture, and re-lowering the flag on a seam.
@Suite("First-frame-ready latch (#315)")
struct Issue315FirstFramePresentedTests {

    /// Stands in for a playback host's `@Published private(set) var isVideoReadyForDisplay`.
    @MainActor
    final class HostDouble {
        @Published var isVideoReadyForDisplay: Bool
        init(_ initial: Bool) { isVideoReadyForDisplay = initial }
    }

    @MainActor
    @Test("A reused host's carried-in picture does not latch this load")
    func carriedInValueIsNotThisLoadsFrame() async throws {
        let engine = try AetherEngine()
        var cancellables = Set<AnyCancellable>()
        // A native host kept across a reload still reports the OUTGOING item as ready at the moment
        // the engine wires its sinks: host.load() (and its unloadCurrentItem) runs after the wiring.
        let host = HostDouble(true)
        engine.latchFirstFrameReadyForDisplay(from: host.$isVideoReadyForDisplay, storeIn: &cancellables)

        #expect(engine.hasFirstFrameReadyForDisplay == false)

        // AVFoundation clears the layer once the swap goes through, then raises it for the new item.
        host.isVideoReadyForDisplay = false
        #expect(engine.hasFirstFrameReadyForDisplay == false)
        host.isVideoReadyForDisplay = true
        #expect(engine.hasFirstFrameReadyForDisplay == true)
    }

    @MainActor
    @Test("A fresh host's first frame latches it")
    func freshHostLatchesOnFirstRise() async throws {
        let engine = try AetherEngine()
        var cancellables = Set<AnyCancellable>()
        let host = HostDouble(false)
        engine.latchFirstFrameReadyForDisplay(from: host.$isVideoReadyForDisplay, storeIn: &cancellables)

        #expect(engine.hasFirstFrameReadyForDisplay == false)
        host.isVideoReadyForDisplay = true
        #expect(engine.hasFirstFrameReadyForDisplay == true)
    }

    @MainActor
    @Test("A seam that drops the layer's picture does not lower it")
    func latchHoldsThroughAPictureLessSeam() async throws {
        let engine = try AetherEngine()
        var cancellables = Set<AnyCancellable>()
        let host = HostDouble(false)
        engine.latchFirstFrameReadyForDisplay(from: host.$isVideoReadyForDisplay, storeIn: &cancellables)
        host.isVideoReadyForDisplay = true

        // The measured shape of an item swap on a reused host: ~40 ms of false, then true again.
        // Media fallback, the AirPlay master swap, the #93 recovery and the AE#158 in-place handover
        // all take it, and a host must not re-cover a picture for any of them.
        host.isVideoReadyForDisplay = false
        #expect(engine.hasFirstFrameReadyForDisplay == true)
        host.isVideoReadyForDisplay = true
        #expect(engine.hasFirstFrameReadyForDisplay == true)
    }

    @MainActor
    @Test("stop() un-latches it")
    func stopClearsTheLatch() async throws {
        let engine = try AetherEngine()
        var cancellables = Set<AnyCancellable>()
        let host = HostDouble(false)
        engine.latchFirstFrameReadyForDisplay(from: host.$isVideoReadyForDisplay, storeIn: &cancellables)
        host.isVideoReadyForDisplay = true
        #expect(engine.hasFirstFrameReadyForDisplay == true)

        engine.stop()
        // The session is gone, so no statement about a picture survives it. load() reaches the same
        // reset through the stopInternal() in its prologue.
        #expect(engine.hasFirstFrameReadyForDisplay == false)
    }
}
