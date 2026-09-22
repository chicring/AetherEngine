import Foundation
import Testing
@testable import AetherEngine

/// Resume-intent contract regressions (the D5/D6 candidates, both fixed; this file pins the
/// contracts rather than documenting defects):
///
/// D5 — `AudioPlaybackHost`'s `onEnd` must do what `SoftwarePlaybackHost.parkClockAtEndOfMedia`
/// (AE#374) does: the master clock (synchronizer) stops at the end and `rate` reads 0, instead of
/// free-running `currentTime` past `duration` without bound.
///
/// D6 — `engine.setRate(0)` is a pause, and on the non-native paths `engine.state` must be written
/// by the engine itself: the native video path maps the pause back through its
/// `host.$timeControlStatus` sink, while SW/audio/audioNative wire none (`loadSoftware`/`loadAudio`
/// attach `wireCommonHostSinks` only, and `loadAudioNative` refuses a transport status on purpose).
/// Otherwise the host has stopped while `state` reports `.playing` forever, and the next
/// `togglePlayPause`'s "play" is swallowed as a pause for a round.
@Suite("Resume-intent contract (D5/D6)")
struct ResumeIntentCandidateVerificationTests {

    /// Little-endian 16-bit PCM WAV with a 440 Hz sine, built in memory (same fixture shape as
    /// `AudioTapDecoderTests.makeWAV`).
    private func makeWAV(sampleRate: Int, channels: Int, seconds: Double) -> Data {
        let frames = Int(Double(sampleRate) * seconds)
        var pcm = Data(capacity: frames * channels * 2)
        for n in 0..<frames {
            let v = Int16(9000 * sin(2 * .pi * 440 * Double(n) / Double(sampleRate)))
            for _ in 0..<channels {
                withUnsafeBytes(of: v.littleEndian) { pcm.append(contentsOf: $0) }
            }
        }
        var d = Data()
        func str(_ s: String) { d.append(s.data(using: .ascii)!) }
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        str("RIFF"); u32(UInt32(36 + pcm.count)); str("WAVE")
        str("fmt "); u32(16); u16(1); u16(UInt16(channels)); u32(UInt32(sampleRate))
        u32(UInt32(sampleRate * channels * 2)); u16(UInt16(channels * 2)); u16(16)
        str("data"); u32(UInt32(pcm.count)); d.append(pcm)
        return d
    }

    // MARK: - D5: end of media must park the master clock (AE#374 parity)

    /// Contract: end of media parks the master clock (the `SoftwarePlaybackHost.parkClockAtEndOfMedia`
    /// shape) — `rate` reads 0 and `currentTime` does not run past `duration`.
    @MainActor
    @Test("D5: audio host parks its clock at end of media")
    func audioHostParksClockAtEnd() async throws {
        let demuxer = Demuxer()
        try demuxer.open(reader: DataIOReader(
            data: makeWAV(sampleRate: 48_000, channels: 2, seconds: 0.5)))
        let host = AudioPlaybackHost()
        try await host.load(demuxer: demuxer, startPosition: nil, audioSourceStreamIndex: nil)
        defer { host.stop() }
        host.play()

        // Wait for onEnd (demuxer EOF + the render queue draining; a 0.5 s clip must arrive
        // well inside 5 s).
        var waited = 0.0
        while !host.didReachEnd, waited < 5.0 {
            try await Task.sleep(nanoseconds: 100_000_000)
            waited += 0.1
        }
        try #require(host.didReachEnd, "audio host never reported end of media within 5 s")

        // One more beat past the end: the clock must sit at `duration`, not keep walking.
        try await Task.sleep(nanoseconds: 1_000_000_000)
        #expect(host.rate == 0,
                "master clock still carries rate \(host.rate) past end of media")
        #expect(host.currentTime <= host.duration + 0.5,
                "clock free-ran to \(host.currentTime)s past \(host.duration)s of media")
    }

    // MARK: - D6: engine.setRate(0) is a pause; the published state must say so

    /// Contract: `engine.state == .paused` after `engine.setRate(0)`. The native path's equivalent
    /// is setRate(0) -> playIntent=false -> tcs .paused -> the sink lands `.paused`; the SW/audio
    /// paths wire no sink that maps a host pause back, so `engine.setRate` writes it itself.
    @MainActor
    @Test("D6: setRate(0) on the software path publishes .paused")
    func setRateZeroPublishesPausedOnSoftware() throws {
        let engine = try AetherEngine()
        engine.state = .playing
        engine.softwareHost = SoftwarePlaybackHost()
        engine.setRate(0)
        #expect(engine.state == .paused,
                "engine.state stayed \(engine.state) although the host was paused by setRate(0)")
    }

    @MainActor
    @Test("D6: setRate(0) on the FFmpeg audio path publishes .paused")
    func setRateZeroPublishesPausedOnAudio() throws {
        let engine = try AetherEngine()
        engine.state = .playing
        engine.audioHost = AudioPlaybackHost()
        engine.setRate(0)
        #expect(engine.state == .paused,
                "engine.state stayed \(engine.state) although the host was paused by setRate(0)")
    }
}
