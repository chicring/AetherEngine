import Testing
import Foundation
import AVFoundation
@testable import AetherEngine

@Suite("AE#711 follow-up: the native picture held across an in-place item swap", .serialized,
       .timeLimit(.minutes(1)))
@MainActor
struct ItemSwapStillTests {

    /// Four seconds of H.264 plus silent AAC, long enough to still be playing when the capture runs
    /// and with an audio stream for the audio-switch rebuild to name. The shared fixtures end after
    /// 0.2 s, before an output attached to them sees a frame. Each track feeds itself through
    /// `requestMediaDataWhenReady`: an interleaving writer fed from one loop waits on whichever
    /// track the loop is not on.
    private static func fixtureURL() async throws -> URL {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("ae711-still-\(UUID().uuidString).mp4")
        let writer = try AVAssetWriter(outputURL: file, fileType: .mp4)
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 128, AVVideoHeightKey: 72,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 128, kCVPixelBufferHeightKey as String: 72,
        ])
        let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1,
        ])
        writer.add(video)
        writer.add(audio)
        #expect(writer.startWriting())
        writer.startSession(atSourceTime: .zero)

        var asbd = AudioStreamBasicDescription(
            mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
            mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2, mChannelsPerFrame: 1,
            mBitsPerChannel: 16, mReserved: 0)
        var formatOut: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil,
                                       magicCookieSize: 0, magicCookie: nil, extensions: nil,
                                       formatDescriptionOut: &formatOut)
        let audioFormat = try #require(formatOut)

        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            let group = DispatchGroup()
            group.enter()
            let frame = FixtureCounter()
            video.requestMediaDataWhenReady(on: DispatchQueue(label: "ae711.fixture.video")) {
                while video.isReadyForMoreMediaData && frame.value < 120 {
                    var buffer: CVPixelBuffer?
                    if let pool = adaptor.pixelBufferPool {
                        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
                    }
                    guard let pixels = buffer else { break }
                    CVPixelBufferLockBaseAddress(pixels, [])
                    memset(CVPixelBufferGetBaseAddress(pixels), Int32(frame.value * 2 % 256),
                           CVPixelBufferGetDataSize(pixels))
                    CVPixelBufferUnlockBaseAddress(pixels, [])
                    adaptor.append(pixels, withPresentationTime: CMTime(value: CMTimeValue(frame.value), timescale: 30))
                    frame.value += 1
                }
                if frame.value >= 120 { video.markAsFinished(); group.leave() }
            }
            group.enter()
            let chunk = 4800
            let chunks = FixtureCounter()
            audio.requestMediaDataWhenReady(on: DispatchQueue(label: "ae711.fixture.audio")) {
                while audio.isReadyForMoreMediaData && chunks.value < 40 {
                    var block: CMBlockBuffer?
                    CMBlockBufferCreateWithMemoryBlock(
                        allocator: nil, memoryBlock: nil, blockLength: chunk * 2, blockAllocator: nil,
                        customBlockSource: nil, offsetToData: 0, dataLength: chunk * 2,
                        flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block)
                    guard let data = block else { break }
                    CMBlockBufferFillDataBytes(with: 0, blockBuffer: data, offsetIntoDestination: 0,
                                               dataLength: chunk * 2)
                    var sample: CMSampleBuffer?
                    CMAudioSampleBufferCreateReadyWithPacketDescriptions(
                        allocator: nil, dataBuffer: data, formatDescription: audioFormat,
                        sampleCount: chunk,
                        presentationTimeStamp: CMTime(value: CMTimeValue(chunks.value * chunk), timescale: 48_000),
                        packetDescriptions: nil, sampleBufferOut: &sample)
                    guard let sample else { break }
                    audio.append(sample)
                    chunks.value += 1
                }
                if chunks.value >= 40 { audio.markAsFinished(); group.leave() }
            }
            group.notify(queue: .main) { done.resume() }
        }
        await writer.finishWriting()
        #expect(writer.status == .completed)
        return file
    }

    @Test("a playing native item hands over the frame on screen")
    func playingCapture() async throws {
        let file = try await Self.fixtureURL()
        defer { try? FileManager.default.removeItem(at: file) }
        let engine = try AetherEngine()
        defer { engine.stop() }
        _ = try await engine.load(url: file)
        let host = try #require(engine.nativeHost)
        try await waitFor { host.isVideoReadyForDisplay }
        #expect(engine.state == .playing)
        // A playing item needs ~300 ms before a fresh output sees a frame (measured here); the
        // rebuild pauses first for that reason, but the playing read still has to work.
        let frame = await host.captureDisplayedFrame(timeout: .seconds(2))
        #expect(frame != nil)
        #expect(engine.state == .playing)
    }

    @Test("a paused native item still hands over the frame on screen")
    func pausedCapture() async throws {
        let file = try await Self.fixtureURL()
        defer { try? FileManager.default.removeItem(at: file) }
        let engine = try AetherEngine()
        defer { engine.stop() }
        _ = try await engine.load(url: file)
        let host = try #require(engine.nativeHost)
        try await waitFor { host.isVideoReadyForDisplay }
        engine.pause()
        let started = ContinuousClock.now
        let frame = await host.captureDisplayedFrame()
        #expect(ContinuousClock.now - started < .milliseconds(250))
        #expect(frame != nil)
    }

    @Test("an audio-switch rebuild holds the picture over the swap and drops it at the next first frame")
    func rebuildHoldsThePicture() async throws {
        let file = try await Self.fixtureURL()
        defer { try? FileManager.default.removeItem(at: file) }
        let engine = try AetherEngine()
        defer { engine.stop() }
        let view = AetherPlayerView(frame: CGRect(x: 0, y: 0, width: 320, height: 180))
        engine.bind(view: view)
        _ = try await engine.load(url: file)
        let host = try #require(engine.nativeHost)
        try await waitFor { host.isVideoReadyForDisplay }
        let audioIndex = try #require(engine.activeAudioTrackIndex)

        var held = false
        let watcher = Task { @MainActor in
            while !Task.isCancelled {
                if view.isHoldingStill { held = true }
                try? await Task.sleep(for: .milliseconds(2))
            }
        }
        let failure = await engine.reloadWithAudioOverride(
            url: file, audioStreamIndex: Int32(audioIndex), expectedGeneration: engine.loadGeneration)
        #expect(failure == nil)
        try await waitFor { !view.isHoldingStill }
        watcher.cancel()

        #expect(held)
        #expect(engine.heldPictureLastRelease == "first frame of the next item")
        #expect(engine.nativeHost === host)
        #expect(engine.heldPictureView == nil)
    }

    @Test("stop takes a held picture down")
    func stopReleasesTheHold() async throws {
        let file = try await Self.fixtureURL()
        defer { try? FileManager.default.removeItem(at: file) }
        let engine = try AetherEngine()
        let view = AetherPlayerView(frame: CGRect(x: 0, y: 0, width: 320, height: 180))
        engine.bind(view: view)
        _ = try await engine.load(url: file)
        let host = try #require(engine.nativeHost)
        try await waitFor { host.isVideoReadyForDisplay }
        engine.pause()
        await engine.holdPictureAcrossItemSwap()
        #expect(view.isHoldingStill)
        engine.stop()
        #expect(!view.isHoldingStill)
        #expect(engine.heldPictureLastRelease == "stop")
        #expect(engine.heldPictureView == nil)
    }

    /// A host shaped like Sodalite: AVKit renders the native path, no `AetherPlayerView` is bound,
    /// and a still view is the only surface the engine has. Before it existed the hold returned
    /// without a trace (device log 2026-10-07: no `held picture` line at all).
    @Test("an AVKit host's still view carries the hold through the rebuild")
    func stillViewCarriesTheHold() async throws {
        let file = try await Self.fixtureURL()
        defer { try? FileManager.default.removeItem(at: file) }
        let engine = try AetherEngine()
        defer { engine.stop() }
        let still = AetherStillView(frame: CGRect(x: 0, y: 0, width: 320, height: 180))
        engine.bindStillView(still)
        _ = try await engine.load(url: file)
        let host = try #require(engine.nativeHost)
        try await waitFor { host.isVideoReadyForDisplay }
        let audioIndex = try #require(engine.activeAudioTrackIndex)

        var held = false
        let watcher = Task { @MainActor in
            while !Task.isCancelled {
                if still.isHoldingStill { held = true }
                try? await Task.sleep(for: .milliseconds(2))
            }
        }
        let failure = await engine.reloadWithAudioOverride(
            url: file, audioStreamIndex: Int32(audioIndex), expectedGeneration: engine.loadGeneration)
        #expect(failure == nil)
        try await waitFor { !still.isHoldingStill }
        watcher.cancel()

        #expect(held)
        #expect(engine.heldPictureLastSkip == nil)
        #expect(engine.heldPictureLastRelease == "first frame of the next item")
    }

    @Test("with no surface bound the hold says so instead of returning silently")
    func noSurfaceIsLogged() async throws {
        let file = try await Self.fixtureURL()
        defer { try? FileManager.default.removeItem(at: file) }
        let engine = try AetherEngine()
        defer { engine.stop() }
        _ = try await engine.load(url: file)
        let host = try #require(engine.nativeHost)
        try await waitFor { host.isVideoReadyForDisplay }
        engine.pause()
        await engine.holdPictureAcrossItemSwap()
        #expect(engine.heldPictureLastSkip == "no surface bound")
        #expect(engine.heldPictureView == nil)
    }

    @Test("a bound still view wins over the player view, and unbinding it takes the picture down")
    func stillViewWinsAndUnbindReleases() async throws {
        let file = try await Self.fixtureURL()
        defer { try? FileManager.default.removeItem(at: file) }
        let engine = try AetherEngine()
        defer { engine.stop() }
        let view = AetherPlayerView(frame: CGRect(x: 0, y: 0, width: 320, height: 180))
        let still = AetherStillView(frame: CGRect(x: 0, y: 0, width: 320, height: 180))
        engine.bind(view: view)
        engine.bindStillView(still)
        _ = try await engine.load(url: file)
        let host = try #require(engine.nativeHost)
        try await waitFor { host.isVideoReadyForDisplay }
        engine.pause()
        await engine.holdPictureAcrossItemSwap()
        #expect(still.isHoldingStill)
        #expect(!view.isHoldingStill)
        engine.unbindStillView(still)
        #expect(!still.isHoldingStill)
        #expect(engine.heldPictureLastRelease == "still view unbound")
    }

    @Test("Dolby Vision, PiP and external playback hold nothing")
    func skipReasons() {
        #expect(AetherEngine.heldPictureSkipReason(
            videoFormat: .hdr10, pictureInPictureActive: false, externalPlaybackActive: false) == nil)
        #expect(AetherEngine.heldPictureSkipReason(
            videoFormat: .dolbyVision, pictureInPictureActive: false, externalPlaybackActive: false) != nil)
        #expect(AetherEngine.heldPictureSkipReason(
            videoFormat: .sdr, pictureInPictureActive: true, externalPlaybackActive: false) != nil)
        #expect(AetherEngine.heldPictureSkipReason(
            videoFormat: .sdr, pictureInPictureActive: false, externalPlaybackActive: true) != nil)
    }
}

/// One track's position in the fixture writer, touched only on that track's own serial queue.
private final class FixtureCounter: @unchecked Sendable {
    var value = 0
}
