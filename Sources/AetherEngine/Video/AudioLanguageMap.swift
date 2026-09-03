import Foundation

/// The ISO 639-2/T code an fMP4 audio track's `mdhd` carries, resolved from the source container's tag.
///
/// It also names the master's `EXT-X-MEDIA:TYPE=AUDIO` rendition, which is the tag AVFoundation actually
/// reads on an HLS asset: an fMP4 whose mdhd says "deu" still reports `AVAssetTrack.languageCode == nil`
/// without it, and AVKit's audio menu reads "Not Specified" (AE#458). The mdhd is written because the
/// track IS that language for whoever reads it; the master is what moves the label.
///
/// ICU resolves ISO 639-1, ISO 639-2/T and BCP-47 subtags ("pt-BR" -> "por"), but NOT the twenty ISO 639-2/B
/// bibliographic codes, and Matroska writes exactly those ("ger", "fre", "cze"), so they are mapped first.
/// Everything else fails closed: a label ICU cannot resolve to a three-letter code writes no language at all,
/// which leaves the unlabelled-track behaviour untouched.
enum AudioLanguageMap {
    /// The twenty ISO 639-2 languages whose bibliographic code differs from the terminological one.
    /// None of these is a valid ISO 639-1 or 639-2/T code for a different language, so matching them
    /// first cannot shadow a real tag.
    private static let terminologicalByBibliographic: [String: String] = [
        "alb": "sqi", "arm": "hye", "baq": "eus", "bur": "mya", "chi": "zho",
        "cze": "ces", "dut": "nld", "fre": "fra", "geo": "kat", "ger": "deu",
        "gre": "ell", "ice": "isl", "mac": "mkd", "mao": "mri", "may": "msa",
        "per": "fas", "rum": "ron", "slo": "slk", "tib": "bod", "wel": "cym",
    ]

    static func iso639_2T(forSourceLanguage language: String?) -> String? {
        guard let raw = language?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !raw.isEmpty
        else { return nil }
        if let terminological = terminologicalByBibliographic[raw] { return terminological }
        // "und" resolves to itself; writing it is the same as writing nothing, and movenc's default
        // already is und.
        if let alpha3 = alpha3(of: raw) { return alpha3 }
        // ICU's language table has no alpha3 entry for the ISO 639-3 members it aliases to a
        // macrolanguage ("cmn", "arb", "pes", "swh", "uzn", "kmr"), so Mandarin tagged "cmn" lost its
        // LANGUAGE while "yue" and "nan", which CLDR does not alias, resolved (htrung14, AE#458).
        // Canonicalizing resolves the alias; running it only where the direct route came back empty
        // keeps every tag that resolves today on its current answer ("no" stays "nor", not "nob").
        //
        // Gated on a well-formed BCP-47 primary subtag: canonicalization also turns "English" into
        // "en" and "Japanese" into "jpn", and free text in a language field is a track NAME, not a
        // tag. Guessing at it is how a commentary track ends up labelled as a language.
        guard hasLanguageSubtagShape(raw) else { return nil }
        let canonical = Locale.canonicalLanguageIdentifier(from: raw)
        guard canonical != raw else { return nil }
        return alpha3(of: canonical)
    }

    private static func alpha3(of identifier: String) -> String? {
        guard let alpha3 = Locale.Language(identifier: identifier).languageCode?.identifier(.alpha3),
              alpha3.count == 3, alpha3 != "und"
        else { return nil }
        return alpha3
    }

    /// RFC 5646 2.2.1: a language subtag is 2 or 3 ASCII letters (4 is reserved, 5 to 8 registered,
    /// neither of which any container writes). Anything else is prose, not a tag.
    private static func hasLanguageSubtagShape(_ raw: String) -> Bool {
        let primary = raw.prefix { $0 != "-" && $0 != "_" }
        return (2...3).contains(primary.count) && primary.allSatisfy { $0.isASCII && $0.isLetter }
    }
}
