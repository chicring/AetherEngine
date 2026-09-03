import Foundation
import Testing
@testable import AetherEngine

/// AE#460: `reloadAtCurrentPosition(applying:)` is the session-preserving rebuild with the options
/// it replays taken from the host. These pin the two rules that make handing a host the whole
/// `LoadOptions` struct safe: the fields that name the session are refused by name, and a refusal
/// leaves the session exactly as it was.
@MainActor
struct Issue460SessionOptionCorrectionTests {

    @Test("the identity list is a real subset of the struct, so a rename cannot leave a dead entry")
    func identityFieldsExist() {
        for field in SessionOptionCorrection.loadIdentityFields {
            #expect(SessionOptionCorrection.knownFields.contains(field),
                    "loadIdentityFields names \(field), which LoadOptions no longer carries")
        }
    }

    /// The inventory guard. A field added to `LoadOptions` is correctable by default (it falls
    /// through `refusedFields`), which is right for a tuning lever and wrong for one that names the
    /// session, so adding one has to be a decision. This fails until someone makes it.
    @Test("every LoadOptions field is accounted for as identity or as correctable")
    func fieldInventoryIsComplete() {
        let actual = Mirror(reflecting: LoadOptions()).children.compactMap(\.label)
        // LoadOptions changed shape. Decide for each new field whether it names the session (add
        // it to loadIdentityFields) or tunes it, then update knownFields.
        #expect(actual == SessionOptionCorrection.knownFields)
    }

    @Test("a tuning change is honoured")
    func tuningChangeIsHonoured() {
        var base = LoadOptions()
        base.audioBridgeMode = .surroundCompat
        var proposed = base
        proposed.audioBridgeMode = .lossless
        proposed.httpHeaders["Authorization"] = "Bearer fresh"
        #expect(SessionOptionCorrection.refusedFields(from: base, to: proposed).isEmpty)
    }

    @Test("each load-identity field is refused by name")
    func identityChangesAreRefused() {
        let base = LoadOptions()
        var live = base; live.isLive = true
        #expect(SessionOptionCorrection.refusedFields(from: base, to: live) == ["isLive"])
        var audioOnly = base; audioOnly.audioOnly = true
        #expect(SessionOptionCorrection.refusedFields(from: base, to: audioOnly) == ["audioOnly"])
        var hls = base; hls.nativeRemoteHLS = true
        #expect(SessionOptionCorrection.refusedFields(from: base, to: hls) == ["nativeRemoteHLS"])
        var sequential = base; sequential.sequentialOrigin = true
        #expect(SessionOptionCorrection.refusedFields(from: base, to: sequential) == ["sequentialOrigin"])
    }

    @Test("several identity changes are all named, not just the first")
    func identityChangesAreAllNamed() {
        let base = LoadOptions()
        var proposed = base
        proposed.isLive = true
        proposed.sequentialOrigin = true
        proposed.autoplay = false
        #expect(SessionOptionCorrection.refusedFields(from: base, to: proposed)
                == ["isLive", "sequentialOrigin"])
    }

    @Test("changedFields names what moved and stays quiet when nothing did")
    func changedFieldsNamesTheChange() {
        let base = LoadOptions()
        #expect(SessionOptionCorrection.changedFields(from: base, to: base).isEmpty)
        var proposed = base
        proposed.autoplay = false
        proposed.teletextPage = 888
        #expect(SessionOptionCorrection.changedFields(from: base, to: proposed)
                == ["autoplay", "teletextPage"])
    }

    /// `String(describing:)` on a Dictionary iterates in hash order, which depends on the storage
    /// capacity, so two equal `httpHeaders` built differently can describe differently. The struct's
    /// own `==` short-circuits the identical case, so the hazard only shows when some OTHER field
    /// moved: the log line would then name a header change nobody made.
    @Test("equal headers built at different capacities do not report a change")
    func headerOrderDoesNotFakeAChange() {
        var base = LoadOptions()
        base.httpHeaders = ["Authorization": "Bearer a", "Referer": "https://example.test", "User-Agent": "x"]
        var proposed = base
        var rebuilt: [String: String] = [:]
        rebuilt.reserveCapacity(256)
        rebuilt["User-Agent"] = "x"
        rebuilt["Referer"] = "https://example.test"
        rebuilt["Authorization"] = "Bearer a"
        proposed.httpHeaders = rebuilt
        proposed.autoplay = false
        #expect(SessionOptionCorrection.changedFields(from: base, to: proposed) == ["autoplay"])
    }

    @Test("a real header change is still reported")
    func headerChangeIsReported() {
        var base = LoadOptions()
        base.httpHeaders = ["Authorization": "Bearer stale"]
        var proposed = base
        proposed.httpHeaders["Authorization"] = "Bearer fresh"
        #expect(SessionOptionCorrection.changedFields(from: base, to: proposed) == ["httpHeaders"])
    }
}

