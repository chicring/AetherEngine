import Foundation

/// progressive VOD serve: tracks, per segment index, the staging file currently being produced and
/// how many of its bytes are safe to publish. The muxer commits a byte count after each fragment
/// flush (commit boundaries always fall on a moof+mdat edge), the cache completes the entry once
/// adopt() has renamed the file into place, and every discard path abandons it. The staging path
/// (which embeds a per-muxer UUID) IS the epoch identity: a restart muxer re-cutting the same index
/// commits under a new path, which replaces the entry and wakes the old entry's waiters as
/// .abandoned so a serve parked on the dead file can fall back instead of waiting forever.
///
/// Bytes ahead of the last commit are NEVER published: under +delay_moov / AE#222 the staging file
/// can be ftruncated (a discarded moov-prime fragment), so only a flush the muxer itself reported is
/// a stable read boundary.
final class ProgressiveSegmentBoard: @unchecked Sendable {

    /// What a serve needs to follow one in-production segment. `board` rides along so the provider
    /// hands the server a single entry point; equality ignores it (identity is index+path).
    struct Handle: Equatable {
        let index: Int
        let path: URL
        let board: ProgressiveSegmentBoard

        static func == (a: Handle, b: Handle) -> Bool {
            a.index == b.index && a.path == b.path
        }

        /// Same contract as `ProgressiveSegmentBoard.wait`.
        func wait(beyond: Int, until deadline: Date) -> Progress? {
            board.wait(self, beyond: beyond, until: deadline)
        }
    }

    enum Progress: Equatable {
        /// Producer flushed a fragment; bytes [0, n) of the staging file are complete boxes.
        case committed(Int)
        /// adopt() renamed the staging file into the cache; n is the final byte count.
        case completed(Int)
        /// The staging file was discarded, superseded, or the session closed.
        case abandoned
    }

    private enum Terminal: Equatable {
        case completed(Int)
        case abandoned
    }

    private struct Entry {
        var path: URL
        var committed: Int
        var terminal: Terminal?
    }

    private let condition = NSCondition()
    private var entries: [Int: Entry] = [:]

    /// Register or advance the committed boundary for `index`. A commit under a different path than
    /// the current entry is a new epoch (restart muxer): it replaces the entry wholesale and wakes
    /// the old waiters, which read the replacement as .abandoned for THEIR handle. `bytes` is
    /// monotone non-decreasing within one path; a stale lower count is ignored.
    func commit(index: Int, path: URL, bytes: Int) {
        condition.lock()
        if var e = entries[index], e.path == path {
            if bytes > e.committed { e.committed = bytes }
            entries[index] = e
        } else {
            entries[index] = Entry(path: path, committed: bytes, terminal: nil)
        }
        condition.broadcast()
        condition.unlock()
    }

    /// Mark the entry done after adopt() renamed the staging file into the cache. A serve holding
    /// an fd opened before the rename keeps reading it; a serve that has not opened yet falls back
    /// to the cache path. Ignored when the entry was replaced by a newer epoch (path mismatch) or
    /// already terminated.
    func complete(index: Int, path: URL, bytes: Int) {
        condition.lock()
        if var e = entries[index], e.path == path, e.terminal == nil {
            e.committed = max(e.committed, bytes)
            e.terminal = .completed(bytes)
            entries[index] = e
        }
        condition.broadcast()
        condition.unlock()
    }

    /// Mark the entry dead because its staging file was discarded or failed. Same ignore rules as
    /// complete(): a terminal entry is terminal, and an adopted file stays completed.
    func abandon(index: Int, path: URL) {
        condition.lock()
        if var e = entries[index], e.path == path, e.terminal == nil {
            e.terminal = .abandoned
            entries[index] = e
        }
        condition.broadcast()
        condition.unlock()
    }

    /// Session teardown (cache.close()): every in-production entry is dead.
    func abandonAll() {
        condition.lock()
        for (index, var e) in entries where e.terminal == nil {
            e.terminal = .abandoned
            entries[index] = e
        }
        condition.broadcast()
        condition.unlock()
    }

    /// The in-production entry for `index`, or nil when nothing is being produced for it (only
    /// completed/abandoned bookkeeping, or no entry at all).
    func handle(for index: Int) -> Handle? {
        condition.lock()
        defer { condition.unlock() }
        guard let e = entries[index], e.terminal == nil else { return nil }
        return Handle(index: index, path: e.path, board: self)
    }

    /// Block until the entry for `handle` commits beyond `beyond`, terminates, or `deadline`
    /// passes. A handle whose entry was replaced by a newer epoch or dropped reads .abandoned, so a
    /// serve never waits on a file that will never grow again. Nil = deadline elapsed.
    func wait(_ handle: Handle, beyond: Int, until deadline: Date) -> Progress? {
        condition.lock()
        defer { condition.unlock() }
        while true {
            guard let e = entries[handle.index], e.path == handle.path else {
                return .abandoned
            }
            if let terminal = e.terminal {
                switch terminal {
                case .completed(let n): return .completed(n)
                case .abandoned: return .abandoned
                }
            }
            if e.committed > beyond { return .committed(e.committed) }
            if !condition.wait(until: deadline) { return nil }
        }
    }
}
