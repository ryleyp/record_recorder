# Implementation Plan (as executed)

Environment: Xcode 26.6 (Swift 6.3.3, Swift 5 language mode), macOS 14
deployment target, Apple Silicon.

1. **Feasibility first: the MP3 encoder.** macOS frameworks cannot encode
   MP3, so LAME 3.100 was downloaded (SHA-256 verified against the official
   release), configured (`--disable-frontend --disable-decoder`), and
   test-compiled standalone for arm64 before committing to the approach.
2. **Project scaffold.** Hand-written `project.pbxproj` (objectVersion 77,
   file-system-synchronized groups) with app + hosted unit-test targets,
   shared scheme, hardened-runtime entitlements (`audio-input`), bridging
   header exposing `<lame.h>`. Validated with a minimal app that calls
   `get_lame_version()` — built clean, committed as the first checkpoint.
3. **Audio layer.** CoreAudio device enumeration with hot-plug listener;
   AVAudioEngine capture bound to the selected device; render-thread metering
   (peak/RMS/clip); lossless CAF writing with pause/resume via an atomic
   flag; sleep prevention; disk-space readout; disconnect handling; crash
   recovery marker.
4. **Detection.** Streaming analyzer producing waveform peaks + RMS envelope;
   pure scored-gap detector (duration/depth/edge scoring, adaptive-threshold
   fallback, trim suggestions, min/max gap and min-track enforcement,
   three presets).
5. **Model & persistence.** Codable `AlbumProject` in a `.vinylproj` package
   with recordings + artwork; autosave; audio-health and recovery reporting.
6. **Export.** Segment reader with optional normalization pre-pass, edge
   fades, 44.1 kHz resampling, LAME CBR encoding, Swift ID3v2.3 writer
   (UTF-16 + APIC artwork), album folder layout, WAV originals, M3U,
   overwrite protection, cancellation.
7. **UI.** Seven-stage guided flow (Connect → Set Levels → Record → Detect →
   Review → Album Details → Export) behind a sidebar; waveform Canvas editor
   with draggable markers, trims, zoom, previews, undo/redo; welcome screen;
   alerts for permissions, disconnects, recovery, and missing files.
8. **Tests.** 35 XCTests over generated audio fixtures (clear silence, quiet
   passages, surface noise, false gaps, unequal stereo), model logic,
   persistence, tags, and end-to-end MP3 export verified by decoding with
   CoreAudio. The suite caught one real bug (unconditional adaptive threshold
   splitting quiet passages), which was fixed by making the raise a fallback
   and adding a maximum plausible gap duration.
9. **Verification & docs.** Release build (universal), launch smoke test,
   sample-audio generator script, README + architecture + user guide +
   licenses + limitations + signing and manual-test checklists.
