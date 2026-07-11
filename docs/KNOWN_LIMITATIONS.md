# Known Limitations

## Hardware / capture

- **No input gain control in the app.** USB line-in adapters rarely expose a
  software gain stage; you set the level with the record player's volume knob
  while watching the meters. (Adapters that do expose gain can be adjusted in
  Audio MIDI Setup.)
- **Recording captures at the device's native sample rate** (typically 44.1
  or 48 kHz); the app does not force the device to 44.1 kHz. Export always
  resamples to 44.1 kHz for the MP3s. The WAV "Original Recordings" keep the
  native rate.
- Devices with more than 2 input channels record only the first two.
- If the USB adapter is unplugged mid-recording the take is stopped and kept,
  but the tail written during the disconnect may contain a brief glitch.

## Detection

- Detection is tuned for typical LPs: gaps of roughly 1–8 seconds. Quiet
  stretches longer than 15 seconds are deliberately never treated as gaps
  (they are almost always quiet passages or fades), so two songs separated by
  an unusually long silence must be split manually with Add Marker.
- Live albums, crossfaded albums, and classical works without inter-movement
  silence will need manual marker placement — that's inherent to the medium.

## Export / metadata

- Peak normalization boost is capped at +18 dB to avoid amplifying noise on
  nearly-silent segments.
- ID3 genre is written as free text (TCON); Apple Music reads it fine, some
  vintage players only understand the numeric ID3v1 genre list.
- No ID3v1 fallback tag is written (ID3v2.3 only). Every Apple device and
  every player from this century reads v2.
- "Confirm MP3s import into Apple Music" is verified in CI-style tests by
  decoding the exported files with CoreAudio (the same decoder Apple Music
  uses); the actual drag-into-Music step is on the manual checklist.

## Projects

- `.vinylproj` packages are plain folders; Finder shows them as folders (no
  custom document icon/UTI registration in v1). Don't rearrange their
  contents by hand.
- Sides are limited to A and B (one disc per project). Multi-disc sets:
  use one project per disc and set the disc number in Album Details.
- Moving a project keeps working (all paths are package-relative), but the
  export destination preference stores an absolute path and may need
  re-choosing after a move.

## App / platform

- Not sandboxed in v1 (fine for direct distribution; App Store submission
  would require enabling the sandbox and security-scoped bookmarks — see
  SIGNING_CHECKLIST.md).
- Ad-hoc signed local builds only; distributing to other Macs needs
  Developer ID signing + notarization (see SIGNING_CHECKLIST.md).
- No direct iPod writing — by design. The app produces standard MP3 files
  and defers device sync to Finder/Apple Music.
- UI is English-only in v1.