@MainActor
struct Issue460ReloadWithOptionsTests {

    @Test("a session that was never loaded says why it cannot be rebuilt")
    func refusalIsReadableWithoutAttemptingTheReload() throws {
        let engine = try AetherEngine()
        #expect(engine.sessionReloadRefusal == .noActiveSession)
    }

    @Test("no session throws instead of returning like the plain reload does")
    func noSessionThrows() async throws {
        let engine = try AetherEngine()
        await #expect(throws: AetherEngineError.self) {
            try await engine.reloadAtCurrentPosition { $0.autoplay = false }
        }
        do {
            try await engine.reloadAtCurrentPosition { $0.autoplay = false }
            Issue.record("expected a refusal")
        } catch let error as AetherEngineError {
            guard case .sessionNotReloadable(let refusal) = error else {
                Issue.record("expected sessionNotReloadable, got \(error)")
                return
            }
            #expect(refusal == .noActiveSession)
        }
    }

    @Test("an identity change is refused before the session is even consulted")
    func identityChangeIsRefusedFirst() async throws {
        let engine = try AetherEngine()
        var seeded = LoadOptions()
        seeded.isLive = true
        engine.setLoadedOptionsForTesting(seeded)

        do {
            try await engine.reloadAtCurrentPosition { $0.isLive = false }
            Issue.record("expected a refusal")
        } catch let error as AetherEngineError {
            guard case .loadIdentityNotCorrectable(let fields) = error else {
                Issue.record("expected loadIdentityNotCorrectable, got \(error)")
                return
            }
            #expect(fields == ["isLive"])
        }
        // The refusal costs nothing: no teardown, and the session keeps the options it was on.
        #expect(engine.loadedOptions.isLive)
    }

    @Test("a refused correction does not install the options it refused")
    func refusedCorrectionDoesNotInstall() async throws {
        let engine = try AetherEngine()
        var seeded = LoadOptions()
        seeded.autoplay = true
        seeded.teletextPage = 150
        engine.setLoadedOptionsForTesting(seeded)

        // Refused for the session, not for the fields: the tuning change rides along and must not
        // survive a reload that never happened.
        try? await engine.reloadAtCurrentPosition {
            $0.autoplay = false
            $0.teletextPage = 888
        }
        #expect(engine.loadedOptions.autoplay)
        #expect(engine.loadedOptions.teletextPage == 150)
    }

    @Test("the closure is seeded with what the session runs on, not with a fresh struct")
    func closureSeesTheSessionsOptions() async throws {
        let engine = try AetherEngine()
        var seeded = LoadOptions()
        seeded.httpHeaders = ["Authorization": "Bearer stale"]
        seeded.matchContentEnabled = true
        engine.setLoadedOptionsForTesting(seeded)

        var seenHeader: String?
        var seenMatchContent: Bool?
        try? await engine.reloadAtCurrentPosition {
            seenHeader = $0.httpHeaders["Authorization"]
            seenMatchContent = $0.matchContentEnabled
        }
        #expect(seenHeader == "Bearer stale")
        #expect(seenMatchContent == true)
    }

    @Test("the correction is installed so internal reopens replay it")
    func correctionInstallsIntoTheSession() throws {
        let engine = try AetherEngine()
        var seeded = LoadOptions()
        seeded.httpHeaders = ["Authorization": "Bearer stale"]
        engine.setLoadedOptionsForTesting(seeded)

        var corrected = seeded
        corrected.httpHeaders["Authorization"] = "Bearer fresh"
        engine.applySessionOptionCorrection(corrected)
        #expect(engine.loadedOptions.httpHeaders["Authorization"] == "Bearer fresh")
    }
}
