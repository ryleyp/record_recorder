# Vinyl Album Recorder

A native macOS app that records vinyl records through a USB audio input
adapter, automatically splits each side into tracks, and exports a fully
tagged MP3 album ready to sync to an iPod with Apple Music or Finder.

Everything runs locally: no accounts, no cloud, no subscriptions, works
fully offline.

## Requirements

- **To run:** macOS 14 (Sonoma) or later. Built and tested on Apple Silicon;
  the Release build is a universal binary.
- **To build:** Xcode 16 or later (developed with Xcode 26). No other tools —
  the LAME MP3 encoder is vendored as source and compiles with the app. No
  Homebrew, no package managers, no network access needed.
- **Hardware:** a record player with an AUX/headphone output and a USB audio
  input adapter (line-in or "USB sound card"). The MacBook headphone jack does
  **not** accept audio input.

## Building and running

```bash
git clone https://github.com/ryleyp/record_recorder.git
cd record_recorder
open VinylAlbumRecorder.xcodeproj   # then press ⌘R in Xcode
```

or from the command line:

```bash
xcodebuild -project VinylAlbumRecorder.xcodeproj \
           -scheme VinylAlbumRecorder -configuration Release build
```

The built app lands in Xcode's DerivedData products folder; copy
`VinylAlbumRecorder.app` to /Applications if you like.

First recording: macOS will ask for **microphone permission** — macOS groups
USB line-in adapters under microphone access, so this is the app asking to
hear your record player. If you denied it, re-enable it in
System Settings › Privacy & Security › Microphone.

## Running the tests

```bash
xcodebuild -project VinylAlbumRecorder.xcodeproj \
           -scheme VinylAlbumRecorder test
```

35 automated tests cover track detection (silence, surface noise, quiet
musical passages, false gaps), boundary scoring, minimum track length,
trim suggestions, track numbering across sides, file-name sanitization,
project save/restore, ID3 metadata, and end-to-end MP3 export (the exported
files are decoded back with CoreAudio to verify duration, sample rate, and
tags).

Sample audio for manual experiments can be regenerated with:

```bash
swift Scripts/generate_sample_audio.swift   # writes SampleAudio/*.wav
```

## Two ways in

The first stage offers two large choices that both feed the same detection,
review, metadata, and export pipeline:

**A. Record from Audio Input** — capture the record live through a USB audio
adapter (the original workflow, below).

**B. Import from USB or Folder** — bring in recordings the Crosley (or
anything else) already saved: MP3, WAV, AIFF, M4A, AAC, FLAC, or CAF, from a
mounted USB flash drive, SD card, external drive, or any folder. Removable
drives are listed automatically and refresh on insert/eject.

- One file can be a whole side (track detection runs on it) or each file can
  already be one track (no detection; confirm the order, done).
- Two files can be imported at once as Side A and Side B.
- Files are copied into the project by default; a reference-only mode is
  available. Originals are never modified.
- Every import is probed (format, sample rate, bit depth, channels, duration,
  bitrate) with warnings for mono, low-bitrate, corrupt, or unsupported files.
- Imported audio is **never re-encoded until final export**, and imported
  MP3 tracks can be exported with **"Keep original encoding"** — tags are
  rewritten but the audio frames are copied byte-for-byte (verified by test).

**Tracklist-guided splitting:** paste the album's tracklist (from the sleeve,
Discogs, Wikipedia…) into the Detect stage — one track per line, runtimes
optional but recommended (`1. Dreams 4:14`). Cuts snap to the detected gap
nearest each listed runtime, and titles (plus optional `Artist:` / `Album:` /
`Year:` lines) fill in automatically. The app is fully offline by design, so
it can't look albums up itself — pasting is the mechanism.

**Audacity interoperability:** recorded and split in Audacity already? Export
audio (WAV/FLAC/MP3/…) plus File › Export › **Export Labels**, then import
both together (or drag-drop them onto the app). Labels become track
boundaries and titles instantly — no silence detection needed. `.aup3`
projects aren't readable yet; export from Audacity first.

## The recording workflow

1. **Add Music** — pick your USB audio input from the device list (or import).
2. **Set Levels** — play the loudest part of the record and adjust the
   player's volume until peaks sit between -12 and -6 dBFS; a CLIP lamp warns
   about distortion.
3. **Record** — record Side A (and later Side B) to a lossless working file.
   Pause/resume/stop/cancel supported; the Mac won't sleep mid-recording, and
   a crash-recovery marker protects long sessions.
4. **Detect Tracks** — the app scores quiet gaps (duration, depth vs.
   surrounding music, energy jump at song starts) and proposes boundaries.
   Conservative / Balanced / Aggressive presets plus manual threshold, gap,
   and minimum-track-length controls. Re-run any time; the original recording
   is never modified.
5. **Review Tracks** — full-side waveform with draggable boundary markers,
   green/red trim handles for lead-in/run-out, zoom, scrubbing, per-cut audio
   preview, short-track warnings, and undo/redo.
6. **Album Details** — album title/artist/year/genre/disc, artwork
   (drag-and-drop), and a table to name every track. Numbering continues from
   Side A to Side B automatically.
7. **Export** — CBR MP3 at 320 (default), 256, or 192 kbps with ID3v2.3 tags
   (UTF-16 text + embedded artwork), organized as:

```
Music/
  Artist Name/
    Album Name/
      01 - Song Title.mp3
      02 - Song Title.mp3
      Album Artwork.jpg
      Album Name.m3u                 (optional)
      Original Recordings/
        Side A.wav                   (optional lossless copies)
        Side B.wav
```

Optional gentle peak normalization (off by default — the vinyl's character is
preserved exactly as captured). "Reveal in Finder", "Open in Apple Music",
and step-by-step iPod sync instructions are built in.

Projects are saved as `.vinylproj` packages (JSON + recordings + artwork)
in `~/Music/Vinyl Album Recorder/` by default, auto-saved as you edit, and
reopenable later — record Side A today and Side B next week.

## Documentation

- [docs/USER_GUIDE.md](docs/USER_GUIDE.md) — plain-language walkthrough
- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) — technical design
- [docs/DEPENDENCIES_AND_LICENSES.md](docs/DEPENDENCIES_AND_LICENSES.md) — LAME licensing and build details
- [docs/KNOWN_LIMITATIONS.md](docs/KNOWN_LIMITATIONS.md)
- [docs/SIGNING_CHECKLIST.md](docs/SIGNING_CHECKLIST.md) — preparing a signed/notarized build
- [docs/MANUAL_TEST_CHECKLIST.md](docs/MANUAL_TEST_CHECKLIST.md) — hardware test plan
- [docs/IMPLEMENTATION_PLAN.md](docs/IMPLEMENTATION_PLAN.md)

## License

Application code: MIT (see LICENSE). The bundled LAME encoder
(`VinylAlbumRecorder/ThirdParty/lame/`) is LGPL-2.1 — see
[docs/DEPENDENCIES_AND_LICENSES.md](docs/DEPENDENCIES_AND_LICENSES.md).
