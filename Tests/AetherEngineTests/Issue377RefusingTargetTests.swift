// Tests/AetherEngineTests/Issue377RefusingTargetTests.swift
// AE#377 round 3: after the bounded keep-pin grace (#380) drops the pin, the reporter's ladder was
// refused four more times at the same offset and nothing in the log said WHO refused. A pin is only
// recorded from a 2xx, deliberately, so a re-resolve that lands on a refusing target is written down
// nowhere, and from outside the drop the three shapes are indistinguishable: the source refused the
// re-resolve itself, the source handed back the target just dropped, or a genuinely fresh target
// refused. Only the last one means the origin meters us, and the three need three different fixes.
// These tests pin the verdict, and pin that it is keyed on the ORIGIN rather than on the whole URL:
// a re-minted link carries a fresh signature for the same host, and reading that as a fresh target
// is the misreading the line exists to prevent.
import XCTest
@testable import AetherEngine

final class Issue377RefusingTargetTests: XCTestCase {

    private let source = URL(string: "https://proxy.example.dev/stream/abc?token=one")!
    private let pinned = URL(string: "https://nexus-177.cdn.example.st/file.mkv?sig=aaa")!

    func testSourceItselfRefusedIsNotReadAsATarget() {
        let verdict = AVIOReader.describeRespondingTarget(
            responded: URL(string: "https://proxy.example.dev/stream/abc?token=two")!,
            source: source, pinned: nil, dropped: pinned)
        XCTAssertTrue(verdict.contains("from the source itself"), verdict)
        XCTAssertTrue(verdict.contains("proxy.example.dev"), verdict)
    }

    func testPinnedTargetRefusedNamesThePin() {
        let verdict = AVIOReader.describeRespondingTarget(
            responded: pinned, source: source, pinned: pinned, dropped: nil)
        XCTAssertTrue(verdict.contains("from the pinned target"), verdict)
        XCTAssertTrue(verdict.contains("nexus-177.cdn.example.st"), verdict)
    }

    /// The shape that defeats a bounded keep-pin: the drop spends a re-resolve and the source mints
    /// the same edge host again. A fresh signature on that host is still the same lease.
    func testReMintedSameHostIsNotAFreshTarget() {
        let reMinted = URL(string: "https://nexus-177.cdn.example.st/file.mkv?sig=zzz")!
        let verdict = AVIOReader.describeRespondingTarget(
            responded: reMinted, source: source, pinned: nil, dropped: pinned)
        XCTAssertTrue(verdict.contains("the source minted again"), verdict)
        XCTAssertFalse(verdict.contains("resolved freshly"), verdict)
    }

    /// The one outcome that keeps metering on the table.
    func testFreshTargetRefusedIsNamedAsFresh() {
        let fresh = URL(string: "https://nexus-097.cdn.example.st/file.mkv?sig=bbb")!
        let verdict = AVIOReader.describeRespondingTarget(
            responded: fresh, source: source, pinned: nil, dropped: pinned)
        XCTAssertTrue(verdict.contains("resolved freshly"), verdict)
        XCTAssertTrue(verdict.contains("nexus-097.cdn.example.st"), verdict)
    }

    /// The shape one `dropped` slot cannot hold. The reporter's session refused in three separate
    /// windows, and by the second window the target the FIRST one dropped is no longer the slot's
    /// occupant, so a re-mint of it fell into the fresh arm: metering put back on the table by the
    /// very evidence meant to rule it out. Every target this session has dropped stays known.
    func testATargetAnEarlierWindowDroppedIsNotFresh() {
        let earlier = URL(string: "https://nexus-042.cdn.example.st/file.mkv?sig=old")!
        let reMinted = URL(string: "https://nexus-042.cdn.example.st/file.mkv?sig=new")!
        let verdict = AVIOReader.describeRespondingTarget(
            responded: reMinted, source: source, pinned: nil, dropped: pinned,
            droppedEarlier: [OriginRequestBudget.originKey(for: earlier)!])
        XCTAssertFalse(verdict.contains("resolved freshly"), verdict)
        XCTAssertTrue(verdict.contains("an earlier window dropped"), verdict)
    }

    /// A port or scheme change is a different origin even on the same host, because that is what the
    /// budget keys on and the two lines have to agree about what one target is.
    func testPortIsPartOfTheIdentity() {
        let otherPort = URL(string: "https://nexus-177.cdn.example.st:8443/file.mkv")!
        let verdict = AVIOReader.describeRespondingTarget(
            responded: otherPort, source: source, pinned: nil, dropped: pinned)
        XCTAssertTrue(verdict.contains("resolved freshly"), verdict)
    }

    func testNoResponseURLSaysNothing() {
        XCTAssertEqual(
            AVIOReader.describeRespondingTarget(
                responded: nil, source: source, pinned: pinned, dropped: nil),
            "")
    }
}
