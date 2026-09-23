import Foundation

/// #240: who gets the source link when the video path and a subtitle side reader want it at once.
///
/// A subtitle side reader is a second, independent connection to the same origin, and on Matroska it
/// is a second full copy of the stream: `matroska_parse_cluster` reads every block off the wire and
/// only `matroska_parse_block` then honours `AVDISCARD_ALL`, so a "subtitle-only" reader still pulls
/// the video and audio bytes (see `reference` note in `AetherEngine+Subtitles`). A session with
/// subtitles on therefore asks the link for roughly twice the media rate. Above about 2x headroom
/// nobody notices. At 1.3x to 1.5x, which is an ordinary Wi-Fi bench in front of a high-bitrate
/// remux, the two readers split the link and the video path misses its deadlines: the reporter of
/// #240 measured the same segment taking 2.2 s alone and 7.5 s alongside the prefetcher, which
/// expired the seek landing budget and started a re-anchor cycle that fed itself (each re-anchor
/// jumps the clock, each clock jump rebuilds the prefetch session, each rebuild takes more link).
///
/// The arbitration is a strict priority, not a share: playback is load-bearing, subtitle lookahead
/// is not. The side reader fetches while the video path does not need the link, which on a fast link
/// is nearly always (the producer parks as soon as its forward buffer is full) and on a starved link
/// is the time between catch-up bursts. Two escapes keep it from being a mute switch: a grace window
/// after each anchor, so a freshly selected track fills even against a busy video path, and a
/// continuous-yield cap, so a video path that never parks (a wedged pump, a host that never reports
/// one) cannot silently disable subtitle lookahead for the rest of the session.
enum SideReaderLinkPolicy {

    /// How long a side reader may fetch unconditionally after it anchors or re-anchors, so the cues
    /// around the new position reach the store even while the video path is busy.
    ///
    /// This used to be a lead floor ("fetch while less than 5 s ahead of the playhead"), which is
    /// wrong in exactly the case the arbitration exists for. On a link that cannot carry two
    /// readers the side reader never gets ahead at all, so its lead stays negative, so the floor
    /// never expires: measured on a 1.4x bench, the reader took 47% of the link with the floor rule
    /// in force and the seek landings did not move. A grace window cannot get stuck that way, and
    /// it protects the case that actually needed protecting, which is the freshly selected track
    /// with nothing in the store yet, not steady-state lookahead.
    static let anchorGraceSeconds: Double = 8

    /// Grace re-armed after an in-place re-anchor (a playhead jump). Unlike the session-start
    /// grace, this one defaults to zero: the pump's keep-set taps every embedded subtitle stream
    /// across the region it produces, so the cues around a fresh playhead are harvested by the
    /// producer itself, and an unconditional 8 s fetch window lands exactly on the post-seek
    /// buffer refill that is most deadline-sensitive on a link without headroom. A reader that
    /// re-anchored while the producer is parked fetches immediately anyway, since nothing is
    /// producing; one that needs the link regardless still gets the yield cap's valve grant.
    static let reanchorGraceSeconds: Double = 0

    /// Longest continuous yield before the side reader takes the link anyway. Longer than the seek
    /// machinery's whole budget (8 s + 4x4 s extensions + re-anchor waits, #216), so a real seek
    /// never trips it and only a stuck signal does.
    static let maxYieldSeconds: Double = 60

    /// Kill switch for the startup rule, for measurement and tests. When false, rule 3 below and
    /// the startup half of `shouldDeferOpen` are skipped — exact previous behaviour.
    nonisolated(unsafe) static var sideReadersYieldDuringStartup = true

    /// Whether the side reader must leave the link to the video path right now.
    ///
    /// Ordered so each rule is decidable on its own:
    /// 1. the cap fires first, because its whole purpose is to override a signal that is not clearing
    /// 2. a seek in flight yields unconditionally: the landing budget is what this exists to protect
    /// 3. playback startup with a fetching producer yields, and the grace does NOT override it:
    ///    startup is the one window where playback has no buffer yet, the pump's own keep-set
    ///    harvests the cues at the playhead, and the field trace showed the reader's anchor grace
    ///    halving the pump exactly there (the first segment's ~4 s watchdog does not wait). A
    ///    paused or parked startup — videoProducing false — still lets the reader fetch, so a
    ///    load that never plays is not starved of lookahead
    /// 4. inside its anchor grace the reader fetches, so a fresh selection is not left with an empty
    ///    store on a busy link
    /// 5. an actively fetching producer wins the link
    static func shouldYield(
        seeking: Bool,
        startingUp: Bool,
        videoProducing: Bool,
        inAnchorGrace: Bool,
        yieldedSeconds: Double,
        maxYieldSeconds: Double = SideReaderLinkPolicy.maxYieldSeconds
    ) -> Bool {
        if yieldedSeconds >= maxYieldSeconds { return false }
        if seeking { return true }
        if sideReadersYieldDuringStartup, startingUp, videoProducing { return true }
        if inAnchorGrace { return false }
        return videoProducing
    }
}

