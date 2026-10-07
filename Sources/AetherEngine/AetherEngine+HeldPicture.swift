import Foundation
import AVFoundation
import Combine

extension AetherEngine {

    /// The longest a held picture stays up when the next item never reports a first frame. The
    /// rebuild has its own failure paths; this only keeps a frozen frame from outliving them.
    static let heldPictureTimeoutSeconds: Double = 8

    /// AE#711 follow-up: hold the picture on screen across the in-place item swap of an audio switch.
    ///
    /// #711 keeps the old item mounted while the source reopens, but `replaceCurrentItem` still drops
    /// the `AVPlayerLayer` to black until the next item decodes its first frame, which a viewer sees
    /// as a flash on every switch. The frame is read from the paused old item (a paused item answers
    /// in about 20 ms; a playing one needs ~300 ms before a fresh output sees anything, which is why
    /// the caller pauses first) and laid over the layer until the next host session reports a
    /// picture. Call after the pause and before `stopInternal`.
    func holdPictureAcrossItemSwap() async {
        releaseHeldPicture(reason: nil)
        guard let host = nativeHost else { return }
        // A bound still view first: a host that binds one renders the native path through AVKit, and
        // its `AetherPlayerView`, if any, is not what is on screen.
        let surface: (any HeldStillSurface)? = boundStillView ?? boundView
        if let skip = surface == nil ? "no surface bound" : Self.heldPictureSkipReason(
            videoFormat: videoFormat, pictureInPictureActive: pictureInPictureActive,
            externalPlaybackActive: host.avPlayer.isExternalPlaybackActive) {
            heldPictureLastSkip = skip
            EngineLog.emit("[AetherEngine] held picture: skipped (\(skip))", category: .engine)
            return
        }
        guard let view = surface else { return }
        heldPictureLastSkip = nil
        let generation = loadGeneration
        let heldSession = host.sessionID
        let started = ContinuousClock.now
        guard let frame = await host.captureDisplayedFrame() else {
            heldPictureLastSkip = "no frame from the outgoing item"
            EngineLog.emit("[AetherEngine] held picture: no frame from the outgoing item", category: .engine)
            return
        }
        guard loadGeneration == generation, nativeHost === host,
              (boundStillView ?? boundView) === view else { return }
        let isHDR = videoFormat == .hdr10 || videoFormat == .hdr10Plus || videoFormat == .hlg
        guard view.showStill(frame, gravity: videoGravity, isHDR: isHDR) else {
            heldPictureLastSkip = "frame could not be wrapped for display"
            EngineLog.emit("[AetherEngine] held picture: frame could not be wrapped for display", category: .engine)
            return
        }
        heldPictureView = view
        heldPictureShownAt = .now
        heldPictureToken &+= 1
        let token = heldPictureToken
        heldPictureRelease = host.$isVideoReadyForDisplay
            .filter { [weak host] ready in ready && (host?.sessionID ?? heldSession) != heldSession }
            .first()
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.releaseHeldPicture(reason: "first frame of the next item") }
            }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.heldPictureTimeoutSeconds))
            guard let self, self.heldPictureToken == token, self.heldPictureView != nil else { return }
            self.releaseHeldPicture(reason: "timeout")
        }
        EngineLog.emit(
            "[AetherEngine] held picture: up after \(Self.milliseconds(ContinuousClock.now - started))ms "
            + "(\(CVPixelBufferGetWidth(frame))x\(CVPixelBufferGetHeight(frame)), hdr=\(isHDR))",
            category: .engine)
    }

    /// Takes the held picture down. `reason` nil is a silent clear (nothing was up, or a new hold
    /// replaces it); every other release is logged with how long the picture stood.
    func releaseHeldPicture(reason: String?) {
        heldPictureRelease?.cancel()
        heldPictureRelease = nil
        guard let view = heldPictureView else { return }
        view.clearStill()
        heldPictureView = nil
        heldPictureLastRelease = reason
        if let reason, let shownAt = heldPictureShownAt {
            EngineLog.emit(
                "[AetherEngine] held picture: released after \(Self.milliseconds(ContinuousClock.now - shownAt))ms (\(reason))",
                category: .engine)
        }
        heldPictureShownAt = nil
    }

    /// Why no picture is held. Dolby Vision: the output vends the base layer, which for Profile 5 has
    /// no displayable colour of its own. PiP and external playback: the picture is not in this view.
    nonisolated static func heldPictureSkipReason(
        videoFormat: VideoFormat, pictureInPictureActive: Bool, externalPlaybackActive: Bool
    ) -> String? {
        if videoFormat == .dolbyVision { return "Dolby Vision" }
        if pictureInPictureActive { return "picture in picture" }
        if externalPlaybackActive { return "external playback" }
        return nil
    }

    private nonisolated static func milliseconds(_ duration: Duration) -> Int {
        Int(duration.components.seconds * 1000 + duration.components.attoseconds / 1_000_000_000_000_000)
    }
}
