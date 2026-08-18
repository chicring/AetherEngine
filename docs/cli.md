# aetherctl

A standalone macOS CLI shipped alongside the library for repro work without going through TestFlight + Apple TV. Most subcommands operate on a media source URL (`file://` or `http(s)://`); `live`, `dvr`, `hlsfixture`, and `hlslive` run against built-in synthetic fixtures.

```bash
swift run aetherctl probe <url>          # dump container + streams + duration, exit
swift run aetherctl serve <url>          # park the engine's loopback HLS-fMP4 server
swift run aetherctl validate <url>       # serve + run mediastreamvalidator, exit
swift run aetherctl segverify <url>      # SW-decode each loopback segment in isolation; report independence (#92)
swift run aetherctl swdecode <url>       # open SoftwareVideoDecoder, decode N packets, report
swift run aetherctl play <url>           # full load+play session smoke test: 1 Hz telemetry, cue log, host-call mimicry
swift run aetherctl dovitest <url>       # convert a DV Profile 7 stream to 8.1, dump for dovi_tool
swift run aetherctl pktdump <url>        # dump raw demuxer packet timing (dts/pts/keyframe) per open profile
swift run aetherctl dualsubs <file> ...  # dual subtitle-track render probe (--primary / --secondary stream index)
swift run aetherctl extract <url>        # FrameExtractor still-image extraction + leak testing
swift run aetherctl audio [--seconds N] <url>   # audio-only pipeline smoke test (default 10 s)
swift run aetherctl audiotap <url>       # decode the PCM audio tap headless, write mono 48 kHz WAV (#95)
swift run aetherctl bgaudio <url>        # SW-path background-audio keepalive probe (iOS background behavior)
swift run aetherctl customio <path>      # exercise the custom IOReader path end-to-end
swift run aetherctl disc-inspect <path>  # walk a local DVD / Blu-ray ISO: titles, chapters, recognition stages
swift run aetherctl live                 # live MPEG-TS session against the built-in fixture
swift run aetherctl dvr                  # DVR rewind matrix across native + SW paths
swift run aetherctl hlsfixture <ts>      # local HLS live fixture with fault knobs + ingest self-test
swift run aetherctl seektest <url>       # rapid-seek burst repro + clock-bounce / isSeeking probe
swift run aetherctl hlslive              # SSAI live-direct-play repro against a synthetic ad-pod feed
swift run aetherctl smbtest <smb-url>    # play a file off an SMB2/3 share via the AetherEngineSMB reader
swift run aetherctl <url>                # alias for serve (backwards compat)
```

Twenty-one subcommands plus the bare-URL `serve` alias.

## probe

Opens the demuxer, prints the codec / resolution / frame rate of the video track, the audio track list (codec, channels, language, Atmos flag), the subtitle track list, the parsed container metadata (`MediaMetadata`: title / artist / album / albumArtist + embedded cover art presence), then exits. No HLS server is started.

## serve

The original behavior. The CLI prints the loopback URL and parks until Ctrl-C; from another terminal you can:

```bash
curl -i  http://127.0.0.1:<port>/master.m3u8
curl -o  /tmp/init.mp4   http://127.0.0.1:<port>/init.mp4
mediastreamvalidator http://127.0.0.1:<port>/master.m3u8
mp4dump --verbosity 1 /tmp/init.mp4
ffprobe -v debug /tmp/seg0.mp4
open 'http://127.0.0.1:<port>/master.m3u8'   # macOS QuickTime
```

`--no-dv` forces the SDR / HDR10 route even for a Dolby Vision source (compare the two playlists).

