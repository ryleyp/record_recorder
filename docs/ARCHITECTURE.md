# Architecture

## Overview

Vinyl Album Recorder is a single-window SwiftUI app (macOS 14+) with four
layers under the UI:

```
UI (SwiftUI stage views)
└── AppState (@MainActor ObservableObject — the only mutable app-wide state)
    ├── Audio        AudioDeviceManager · RecordingEngine · PlaybackController
    ├── Detection    SideAnalyzer · LoudnessEnvelope · TrackDetector
    ├── Export       TrackExporter · LameMP3Encoder · ID3TagWriter
    └── Model        AlbumProject · ProjectStore · FileNameSanitizer
```

All heavy work (waveform analysis, MP3 encoding, WAV copying) runs in
detached tasks off the main thread with progress callbacks marshalled back to
`@MainActor`.

## Audio capture

- **Device enumeration** (`AudioDeviceManager`) uses CoreAudio
  (`AudioObjectGetPropertyData`) to list devices with input channels, their
  UID, name, channel count, and nominal sample rate. A
  `kAudioHardwarePropertyDevices` listener refreshes the list on hot-plug.
- **Capture** (`RecordingEngine`) uses `AVAudioEngine`. The selected device is
  bound by setting `kAudioOutputUnitProperty_CurrentDevice` on the input
  node's underlying audio unit before starting. A tap on the input node feeds:
  - `MeterBox` — per-channel peak/RMS accumulated on the render thread behind
    an `os_unfair_lock`, drained by a 20 Hz main-thread timer (published as
    dBFS levels, sticky clip lamp, session-max peak for the level check).
  - `AVAudioFile` — writes 16-bit PCM at the device's native sample rate.
    Recording never resamples; conversion to 44.1 kHz happens at export.
- **Why CAF for the working file:** a CAF whose data-chunk size is unknown is
  defined as "read to end of file", so a recording interrupted by a crash or
  power loss stays readable up to the last written buffer. Combined with a
  `recording-in-progress.json` marker in the project package, this gives crash
  recovery without a separate journal.
- **Pause/resume** is a lock-free atomic flag read by the tap; the engine
  keeps running (meters stay live) while file writes are skipped.
- **Sleep prevention** via `ProcessInfo.beginActivity(.idleSystemSleepDisabled)`
  for the duration of a recording.
- **Disconnect detection**: `AVAudioEngineConfigurationChange` notifications
  plus a periodic device-alive check; an unplugged device stops the recording
  gracefully and keeps the file.
- **Speaker monitoring** is implemented by permanently connecting input →
  main mixer with `outputVolume` 0; the optional toggle (behind a feedback
  warning) just raises the volume, avoiding graph rebuilds.

## Track detection

`SideAnalyzer` streams the CAF once and produces:
- min/max peak buckets every 25 ms (waveform drawing), and
- an RMS envelope in dBFS every 50 ms (detection).

`TrackDetector.detect(envelope:settings:)` is a pure function (easy to test):

1. **Threshold** — primary pass uses the configured silence threshold
   (default -40 dBFS), clamped out of music territory. If no usable quiet run
   is found (worn vinyl whose gaps never drop that low), one retry raises the
   threshold to `noiseFloor(5th percentile) + 8 dB`. The raise is deliberately
   a *fallback only*: applied unconditionally it would split quiet musical
   passages.
2. **Runs** below the threshold become candidates. Runs touching the edges
   become lead-in/run-out **trim suggestions**, never tracks.
3. **Scoring** per gap (0…1): 40% duration (full credit at 2× minimum gap),
   35% depth below the surrounding ±5 s of music, 25% energy jump right after
   the gap (song starts are sharp). Gaps longer than 15 s are rejected as
   quiet passages/fades — real inter-song gaps last a few seconds.
4. **Acceptance** requires minimum gap duration (default 1.5 s) and a
   preset-dependent score cutoff (conservative 0.62 / balanced 0.48 /
   aggressive 0.34). The cut point is the quietest hop in the gap.
5. **Minimum track length** (default 30 s) is enforced by repeatedly deleting
   the weaker-scored boundary adjoining any too-short segment.

## Review editor

`ReviewView` draws the analysis peaks in a `Canvas`; a single drag gesture
either grabs the nearest marker (within 10 pt) or scrubs the playhead.
Boundaries and trims live in the project model; every edit goes through
`reconcileTrackList()` so track titles survive marker changes. Undo/redo is a
snapshot stack of `(boundaries, trimStart, trimEnd)`. Playback uses
`AVAudioPlayer` (native CAF support, seekable) with a "preview around cut"
helper.

## Export

`TrackExporter.export` renders each segment:

CAF segment → optional peak pre-pass (normalization gain, capped +18 dB) →
edge fades in the source timeline (default: none in, 15 ms out) →
`AVAudioConverter` resample to 44.1 kHz if the device recorded at another
rate → float→int16 interleave → **LAME** CBR encode → write
`ID3v2.3 tag + frames` atomically.

- **LAME** (vendored 3.100, compiled into the app) is configured CBR at
  192/256/320 kbps, joint stereo (or mono for mono devices), quality 2,
  Xing/Info header off (unnecessary for CBR), LAME's own ID3 writer off.
- **ID3v2.3 tags are written by `ID3TagWriter` in Swift** instead of LAME's
  tag API so that titles in any language round-trip via UTF-16 text frames.
  Frames: TIT2, TPE1, TALB, TPE2, TYER, TCON, TRCK (n/total),
  TPOS (disc/total), APIC (front cover JPEG/PNG). A matching parser exists for
  the tests.
- Track numbering flattens Side A then Side B (`AlbumProject.exportOrder`),
  so Side B continues from Side A within the album.
- Original CAFs are converted to 16-bit WAV copies chunk-by-chunk; an M3U
  playlist and the artwork JPEG complete the album folder.
- Export runs in a cancellable detached `Task`; an existing non-empty album
  folder raises `albumFolderExists`, which the UI turns into a
  replace/cancel confirmation.

## Persistence

A project is a folder package `Name.vinylproj`:

```
Name.vinylproj/
  project.json                   (Codable AlbumProject, pretty-printed)
  Artwork.jpg                    (optional)
  Recordings/Side A.caf, Side B.caf
  recording-in-progress.json     (only while recording; crash marker)
```

`AppState` autosaves the JSON one second after any model change. On open,
`ProjectStore.audioStatus` reports missing recordings (moved/deleted files)
and interrupted recordings, which the UI surfaces as alerts; recovered
partial audio is kept and marked recorded.

## Concurrency notes

- The project targets Swift 5 language mode. `AppState`,
  `RecordingEngine`, `AudioDeviceManager`, and `PlaybackController` are
  `@MainActor`; the audio tap intentionally reads two thread-safe primitives
  (`MeterBox`, `AtomicFlag`) plus `AVAudioFile.write` (safe off-main; the file
  reference is only swapped while the write flag is cleared, which quiesces
  the tap first).
- Detection/analysis/export are pure or self-contained and run in
  `Task.detached`.

## Build system

The Xcode project uses objectVersion 77 with file-system-synchronized groups:
`VinylAlbumRecorder/` and `VinylAlbumRecorderTests/` folders *are* the target
memberships, so adding a file to the folder adds it to the build. LAME's C
sources under `VinylAlbumRecorder/ThirdParty/lame/` compile directly into the
app target (`HAVE_CONFIG_H` + header search paths; `config.h` was generated by
LAME's configure on macOS/arm64 and is portable to x86_64 as vendored). The
bridging header exposes `<lame.h>` to Swift. Tests are hosted in the app
(`TEST_HOST`) and use `@testable import`.