/// #240: the live view of what the video path is doing, shared with the side readers.
///
/// `videoProducing` is a count, not a flag: a producer restart overlaps an exiting pump with a
/// starting one, and a plain Bool would let the old pump's teardown clear the new pump's claim. Any
/// pull from the source counts, so the readers see "someone is fetching" rather than "producer N is".
final class SideReaderLinkGate: @unchecked Sendable {
    private let lock = NSLock()
    private var seeking = false
    /// Defaults to startup: until a session's first roll reports otherwise, holding the link for
    /// playback is the safe read (rule 3 also requires `videoProducing`, so an idle engine is not
    /// treated as starting up).
    private var startingUp = true
    private var producingCount = 0

    init() {}

    /// Wired to `AetherEngine.isSeeking` (programmatic + native scrub, both flags).
    func setSeeking(_ inFlight: Bool) {
        lock.lock()
        seeking = inFlight
        lock.unlock()
    }

    /// Wired to `AetherEngine.hasTransportRolled` (inverted): true from each session reset until
    /// this load's transport has actually rolled once.
    func setStartingUp(_ inFlight: Bool) {
        lock.lock()
        startingUp = inFlight
        lock.unlock()
    }

    /// A pump started pulling from the source, or resumed after a park.
    func videoFetchBegan() {
        lock.lock()
        producingCount += 1
        lock.unlock()
    }

    /// A pump parked or exited. Balanced with `videoFetchBegan` at every call site.
    func videoFetchEnded() {
        lock.lock()
        producingCount = max(0, producingCount - 1)
        lock.unlock()
    }

    var state: (seeking: Bool, startingUp: Bool, videoProducing: Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (seeking, startingUp, producingCount > 0)
    }
}

/// #240: the side reader's half of the arbitration, injectable so the loops stay testable.
///
/// Holds the state source plus the tuning, so a reader loop asks one question and the tests can
/// drive every rule without an engine, a producer or a network.
struct SideReaderLinkArbiter: Sendable {
    let state: @Sendable () -> (seeking: Bool, startingUp: Bool, videoProducing: Bool)
    var anchorGraceSeconds: Double = SideReaderLinkPolicy.anchorGraceSeconds
    /// See `SideReaderLinkPolicy.reanchorGraceSeconds`: applied to the re-arm after an in-place
    /// move, kept separate from the session-start grace.
    var reanchorGraceSeconds: Double = SideReaderLinkPolicy.reanchorGraceSeconds
    var maxYieldSeconds: Double = SideReaderLinkPolicy.maxYieldSeconds
    /// How long the reader keeps the link once the cap has fired, before it starts asking again.
    /// Without a window the valve would be worthless: the cap is evaluated per loop iteration, so it
    /// would hand back one packet and yield for another full cap, which on a video path that never
    /// parks is indistinguishable from having no lookahead at all. A grant window turns it into a
    /// duty cycle (10 s of every 70), which is slow but alive.
    var valveGrantSeconds: Double = 10
    var pollNanoseconds: UInt64 = 250_000_000

    init(gate: SideReaderLinkGate) {
        self.state = { gate.state }
    }

    init(state: @escaping @Sendable () -> (seeking: Bool, startingUp: Bool, videoProducing: Bool)) {
        self.state = state
    }

    /// Whether the arbiter would hold a reader that has banked nothing yet. Used by the open path,
    /// which has no lead of its own: a session being built has read zero seconds ahead.
    func shouldDeferOpen() -> Bool {
        let now = state()
        return now.seeking
            || (SideReaderLinkPolicy.sideReadersYieldDuringStartup
                && now.startingUp && now.videoProducing)
    }

    /// Whether the reader is currently held by the startup rule (3) specifically, for the
    /// once-per-session log line. A seek wins over startup in the rule order, so it is checked
    /// first; the grace does not reach this question (rule 3 sits above it).
    func isHoldingForStartup() -> Bool {
        let now = state()
        return SideReaderLinkPolicy.sideReadersYieldDuringStartup
            && !now.seeking && now.startingUp && now.videoProducing
    }

    func shouldYield(inAnchorGrace: Bool, yieldedSeconds: Double) -> Bool {
        let now = state()
        return SideReaderLinkPolicy.shouldYield(
            seeking: now.seeking,
            startingUp: now.startingUp,
            videoProducing: now.videoProducing,
            inAnchorGrace: inAnchorGrace,
            yieldedSeconds: yieldedSeconds,
            maxYieldSeconds: maxYieldSeconds)
    }

    var pollSeconds: Double { Double(pollNanoseconds) / 1_000_000_000 }
}
