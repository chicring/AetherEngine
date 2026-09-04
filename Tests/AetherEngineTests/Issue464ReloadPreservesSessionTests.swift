import Foundation
import Testing
@testable import AetherEngine

/// AE#464 round 2 (cmcpherson274, measured on tvOS 26.6): what a session-preserving reload has to
/// preserve. Both of these were reachable from every rebuild the engine makes on its own, not just
/// from an audio-delay nudge, and neither failed visibly: one settled the rebuilt host paused with
/// no error, the other rebuilt the session at its head.
@Suite("AE#464 round 2: a session-preserving rebuild preserves the transport")
struct Issue464RebuildTransportTests {

    @Test("a host that owns transport gets its session back playing, not frozen on the mount flag")
    func nativeIntentWins() {
        // The reported shape: LoadOptions.autoplay = false because the app drives transport itself.
        // Replaying that flag left the rebuilt host at timeControlStatus=paused for 40 s while the
        // producer parked on a consumer that would never ask for a segment, and the host reported
        // progress the whole time. What the rebuild has to come back in is the session's own intent.
        #expect(AetherEngine.rebuildResumesPlaying(state: .playing, nativeTransportIntent: true))
        #expect(!AetherEngine.rebuildResumesPlaying(state: .playing, nativeTransportIntent: false))
    }

    @Test("the durable intent outranks the momentary state, so a rebuild mid-seek is not a pause")
    func intentSurvivesAScrub() {
        // #122: `transportIntentIsPlaying` is the last engine-routed transport command and survives a
        // seek; `state` is `.seeking` for the whole landing. Reading the state there would turn every
        // correction raised during a scrub into a stop.
        #expect(AetherEngine.rebuildResumesPlaying(state: .seeking, nativeTransportIntent: true))
        // And the reverse: a paused scrub stays paused, which is the same thing #123's finalize wants.
        #expect(!AetherEngine.rebuildResumesPlaying(state: .seeking, nativeTransportIntent: false))
    }

    @Test("routes with no competing transport owner answer from state, as togglePlayPause does")
    func softwareAndAudioFallBackToState() {
        #expect(AetherEngine.rebuildResumesPlaying(state: .playing, nativeTransportIntent: nil))
        #expect(AetherEngine.rebuildResumesPlaying(state: .seeking, nativeTransportIntent: nil))
        #expect(!AetherEngine.rebuildResumesPlaying(state: .paused, nativeTransportIntent: nil))
    }

    @Test("a session that was not running does not come back running")
    func terminalStatesDoNotResume() {
        #expect(!AetherEngine.rebuildResumesPlaying(state: .idle, nativeTransportIntent: nil))
        #expect(!AetherEngine.rebuildResumesPlaying(state: .loading, nativeTransportIntent: nil))
        #expect(!AetherEngine.rebuildResumesPlaying(state: .ended, nativeTransportIntent: nil))
        #expect(!AetherEngine.rebuildResumesPlaying(state: .error("x"), nativeTransportIntent: nil))
    }
}

@Suite("AE#464 round 2: a rebuild stacked behind another one keeps the playhead")
struct Issue464RebuildPositionTests {

    @Test("with no load in flight the clock is the playhead, exactly as before")
    func steadyStateReadsTheClock() {
        #expect(AetherEngine.rebuildPosition(state: .playing, clock: 15.3, underReconstruction: nil) == 15.3)
        #expect(AetherEngine.rebuildPosition(state: .playing, clock: 15.3, underReconstruction: 0) == 15.3)
        #expect(AetherEngine.rebuildPosition(state: .paused, clock: 15.3, underReconstruction: 0) == 15.3)
    }

    @Test("a load in flight has zeroed the clock, so the parked position is the honest one")
    func stackedReloadKeepsThePosition() {
        // The measured leg: three stepper presses inside one runloop turn (10:32:42.804-.807) started
        // three reloads. Generations 2 and 3 were superseded, and the survivor snapshotted a clock
        // that generation 2's load had already reset, so it cut seg0+ on a title 15 s in.
        #expect(AetherEngine.rebuildPosition(state: .loading, clock: 0, underReconstruction: 15.3) == 15.3)
    }

    @Test("nothing parked means nothing invented; the clock still answers")
    func nothingParkedFallsThrough() {
        #expect(AetherEngine.rebuildPosition(state: .loading, clock: 0, underReconstruction: nil) == 0)
    }

    @Test("a cold load parks its own head, so a reload during startup does not resurrect a stale position")
    func coldLoadParksZero() {
        // `load` parks `startPosition ?? 0`. A fresh load at the head therefore parks 0, which is
        // what a reload stacked onto it must read: the previous session's playhead is gone.
        #expect(AetherEngine.rebuildPosition(state: .loading, clock: 0, underReconstruction: 0) == 0)
    }
}
