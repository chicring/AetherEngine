import Foundation
import AetherLibavcodec
import AetherLibavformat
import AetherLibavutil

/// #407: a Matroska track written as `V_MS/VFW/FOURCC` carries no presentation timestamps at all.
/// `matroskadec` puts the block timecode on `pkt->dts` and leaves `pkt->pts` unset for such a track
/// (`if (track->ms_compat) pkt->dts = timecode; else pkt->pts = timecode;`), and that is the carriage
/// every VC-1 remux uses, because VC-1 has no native Matroska mapping.
///
/// The engine opens every source with `fflags=+genpts`, so libavformat fills the gap it finds. Its
/// reconstruction takes a following packet's DTS as this packet's PTS, which assumes decode order and
/// presentation order are the same sequence. On a stream with B pictures they are not, and what comes
/// out is a uniform `pts = dts + one frame` ladder: decode-order timestamps, monotonic and perfectly
/// even.
///
/// Nothing downstream survives that. libavcodec hands its pictures out in presentation order but each
/// one carries the timestamp of the packet it was decoded from, so a B picture wears the following P
/// picture's time and the P wears the B's. `SampleBufferRenderer` then sorts its reorder buffer by PTS
/// and puts the pictures back into decode order. Motion steps forward, back, forward, back for the
/// length of the title, at an even frame spacing, with nothing to count: no drop, no late frame, no
/// corrupted frame. Every instrument reads healthy and the pictures are in the wrong order.
///
/// Measured on `samples.ffmpeg.org/V-codecs/WVC1/Test_1440x576_WVC1_6Mbps.wmv` remuxed with a plain
/// `ffmpeg -c copy`, decoded ladder against picture type:
///
///     with +genpts    0.040 I   0.120 B   0.080 P   0.200 B   0.160 P     <- every B/P pair swapped
///     without         0.040 I   0.080 B   0.120 P   0.160 B   0.200 P
///
/// So the repair is to stop supplying the invented axis and let the decoder's own reorder own it.
/// Clearing PTS leaves `best_effort_timestamp` to place each picture, which is the second ladder.
///
/// The gate is an equivalence, not a guess. `matroskadec` sets `ms_compat` and `par->codec_tag` in one
/// block, both read out of the same VFW header, and no natively mapped Matroska track carries a codec
/// tag (measured: `WVC1` = 0x31435657 on the VFW track, 0 on H.264 and VP9 in the same container). On a
/// Matroska input `codec_tag != 0` is therefore exactly the carriage that withholds PTS, and any PTS
/// present on such a track was necessarily invented by `+genpts`. `video_delay > 0` narrows that to the
/// streams where inventing it can transpose anything at all.
///
/// Two deliberate exclusions:
///
/// - **Matroska only.** AVI carries a FourCC on every track and is DTS-only as well, but the
///   `ms_compat`/`codec_tag` equivalence is established in `matroskadec` and nowhere else, and a
///   VC-1 AVI has not been measured. A gate that is exact on one container beats a guess on two.
/// - **H.264 / HEVC / AV1 keep their PTS**, VFW-carried or not. Those are the codecs
///   `VideoRoutingPolicy` can route natively, which is the one path where packets reach the fMP4
///   muxer, and that muxer refuses a packet with no timestamp outright. A wrongly ordered picture is
///   a bad picture; a refused packet is no playback at all. Such a file is pathological in the first
///   place, and #409 already covers the reordering defect on the native path.
enum VFWDecodeOrderPTSRepair {

    /// The three facts about a video stream that decide the repair. Values only, so the decision is
    /// testable without FFmpeg.
    struct StreamShape: Equatable, Sendable {
        /// `AVCodecParameters.codec_tag`. Nonzero on a Matroska track exactly when it is VFW-carried.
        var codecTag: UInt32
        /// `AVCodecParameters.video_delay`: how many pictures the bitstream reorders by.
        var videoDelay: Int32
        /// `AVCodecParameters.codec_id`, to hold the natively routable codecs out (see above).
        var codecID: AVCodecID
    }

    /// Codecs `VideoRoutingPolicy` can keep on the native path, whose packets can therefore reach the
    /// fMP4 muxer. AV1 is here even though it routes by HW availability: the muxer is the risk, and it
    /// is reachable for AV1 on a device with a hardware decoder.
    static let nativelyRoutableCodecs: Set<AVCodecID> = [
        AV_CODEC_ID_H264, AV_CODEC_ID_HEVC, AV_CODEC_ID_AV1,
    ]

    /// Whether `+genpts` is inventing a decode-order axis for this stream, so its PTS has to go.
    static func suppressesGeneratedPTS(formatName: String, shape: StreamShape) -> Bool {
        guard isMatroska(formatName) else { return false }
        guard shape.codecTag != 0, shape.videoDelay > 0 else { return false }
        return !nativelyRoutableCodecs.contains(shape.codecID)
    }

    /// libavformat registers both Matroska flavours under one comma-joined demuxer name
    /// (`matroska,webm`), so the name is matched element by element rather than whole.
    static func isMatroska(_ formatName: String) -> Bool {
        formatName.split(separator: ",").contains { $0 == "matroska" || $0 == "webm" }
    }
}
