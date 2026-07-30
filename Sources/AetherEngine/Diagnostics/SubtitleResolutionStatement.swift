import Foundation

/// #250: one line stating the absolute source-time span the subtitle path has decoded display
/// state over, fenced by the engine's own generation counters.
///
/// The question it answers is the one no existing surface can: after a far seek lands, has the
/// pipeline DETERMINED the display state at the rendered position, or has it merely not produced
/// anything yet? On a PGS track with no acquisition point those two are indistinguishable from
/// outside, and every other subtitle diagnostic is playhead-relative, ungated by generation, or
/// states the harvest frontier rather than how far determination has advanced.
///
/// Neither of the two obvious candidates for `resolvedThrough` can be used:
///
/// - The drain window's own end (`playhead + subtitleDrainLeadSeconds`) claims determination over
///   bytes nobody has read. An empty window is ambiguous between "no cue here" and "not harvested
///   yet", which is precisely the ambiguity this line exists to remove.
/// - The drain cursor (`lastDecodedPts`) is the last actual cue. On a sparse track it stands still
///   for minutes, so every dialogue pause would read as unresolved.
///
/// So it is the decode window clamped to a harvest frontier, and the frontier's SOURCE travels with
/// it. `via=prefetch` is exact: since #230 the #151 reader's banked position is the read position on
/// the source axis (a cue PTS for a harvested packet, the monotone read DTS for a pacing one), so
/// everything below it that is not in the store genuinely carries no subtitle packet. `via=eof` is
/// the strongest state: the reader reached end of stream, so the whole window is determined.
/// `via=pump` is the weak one and says so: the producer tap has no read-position surface at all,
/// so the claim collapses to the drain cursor, a lower bound rather than a contiguity claim. A
/// `via=pump` line is itself the answer "not determined beyond what is already on screen".
enum SubtitleResolutionStatement {

    /// What bounds `resolvedThrough`, and therefore how much the number is worth.
    enum Frontier: String, Sendable {
        /// The #151 side reader's banked read position. Exact.
        case prefetch
        /// The side reader reached end of stream; the window is determined in full.
        case eof
        /// No usable side-reader frontier (never started, exited, or fenced to a superseded
        /// generation). Falls back to the drain cursor: a lower bound, not a contiguity claim.
        case pump
    }

    /// Why the line was emitted. Deliberately not every drain tick: the drainer runs at 2 Hz per
    /// channel and a statement per tick would bury the transitions that carry the information.
    enum Reason: String, Sendable {
        /// A post-seek reconstruction window finished decoding.
        case reconstruction
        /// Steady-state cadence, riding the 30 s memory probe.
        case tick
        /// The forward prefetcher reached end of stream.
        case eof
        /// The frontier's source changed, e.g. the prefetcher died and the pump is all that is left.
        case frontier
    }

    /// The engine's fence for a subtitle-resolution claim. A side-reader frontier is only usable
    /// while both counters still match the engine's live ones: `loadGeneration` rules out a
    /// different source entirely, `seekGeneration` rules out a position banked before the seek in
    /// question. Counting log lines cannot do this, which is the whole reason the numbers are here.
    struct Fence: Equatable, Sendable {
        var loadGeneration: UInt64
        var seekGeneration: UInt64

        init(loadGeneration: UInt64 = 0, seekGeneration: UInt64 = 0) {
            self.loadGeneration = loadGeneration
            self.seekGeneration = seekGeneration
        }
    }

    struct Statement: Equatable, Sendable {
        var fence: Fence
        var streamIndex: Int32
        var coveredFrom: Double
        /// nil when nothing inside the window is determined at all.
        var resolvedThrough: Double?
        var via: Frontier
        /// The last packet actually handed to the overlay decoder. Kept alongside
        /// `resolvedThrough` so a sparse stretch stays distinguishable from a starved one.
        var decodedThrough: Double
        var reason: Reason
    }

    /// Which frontier bounds the claim. Split out because the drain tick needs it every tick to
    /// notice a change of source, and that check must not cost a store scan: it depends only on
    /// the side reader's fenced state.
    static func via(prefetchFrontier: Double?, prefetchAtEndOfFile: Bool) -> Frontier {
        if prefetchAtEndOfFile { return .eof }
        if let prefetchFrontier, prefetchFrontier.isFinite { return .prefetch }
        return .pump
    }

    /// Build the statement from what the drain tick and the prefetch telemetry each know.
    ///
    /// - Parameters:
    ///   - windowThrough: the decode window's lead edge, `playhead + lead`.
    ///   - coveredFrom: the start of the contiguous decoded run, i.e. the window start of the last
    ///     reset. Not the current tick's window start: steady ticks decode forward from the cursor.
    ///   - decodedThrough: the drain cursor, the last packet handed to the overlay decoder. Also
    ///     the pump case's whole answer: the drainer scans its window every tick, so the cursor is
    ///     the last packet stored inside it. A session-wide store frontier could not stand in for
    ///     that, since after a backward seek it sits far ahead of the window and would claim
    ///     determination over a region the pump never revisited.
    ///   - prefetchFrontier: the side reader's banked read position, or nil when it is unusable.
    ///     The caller is responsible for the fence check; an unfenced position is worse than none.
    ///   - prefetchAtEndOfFile: the fenced session ended at EOF.
    static func make(
        fence: Fence,
        streamIndex: Int32,
        coveredFrom: Double,
        windowThrough: Double,
        decodedThrough: Double,
        prefetchFrontier: Double?,
        prefetchAtEndOfFile: Bool,
        reason: Reason
    ) -> Statement {
        let via = self.via(prefetchFrontier: prefetchFrontier,
                           prefetchAtEndOfFile: prefetchAtEndOfFile)
        let bound: Double?
        switch via {
        case .eof: bound = windowThrough
        case .prefetch: bound = prefetchFrontier
        case .pump: bound = decodedThrough
        }
        var resolved: Double? = nil
        if let bound, bound.isFinite, bound >= coveredFrom {
            resolved = min(bound, windowThrough)
        }
        return Statement(fence: fence, streamIndex: streamIndex, coveredFrom: coveredFrom,
                         resolvedThrough: resolved, via: via, decodedThrough: decodedThrough,
                         reason: reason)
    }

    static func format(_ s: Statement) -> String {
        let resolved = s.resolvedThrough.map { String(format: "%.2f", $0) } ?? "none"
        let decoded = s.decodedThrough.isFinite ? String(format: "%.2f", s.decodedThrough) : "none"
        return "[AetherEngine] #250 subtitle-resolution "
            + "loadGen=\(s.fence.loadGeneration) seekGen=\(s.fence.seekGeneration) "
            + "stream=\(s.streamIndex) "
            + "coveredFrom=\(String(format: "%.2f", s.coveredFrom)) "
            + "resolvedThrough=\(resolved) "
            + "via=\(s.via.rawValue) "
            + "decodedThrough=\(decoded) "
            + "reason=\(s.reason.rawValue)"
    }
}
