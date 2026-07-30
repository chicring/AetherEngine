import CoreGraphics
import Foundation
import Vision

/// Phase D: on-device recognition of bitmap subtitle images (PGS / DVB / DVD) into plain-text
/// cues for the native WebVTT rendition (PiP / AirPlay / external display). Lossy by design;
/// a failed or empty recognition drops that cue and the rendition just misses the line, the
/// fullscreen overlay keeps the pixel-accurate bitmaps.
enum SubtitleImageOCR {

    /// Vision bounding boxes are normalized with a bottom-left origin; reading order is
    /// descending midY. Blank fragments are dropped; nil when nothing readable remains.
    nonisolated static func assembleLines(_ observations: [(text: String, midY: CGFloat)]) -> String? {
        let lines = observations
            .map { (text: $0.text.trimmingCharacters(in: .whitespacesAndNewlines), midY: $0.midY) }
            .filter { !$0.text.isEmpty }
            .sorted { $0.midY > $1.midY }
            .map(\.text)
        guard !lines.isEmpty else { return nil }
        return lines.joined(separator: "\n")
    }

    /// Track tags are ISO 639-1/2 ("ger"), Vision wants BCP-47 primary codes ("de"). The engine's
    /// synonym classes resolve the bibliographic 639-2/B forms Foundation cannot ("ger", "fre").
    nonisolated static func recognitionLanguage(forTrackLanguage tag: String?) -> String? {
        guard let raw = tag?.trimmingCharacters(in: .whitespaces).lowercased(), !raw.isEmpty else { return nil }
        if let set = AetherEngine.languageSynonyms.first(where: { $0.contains(raw) }),
           let twoLetter = set.first(where: { $0.count == 2 }) {
            return twoLetter
        }
        return Locale.LanguageCode(raw).identifier(.alpha2) ?? raw
    }

    /// Subtitle bitmaps are white glyphs with an outline on transparency; an opaque black
    /// backing gives Vision stable contrast.
    nonisolated static func flattenedOntoBlack(_ image: CGImage) -> CGImage? {
        let w = image.width, h = image.height
        guard w > 0, h > 0, let ctx = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    /// One synchronous Vision pass; callers serialize (single worker task / single fill task).
    nonisolated static func recognizeText(in image: CGImage, language: String?) -> String? {
        // Vision rejects images ≤ 2 px in either dimension; frame-by-frame effects tracks emit
        // streams of such fragments. Skip the flatten + perform and feed the breaker directly.
        guard image.width > 2, image.height > 2 else {
            registerFailure("image too small (\(image.width)x\(image.height))")
            return nil
        }
        guard let flat = flattenedOntoBlack(image) else { return nil }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        if let language,
           let supported = try? request.supportedRecognitionLanguages(),
           let match = supported.first(where: {
               let s = $0.lowercased()
               return s == language || s.hasPrefix(language + "-")
           }) {
            request.recognitionLanguages = [match]
        }
        do {
            try VNImageRequestHandler(cgImage: flat, options: [:]).perform([request])
        } catch {
            registerFailure("Vision perform failed: \(error)")
            return nil
        }
        noteSuccess()
        let observations = (request.results ?? []).compactMap { obs -> (String, CGFloat)? in
            guard let top = obs.topCandidates(1).first else { return nil }
            return (top.string, obs.boundingBox.midY)
        }
        return assembleLines(observations)
    }

    /// Recognize a batch of CLOSED cues and append the text results to a native store. Image
    /// cues become text cues at the same times; text cues pass through (mixed external files).
    /// Runs inside a detached worker/fill task, never on the MainActor.
    nonisolated static func appendRecognized(cues: [SubtitleCue], language trackLanguage: String?,
                                             to store: NativeSubtitleCueStore) {
        let language = recognitionLanguage(forTrackLanguage: trackLanguage)
        var out: [SubtitleCue] = []
        for cue in cues {
            if Task.isCancelled || breakerTripped { break }
            switch cue.body {
            case .image(let image):
                if let text = recognizeText(in: image.cgImage, language: language) {
                    out.append(cue.with(body: .text(text)))
                }
            case .text, .richText:
                out.append(cue)
            }
        }
        if !out.isEmpty { store.appendCues(out) }
    }

    // MARK: - Recognition circuit breaker

    /// Consecutive-failure breaker: a frame-by-frame effects PGS track feeds ~24 unrecognizable
    /// fragments per second, and without a trip every one still pays flatten + Vision (or the
    /// tiny-image reject) forever — a full core of standing CPU for a rendition that will never
    /// hold text. Any successful Vision pass (text found or not) resets the count; a trip stays
    /// until the next `resetBreaker()` (worker re-arm on track select / new session).
    static let breakerConsecutiveFailureLimit = 12

    private static let failureLock = NSLock()
    nonisolated(unsafe) private static var loggedFailure = false
    nonisolated(unsafe) private static var consecutiveFailures = 0
    nonisolated(unsafe) private static var tripped = false

    /// True once recognition has failed `breakerConsecutiveFailureLimit` times in a row.
    /// The OCR worker polls this and disarms itself.
    nonisolated static var breakerTripped: Bool {
        failureLock.lock(); defer { failureLock.unlock() }
        return tripped
    }

    /// New arm / new session: recognition gets a fresh chance (different track, different bitmaps).
    nonisolated static func resetBreaker() {
        failureLock.lock(); defer { failureLock.unlock() }
        consecutiveFailures = 0
        tripped = false
        loggedFailure = false
    }

    private nonisolated static func noteSuccess() {
        failureLock.lock(); defer { failureLock.unlock() }
        consecutiveFailures = 0
    }

    private nonisolated static func registerFailure(_ reason: String) {
        failureLock.lock()
        consecutiveFailures += 1
        let justTripped = !tripped && consecutiveFailures >= breakerConsecutiveFailureLimit
        if justTripped { tripped = true }
        let firstLog = !loggedFailure
        loggedFailure = true
        failureLock.unlock()
        if firstLog { EngineLog.emit("[SubtitleOCR] degraded: \(reason)", category: .engine) }
        if justTripped {
            EngineLog.emit("[SubtitleOCR] circuit breaker tripped after \(breakerConsecutiveFailureLimit) consecutive failures", category: .engine)
        }
    }
}
