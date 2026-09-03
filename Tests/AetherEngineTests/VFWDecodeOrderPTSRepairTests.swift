import Testing
import AetherLibavcodec
@testable import AetherEngine

// #407: a VFW-carried Matroska track supplies no PTS, so `+genpts` invents one out of decode order and
// every B/P pair reaches the renderer transposed. These pin the gate that decides which streams lose
// their invented PTS.
@Suite("VFWDecodeOrderPTSRepair gate")
struct VFWDecodeOrderPTSRepairTests {

    private func shape(
        tag: UInt32,
        delay: Int32,
        codec: AVCodecID = AV_CODEC_ID_VC1
    ) -> VFWDecodeOrderPTSRepair.StreamShape {
        .init(codecTag: tag, videoDelay: delay, codecID: codec)
    }

    /// The reported shape: WVC1 in Matroska, one picture of reorder delay.
    @Test("VC-1 VFW track in Matroska loses its generated PTS")
    func vc1VFWMatroska() {
        #expect(VFWDecodeOrderPTSRepair.suppressesGeneratedPTS(
            formatName: "matroska,webm",
            shape: shape(tag: 0x3143_5657, delay: 1)) == true)
    }

    /// A natively mapped Matroska track carries no codec tag and gets real PTS from the container, so
    /// there is nothing invented to drop.
    @Test("Natively mapped Matroska track (codec_tag 0) keeps its PTS")
    func nativeMatroskaTrack() {
        #expect(VFWDecodeOrderPTSRepair.suppressesGeneratedPTS(
            formatName: "matroska,webm",
            shape: shape(tag: 0, delay: 2, codec: AV_CODEC_ID_H264)) == false)
    }

    /// No reorder delay means decode order IS presentation order, so the invented axis is the right
    /// one and touching it would only cost.
    @Test("Zero video_delay keeps its PTS: nothing can transpose")
    func zeroVideoDelay() {
        #expect(VFWDecodeOrderPTSRepair.suppressesGeneratedPTS(
            formatName: "matroska,webm",
            shape: shape(tag: 0x3143_5657, delay: 0)) == false)
    }

    /// The equivalence behind the gate is established in `matroskadec` and nowhere else. AVI carries a
    /// FourCC on every track and would otherwise match.
    @Test("Same shape in a non-Matroska container is left alone")
    func nonMatroskaContainer() {
        for format in ["avi", "mov,mp4,m4a,3gp,3g2,mj2", "asf", "mpegts"] {
            #expect(VFWDecodeOrderPTSRepair.suppressesGeneratedPTS(
                formatName: format,
                shape: shape(tag: 0x3143_5657, delay: 1)) == false,
                "\(format) must not arm the repair")
        }
    }

    /// H.264 / HEVC / AV1 can stay on the native path, where packets reach the fMP4 muxer and a
    /// timestamp-less packet is refused outright. A bad picture beats no playback.
    @Test("Natively routable codecs keep their PTS even when VFW-carried")
    func nativelyRoutableCodecsExcluded() {
        for codec in [AV_CODEC_ID_H264, AV_CODEC_ID_HEVC, AV_CODEC_ID_AV1] {
            #expect(VFWDecodeOrderPTSRepair.suppressesGeneratedPTS(
                formatName: "matroska,webm",
                shape: shape(tag: 0x3143_5657, delay: 1, codec: codec)) == false,
                "\(codec) routes natively and must keep its PTS")
        }
    }

    /// The software-path long tail that shares VC-1's carriage.
    @Test("Other VFW-carried software-path codecs are repaired")
    func otherSoftwarePathCodecs() {
        for codec in [AV_CODEC_ID_WMV3, AV_CODEC_ID_MPEG4, AV_CODEC_ID_MSMPEG4V3] {
            #expect(VFWDecodeOrderPTSRepair.suppressesGeneratedPTS(
                formatName: "matroska,webm",
                shape: shape(tag: 0x3143_5657, delay: 1, codec: codec)) == true,
                "\(codec) takes the software path and should be repaired")
        }
    }

    /// libavformat registers both flavours under one comma-joined name, so the match is per element.
    @Test("Matroska name matching is per element, not substring")
    func matroskaNameMatching() {
        #expect(VFWDecodeOrderPTSRepair.isMatroska("matroska,webm") == true)
        #expect(VFWDecodeOrderPTSRepair.isMatroska("matroska") == true)
        #expect(VFWDecodeOrderPTSRepair.isMatroska("webm") == true)
        #expect(VFWDecodeOrderPTSRepair.isMatroska("avi") == false)
        #expect(VFWDecodeOrderPTSRepair.isMatroska("") == false)
    }
}