`--native-subs <index>` turns on the native WebVTT subtitle renditions (the `LoadOptions.prepareNativeSubtitles` path a full session uses): the engine calls `requestNativeSubtitleTrack()` before `start()`, then `attachAllNativeSubtitleStores()` after start. Every non-bitmap text track is served as a language-tagged `EXT-X-MEDIA:TYPE=SUBTITLES` rendition (`DEFAULT=NO,AUTOSELECT=NO`) in the master playlist, backed by a per-track `subs_N.m3u8` WebVTT media playlist. (An earlier design muxed `mov_text`/tx3g traks into the fMP4; in-band timed text is not HLS-conformant and AVPlayer rejected it, so the WebVTT rendition replaced it, see [formats.md › Native subtitle renditions](formats.md#native-subtitle-renditions-webvtt-for-pip-airplay-and-external-display).) The `<index>` value is legacy and now ignored, kept only for CLI compatibility: every non-bitmap track is always declared, and actual track selection happens via the host API in a full session, not from this flag. `curl` the `master.m3u8` (or open it in QuickTime) to verify the `SUBTITLES` group + `subs_N.m3u8` endpoints enumerate every language as a legible `AVMediaSelection` group. Omit the flag to reproduce the default behavior (no renditions, output identical to before).

`--throttle-kbps N` is a TEST-ONLY slow-CDN simulation: it caps source-IO delivery to N kbit/s. Set it below the stream bitrate to starve the producer below real-time and provoke AVPlayer rebuffers (for example the #92 open-GOP repro). Also available on `seektest` and `play`.

`--start-position S` starts the session at S seconds, the resume anchor a host passes to `load(url:startPosition:)`. Also available on `play`.

## validate

`serve` plus an inline `xcrun mediastreamvalidator` run against the loopback manifest, with the report printed and the engine torn down on completion.

## swdecode

Opens `SoftwareVideoDecoder` for the source's video stream, feeds up to N packets (default 100, override with `--frames N`), and reports counters plus first-frame metadata (pixel format, dimensions). Tests the SW-pipeline decode path end-to-end without needing a render layer. Useful for legacy codecs (MPEG-4 Part 2, MPEG-2, VC-1) and AV1 / VP9 on platforms where the native AVPlayer path doesn't accept them. Verdict distinguishes three failure modes:

- decoder open failed (FFmpegBuild gate or malformed extradata)
- decoder opened but no frames produced (pixel-format conversion, no IDR in window)
- SW decode end-to-end healthy (if real playback still hangs, the failure is downstream in `SoftwarePlaybackHost` frame-enqueue, display-layer attach, or audio-clock sync)

Backed by the public `AetherEngine.swDecodeProbe(url:maxPackets:options:)` static API returning `SoftwareDecodeProbeResult`. Hosts can use the same probe in their own diagnostic overlays.

## play

Runs a full `load()` + `play()` session exactly like a host app and prints 1 Hz transport telemetry (state, phase, currentTime, sourceTime, buffered frontier, duration) plus the network half of the same `liveTelemetry` snapshot a host reads (`net` throughput, `rx` reader lifetime pull, `ahead` fetched-but-unconsumed window, `cushion` decoded video past the clock, `fwd` native forward buffer, `drop` / `delay`). Fields absent on the running path are omitted, so a software session reads `cushion` where a native one reads `fwd`. Note that `drop` climbs steadily in a CLI run: nothing binds a render surface, and the renderer drops what it cannot present. Where `swdecode` proves the decoder, `play` proves the transport: it fails loud on the two silent failure modes of a session that "loads fine" but never actually plays (#107): exit 2 when the clock does not advance, exit 3 when a selected subtitle track produces no cues.

```bash
swift run aetherctl play <url>                                  # VOD load, 30 s telemetry
swift run aetherctl play --seconds 60 <url>                     # longer window
swift run aetherctl play --live --dvr-window 1800 <url>         # live path with a DVR ring
swift run aetherctl play --subs teletext <url>                  # activate the first matching subtitle track, log every cue + trim
swift run aetherctl play --host-calls reloadlive,play,extractor,setrate <url>   # mimic a host's post-load call sequence
swift run aetherctl play --live --dvr-window 1800 --audio-stats <url>           # decoded-PCM continuity + per-second audio lead
swift run aetherctl play --live --native-hls <master.m3u8>      # nativeRemoteHLS bypass (carriage watchdog + #293 probe)
swift run aetherctl play --sidecar de=/tmp/de.srt --subs de <master.m3u8>   # declare a sidecar at load (#316)
```

`--sidecar <lang>=<path-or-url>[,<lang>=<path>...]` fills `LoadOptions.externalSubtitles`, the load-time
declaration a host makes. On a remote `m3u8` this is what makes the engine stand up its rewritten master
(#316), so it is the way to see the whole chain from the CLI: the served `master.m3u8` body is logged, the
engine reports how many renditions it injected, and selecting the track (`--subs <lang>` matches the
external track by language) shows the `subs_N.m3u8` and `subs_N_0.vtt` fetches arriving. The end-of-run
`subtitle tracks` line is the settled list a host's picker would show, with `*` marking external ids; note
that `cues=0` and "no cues arrived" are CORRECT there, because AVPlayer renders a rendition itself and the
overlay pipeline stays empty (same as AE#154).

`--subs <codec-or-lang>` matches against the track's libavcodec name or language and logs every overlay cue and cue trim as it lands. `--host-calls` replays host post-load behavior against the fresh session: `play`, `extractor` (`makeFrameExtractor`), `setrate` (`setRate(1.0)`), `reloadlive` (reload the URL on the live path when the probe flags it live, the AetherPlayer Open URL flow), `seekback` (rewind 20 s into the DVR window at t=15, return to the live edge at t=30), and `overlapseek` (the #292 seek-window drills below); this is how the pre-arming `setRate` wedge was isolated.

`--seek-every N` seeks once every N ticks past tick 10, walking `--seek-pattern <abs,abs,...>` if one is given (a short backward hop otherwise), and `--seek-count K` stops after K seeks so a run can be a BURST and then play. Both halves are needed for anything about what a seek sequence leaves behind: the burst puts the store in the state under test, and only the playing half shows what the overlay carries through it. That pairing is what made AE#362's second mechanism reproducible (a hole between a restarted pump and the island the previous run left ahead of it, decoded across and then never re-read).

`--host-calls overlapseek` (pair it with `--sw`) runs three drills at t=8, each making a transport call while a seek's demuxer reposition is still in flight, which is the window #254 opened by moving that reposition off the main actor: **A** a second same-target seek (the #292 report: a scrub arriving as two seeks, the second superseding the first), **B** a `pause()`, **C** a `play()` from paused. `seektest` cannot reach any of this because it awaits every seek, so its bursts are strictly serial. Each drill heals the session with pause + play first, so a defect one drill provokes is not inherited by the next, and each reports its own PASS / FAIL / INCONCLUSIVE (`inWindow=NO` means the call arrived after the landing and the run proves nothing). Exit 4 when any drill fails, 5 when any is inconclusive. Before the #292 fix, A and C land the clock at `rate=0.0` while the engine reports `.playing` and B silently keeps playing through the pause.

`--live-ingest` loads the URL through `HLSLiveIngestReader` as a custom source, which is the shape a host uses for a live channel it ingests and re-serves itself (Sodalite's direct live path). Pair it with `--live`. It reaches the reader DIRECTLY, which is what a repro of the reader itself needs; since AE#363 plain `--live` also ends up there, but by way of the engine's own route (the raw live path detects the playlist and hands it to the ingest), so use `--live-ingest` when the reader is the subject and plain `--live` when the routing is. `hlslive` only serves local `.ts` files. AE#359 (the master's SUBTITLES renditions were parsed away) survived precisely because this path had no harness; `--live-ingest --subs <lang>` reproduces and verifies it in 40 s against a public broadcaster URL.

`--fast-zap` sets `LoadOptions.liveJoinProfile = .fastZap` for the load. `live` has carried the flag for its own raw-TS fixture since AE#195, but that fixture has no upstream playlist, and the served `#EXT-X-TARGETDURATION` is floored by the UPSTREAM's observed arrival cadence (`LiveCadencePolicy`), which is what sizes the holdback the first serve waits for. So fastZap against an origin of one's own, the shape a downstream player actually ships, could not be driven from here at all. Measured on the same 1 s-GOP seed, `--preroll 0 --realtime`: raw TS with no playlist serves at 1.325 s on TARGETDURATION 1 (holdback 3 s, full cushion), the same content behind an `hlsfixture` origin cutting 2 s segments serves on TARGETDURATION **2** (holdback 6 s) although the engine re-cut it at 1 s. Pair it with `--live`, and read the first-serve line (AE#374) rather than a first-frame stopwatch.

`--header "Name: Value"` (repeatable) fills `LoadOptions.httpHeaders` and, on `--live-ingest`, the reader's own fetches. Origins that enforce a per-request `User-Agent` / `Referer` / `Authorization` (tokenized IPTV, STB profiles) could not be driven from the CLI at all before AE#363; pair it with `hlsfixture --require-header` below to have both ends of the contract in one run.

`--native-hls` sets `LoadOptions.nativeRemoteHLS`, the path a host uses for a live channel AVPlayer can play itself. It is the only way to exercise the #168 carriage watchdog, the #293 carriage probe and the AE#363 origin-refusal reroute from the CLI (`hlslive` loads the ingest reader directly and never mounts natively). Pair it with `--live`; without that the m3u8 takes the raw live path, which since AE#363 routes it onto the ingest instead of mounting AVPlayer at all.

`--switch-audio <index>[@ms]` replays a host applying a viewer's language preference just after playback starts (default +20 ms, the #337 field case): the engine rebuilds the session with the new stream at `resumeAt = 0`, which is the only shape where the rebuilt session's video renderer can fill before the newly selected stream's first packet arrives. Pick a stream whose first packet sits late in the mux and the run before the fix reads `state=playing cur=0.00` for its whole length with a first frame on screen; the end-of-run verdict names it. `--audio-stats` alongside it re-installs the tap after the switch, because the tap is bound to the software host the switch replaces and would otherwise report silence for a session that is playing fine. Build a fixture with a late track by offsetting one input: `ffmpeg -f lavfi -i testsrc2=size=1280x720:rate=30:duration=40 -f lavfi -i sine=frequency=440:duration=40 -itsoffset 12 -f lavfi -i sine=frequency=660:duration=28 -map 0:v -map 1:a -map 2:a -c:v libx264 -c:a libopus late-audio.mkv`.

`--teletext-page N` sets `LoadOptions.teletextPage` for the load, and `--switch-teletext-page <page|auto>[@ms]` changes it on a channel that is already playing (default +20 s, deliberately long: the switch has to land after `--subs` has a teletext track showing, else the run measures the load option it could already measure). The engine states what the change reached, `re-decoding N channel(s)` or `no active teletext track to re-decode`, so a page that does nothing is distinguishable from a page that never arrived. Real teletext needs a broadcast transport stream; there is no way to synthesise one with ffmpeg, so the CLI check covers the wiring and the gate, and the decode itself is confirmed against a live DVB channel (#364).

`--frame-times` installs the #311 software frame-time observer BEFORE `load()` (the documented usage: the engine re-arms each new host with it) and reads `softwarePresentationTimebase`. Per tick it appends `ft` (frames reported since the last tick), `ftLast` (newest reported presentation time), `ftGen` (renderer flush generation, which a seek moves) and `ooo`, the count of reports that arrived out of presentation order. `ooo` is the API's own claim under test: these are reported past the reorder buffer, so it must stay 0. `tb` is the timebase read at the same instant, and its closeness to `ftLast` is the point, both are on the source axis with nothing to convert between them.

`--sequential-origin` declares `LoadOptions.sequentialOrigin`, the IPTV timeshift / catch-up shape whose `206` answers are fabricated (#346): one long-lived unranged GET, no ranged probes, no tail read, so **seeking is unavailable** in the run. On VOD it needs `--declared-duration S`, which fills `LoadOptions.declaredDurationSeconds`, because the estimate that the tail read would have produced is gone with the tail read.

`--start-position S` starts at a resume anchor, the same one `serve` takes. `--sw` forces the software path for a source that would route native, which is how a native-only fixture exercises the SW pipeline.

`--malloc-census` turns on the large-allocation census (`AetherEngine.setLargeAllocationCensusEnabled`) for the run, for tracing a footprint that grows where the segment budget says it should not. Besides the 30 s sample it arms a jump trigger, which exists because the 30 s memprobe cannot catch a failure that completes inside one sample (every kill on #220 was that shape): a counter polled at `--census-hz N` runs the zone walk once it climbs `--census-threshold-mb N` above its running high-water. Both flags are inert without `--malloc-census`.

`--audio-stats` installs the engine audio tap and watches the decoded PCM itself: an `AGAP` line for every source-PTS discontinuity > 2 ms between consecutive buffers, and per-second `alead` (last decoded audio PTS minus the synchronizer clock) plus `abufs` (buffers delivered) appended to the telemetry. `alead` is the audio renderer's safety margin: on the SW live path the look-ahead pump holds it near `AudioLookaheadPolicy.targetLeadSeconds`; a collapse toward zero means the source or the feeder cannot keep real time (this is how the #107 audio-chopping report was diagnosed).

## segverify

Fetches `init.mp4` and then each media segment in turn from the loopback server and SW-decodes each segment **in isolation** (a fresh decoder per segment, no carried reference frames), reporting how many are independently decodable. A segment that yields `framesDecoded == 0` is not self-contained: its first sample is not an IRAP, so it depends on a predecessor, which is the open-GOP / B-frame boundary defect (#92). `--from N` / `--count K` bound the range (default 0 / 12), `--no-dv` forces the SDR route, `--dump <dir>` writes each fetched segment for offline inspection. Exit 0 when every tested segment is independent, 2 when any is not. This is the ground-truth verifier the #92 fix was validated against (ffmpeg's `hls` muxer scores every segment independent).

## dovitest

Runs the Dolby Vision Profile 7 to 8.1 converter over every video packet of the source and writes the converted elementary stream (Annex B) to `/tmp/aetherctl-dovitest.hevc`, reporting packets processed, conversions, and failures. Lets you confirm the in-engine `DoviRpuConverter` (libdovi) output matches the `dovi_tool -m 2` ground truth offline, without a DV panel:

```bash
swift run aetherctl dovitest <p7-source>
dovi_tool extract-rpu -i /tmp/aetherctl-dovitest.hevc -o out.rpu
dovi_tool info -i out.rpu -f 0   # expect dovi_profile 8, disable_residual_flag true
```

## pktdump

Opens the demuxer under a selectable open profile, optionally seeks, and dumps raw video packet timing exactly as the demuxer delivers it (before any producer-side dts repair and before muxing): per-packet dts / pts / duration / keyframe flag samples, NOPTS and non-monotonic dts counts, and dts-delta / duration histograms. Also prints the resolved stream fields that `find_stream_info` fills (`avg_frame_rate`, `codecpar.video_delay`).

```bash
swift run aetherctl pktdump --at 660 --count 300 --profile playback        <url>
swift run aetherctl pktdump --at 660 --count 300 --profile restartReopen   <url>
swift run aetherctl pktdump --at 660 --count 300 --profile stillExtraction <url>
```

`--profile` defaults to `playback`; `stillExtraction` is the third open profile, the one the `FrameExtractor` uses (a short-range AVIO with its own thread count), for comparing what a still-extraction open resolves against what playback resolves.

The profile differential is the diagnostic: a `video_delay=0` plus NOPTS or non-monotonic dts under one profile while the other is clean means that profile's open path cannot reconstruct decode-order dts for B-frame content (the #93 post-recovery judder root cause). Backed by the public `PacketTimingProbe.run(url:seekSeconds:packetCount:profileName:)`.

## extract

Opens a `FrameExtractor` against the source and pulls a still frame. Thumbnail mode (default) snaps to the nearest keyframe and downscales to `--width` (default 320); `--snapshot` decodes frame-accurately at full resolution. `--at <sec>` sets the seek position (default 60.0). The first frame is written to `/tmp/aetherctl-extract-<mode>.png`. `--loops N` repeats the extraction across eight cycling positions, which pairs with `leaks --atExit` to validate the decode-context teardown is clean:

```bash
swift run aetherctl extract --at 612 --snapshot <url>          # frame-accurate still
swift run aetherctl extract --width 480 <url>                  # keyframe thumbnail
leaks --atExit -- .build/debug/aetherctl extract --loops 8 <url>   # leak sweep
```

## audio

Plays a source through the audio-only pipeline (default ten seconds, `--seconds N` to override) and reports which host took it (bare AVPlayer vs the FFmpeg renderer path), exercising the same dispatch a music host sees.

## audiotap

    aetherctl audiotap [--duration S] [--out PATH.wav] [--remote] <url>

Brings up the loopback session headless, decodes the audio tap (#95) as fast as segments are produced, writes mono Float32 48 kHz WAV (default `/tmp/audiotap.wav`), and prints buffer count, PCM seconds, discontinuity count, and the covered `sourceTime` span. A clean run reports exactly one discontinuity (the install itself). `--remote` drives the remote-HLS delivery path instead (direct AVPlayer ingest of an HLS url, no loopback): rendition/variant resolution, segment fetch + decrypt, playhead-follow decode. Verification tool for the PCM audio tap across the stream-copy and bridge audio paths.

## bgaudio

Verifies SW-path background audio (iOS keepalive) headless on macOS, where the `UIApplication` background lifecycle that normally drives it does not exist. Loads a software-routed source through the full engine, plays a foreground baseline, toggles the SW host into background-audio-only (`--fg N` foreground seconds, `--bg N` background seconds; defaults 3 / 6), then returns to foreground. Reports per-tick the audio clock, the SW video-frame count, and the process memory footprint, and a verdict. A healthy run shows the clock advancing through the background phase (audio alive), the video-frame count flat (video dropped), the footprint roughly flat (the loop paces on the audio renderer rather than buffering the rest of the file), and the video-frame count rising again on foreground return (resync at the next keyframe). The flag and counters are exposed through DEBUG-only engine hooks, so this command is unavailable in a Release build. Generate a quick software-path clip with `ffmpeg -f lavfi -i testsrc2 -f lavfi -i sine -c:v libvpx-vp9 -c:a aac -shortest clip.mkv`.

## customio

Wraps a local file in a custom `IOReader` and plays it through `load(source:)`. `--memory` reads via `DataIOReader`, `--forward-only` drops the seek capability, `--audio-only` routes through the audio-only pipeline, and `--reload` / `--switch-audio` / `--select-subs` / `--extract` exercise the optional capabilities (background reload, audio-track switch, embedded subtitles, scrub preview) end-to-end. `--audio-index N` names the audio stream at LOAD and prints what it asked for next to what it got. Pair it with `--forward-only` for the one question a live host has to answer: `selectAudioTrack` refuses such a source (rebuilding a drained FIFO), so naming the stream at load is the only way onto another track, and this is where that was measured rather than assumed (Sodalite#64).

## disc-inspect

Walks a local DVD-Video or Blu-ray ISO at the filesystem layer (FFmpeg-free) and reports what `DiscReader.wrap` makes of it: the recognition verdict and the stages it went through (ISO9660 / UDF signatures, BDMV / VIDEO_TS contents, resolved extents), so a disc that fails to play is debuggable instead of surfacing a bare `INVALIDDATA`. It also prints the full selectable-title list with each title's duration and chapter offsets (the same titles + chapters the engine exposes via `discTitles` / `discChapters`). Exit 0 when the image is recognized as playable, else 1. `--dump` adds the verbose UDF volume structure under the `.demux` log.

## dualsubs

Activates two subtitle tracks simultaneously on one source (primary + secondary) and prints both cue lists, exercising the dual / bilingual subtitle path. `--primary <streamIndex> --secondary <streamIndex>` select the tracks; `--seek <seconds>` jumps first so you can confirm both channels re-resolve after a seek.

## live

Runs a live MPEG-TS session against a built-in fixture that serves an endless broadcast by looping a seed `.ts` with rewritten timestamps. Flags simulate the failure modes the live path hardens against: `--drop-after N` (mid-stream connection drop + reconnect), `--discontinuity-at N` (program-boundary PTS / PCR jump), `--realtime` (1x wall-clock pacing), `--preroll N` (backlog seconds the paced fixture bursts before 1x pacing; default 30, `0` models a strict-realtime origin with no backlog), `--fast-zap` (loads with `LoadOptions.liveJoinProfile = .fastZap`; the first serve prefers the full holdback but is bounded after two finalized segments plus a 0.5...2.0 s observed-segment grace), `--dvr-window N` (timeshift), `--measure-rss` (sliding-window retention), `--reload-test` (live rejoin end to end, including the full-backlog replay shape some origins serve on reconnect). `--seed <ts>` overrides the seed clip, `--sw` forces the software live path, `--report-cache-bytes` tracks on-disk DVR footprint, `--serve-only` parks the fixture without attaching an engine (raw `curl` / `ffprobe` inspection), `--rewind-test` runs the DVR rewind-and-return matrix variant, and `--gen-highbitrate-seed` generates a ~22 Mbps 1080p H.264 MPEG-TS seed (for RSS-retention measurement) then exits. `--sliding` is still accepted and does nothing: the sliding window is unconditional for live sessions now, and the flag stays only so an older script does not fail on it.

## dvr

Runs the rewind matrix across the native and SW paths (`--path native|sw|both`). `--seconds N` and `--dvr-window N` size the run.

## hlsfixture

Slices a local `.ts` into a sliding live HLS playlist and serves it over loopback, with fault knobs (`--master` indirection, `--codecs`, `--resolution`, `--discontinuity-at`, `--slow-refresh`, `--drop-segment`, `--encrypted`, `--fmp4`, `--port`, `--segment-seconds`) and a `--self-test` mode that runs `HLSLiveIngestReader` against it end to end. Every request is logged as one `[HLSFixture] REQ <path>` line, so what a load actually costs the origin is countable rather than arguable.

`--segments-dir <dir>` serves pre-cut segments (`ffmpeg -i in.ts -c copy -f hls -hls_time 4 -hls_flags independent_segments -hls_segment_filename seg%d.ts out.m3u8`) instead of byte slices, sorted numerically. Byte slices start mid-GOP, which is fine for "did it route" and useless for "did it play": the run rebuffers forever because nothing decodes. Use the directory whenever the question is playthrough.

### The header-enforcing origin (AE#363)

A tokenized IPTV origin refuses anything that arrives without its per-request header, which is a shape none of the fixtures could produce, so neither live client could be driven against one:

```bash
# portal on 8099 answers /entry.m3u8 with a 302 to the "CDN edge" on 8100, both enforcing the header
aetherctl hlsfixture --segments-dir ./segs --master --codecs "avc1.4d401f,mp4a.40.2" \
  --resolution 1280x720 --require-header "User-Agent: Mozilla/5.0 (QtEmbedded; TestSTB)" \
  --redirect-entry --redirect-port 8100 --port 8099
aetherctl play --live --header "User-Agent: Mozilla/5.0 (QtEmbedded; TestSTB)" \
  --seconds 60 http://127.0.0.1:8099/entry.m3u8
```

The REQ log then carries the verdict per request (`auth=ok` / `auth=MISSING -> 403`), which is what makes "who lost the header, and on which hop" a measurement. Knobs: `--require-header "Name: Value"`, `--deny-status N` (401 and 403 reach the engine as different `NSURLError` codes), `--deny-segments-only` (refuse after readyToPlay rather than at the master), `--deny-user-agent S` (refuse `AppleCoreMedia` and serve everyone else, the one origin shape that tells the AVPlayer bypass and the engine's own ingest fetcher apart), `--redirect-entry` / `--redirect-host` / `--redirect-port` (portal-to-edge 302, cross-origin by host name and port while staying on loopback), `--media-origin H:P` (master's variants point at a second origin absolutely).

Measured with it before AE#363 was written, and worth knowing before suspecting the engine: `LoadOptions.httpHeaders` survive BOTH shapes on the AVPlayer bypass on macOS, the cross-origin 302 and the absolutely referenced second origin. Every request arrived with the header and the session played through.

`--codecs` / `--resolution` write `CODECS=` / `RESOLUTION=` onto both `EXT-X-STREAM-INF` lines. Without them AVFoundation reports no `videoAttributes` for the variants, so everything that reads master evidence (the #168 watchdog, the #293 probe gate) sees a master advertising no video at all and the fixture quietly stops carrying the case under test.

Note that the slicing is byte-based, not keyframe-aligned, so segments start mid-GOP and the decoder logs parameter-set errors on the rerouted ingest. That is fine for routing and plumbing questions; for a run that has to *play*, produce real segments with `ffmpeg -f hls` and serve those instead.

## seektest

Drives a real AVPlayer (native loopback-HLS path) through a burst of rapid seeks and reports the producer-restart coalescing behavior, the longest "wedge" (state `.playing` but the clock frozen), and final settle accuracy (AetherEngine#35). A concurrent sampler probe also checks the seek clock-bounce / `isSeeking` signal (AetherEngine#37 / #38): a single backward seek must not bounce the clock back through the pre-seek position, and `isSeeking` must span the real landing. The run ends with a `#38 SEEK EVENT LEDGER`: every `.began` must reach a terminal event (an unpaired one is a stranded in-flight window), and `.stalled` seeks are listed with any late `.landed` that followed them. `--seeks N`, `--gap-ms N`, `--settle N` shape the burst; needs `> 30 s` of seekable VOD. `--throttle-kbps N` caps source-IO delivery to simulate a slow CDN and force rebuffers during the burst (see `serve`).

## hlslive

Replays a synthetic SSAI ad-pod feed through the live-direct-play path to repro the FAST-channel ad-break handling (program-switch detection, muxer rotation with versioned `#EXT-X-MAP`, audio re-anchor, no-cut watchdog). `--segments a.ts,b.ts,c.ts` is required: a comma-separated list of real `.ts` segment files served in order (content / ad / content) without timestamp rewriting. `--seconds N` (default 40) and `--segment-seconds N` (default 5) size the run; `--disc i,j` marks which segment indices carry a leading `#EXT-X-DISCONTINUITY` (default: auto-detected on every file change).

## smbtest

Connects to an SMB2/3 share with `SMBConnection` (SMBClient backend), wraps the file in `SMBIOReader`, and runs a sequential-throughput pass plus a random-seek consistency check. macOS-only; needs the optional `AetherEngineSMB` product (`swift build --product aetherctl` pulls it in). Validates the SMB byte source without a device:

```bash
swift run aetherctl smbtest "smb://user:pass@host/share/path/to/file.mkv" --reads 128
```

`--reads N` sets the random-seek count (default 64). Credentials default to guest when omitted from the URL; URL-encode special characters in the password.

## Fixtures

For repeatable runs, `Scripts/fetch-fixtures.sh` generates a small set of synthetic FFmpeg test clips in `./Fixtures/` (H.264 SDR, HEVC HDR10, AV1, VP9) covering both the native AVPlayer path and the software fallback. Real-world DV / Atmos / multichannel sources go in `./Fixtures/user/` (gitignored).
