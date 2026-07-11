# Manual Test Checklist

Hardware-dependent behavior that automated tests can't cover. Run with a real
record player + USB audio adapter before calling a build good.

## USB audio input selection

- [ ] Launch with no adapter connected → Connect stage shows the "no usable
  input" callout (built-in mic may still be listed; that's expected).
- [ ] Plug the adapter in → it appears in the list without clicking Refresh.
- [ ] Select it → channel count and sample rate shown match the device.
- [ ] Mono adapter (or a mono-only device) → mono warning callout appears.
- [ ] Continue → macOS microphone permission prompt appears (first run);
  denying it shows the explanatory error with the System Settings pointer;
  allowing proceeds to live meters.

## Levels

- [ ] Meters move with the record; L and R differ when the source differs.
- [ ] Cranking the volume drives peaks above -0.3 dBFS → CLIP lamp lights and
  stays lit ~1.5 s; "Loudest peak" text tracks the max and the reset works.
- [ ] Speaker monitoring toggle shows the feedback warning first, and audio
  only passes through after confirming.

## Stereo recording

- [ ] Record ~2 minutes of a real record on Side A. Stop & Continue.
- [ ] The CAF in the project package plays in QuickTime and is stereo,
  16-bit, at the device's sample rate.
- [ ] Pause, wait 10 s, Resume → the pause is absent from the recording.
- [ ] Discard asks for confirmation and removes the file.

## Device disconnection

- [ ] While recording, unplug the USB adapter → app stops the recording,
  keeps the audio so far, and shows the disconnect alert.
- [ ] Replug, restart monitoring, and re-record without relaunching the app.

## Long recording

- [ ] Record ≥ 45 minutes (or 90+ for the full spec target). Elapsed time
  stays accurate, memory stays flat, the Mac does not sleep, disk space
  readout updates.
- [ ] Analysis of the long side completes with a progress bar and the
  waveform stays responsive when zooming.

## Crash recovery

- [ ] Start a recording, wait ≥ 1 minute, then force-quit the app
  (⌥⌘Esc or `kill -9`).
- [ ] Relaunch and reopen the project → "Recording Recovered" alert appears
  and the captured audio (up to the kill) is present, analyzable, and
  exportable.

## MP3 export & Apple Music import

- [ ] Export a real album at 320 kbps with artwork and titles.
- [ ] Folder layout matches `Artist/Album/01 - Title.mp3 …` with
  `Album Artwork.jpg`, the `.m3u`, and `Original Recordings/*.wav`.
- [ ] Drag the album folder into Apple Music → tracks import with correct
  titles, order (Side A then B), album grouping, year, genre, and artwork.
- [ ] Play an MP3 start-to-finish in Music; cut points sound clean (no
  clicks — the 15 ms fade-out is inaudible).
- [ ] Sync the album to an iPod via Finder/Music and play it on the device.

## Reopening a saved project

- [ ] Quit the app mid-workflow (after detection, before export). Relaunch,
  Open Project → markers, trims, titles, artwork, and settings are intact.
- [ ] Move one side's CAF out of the package, reopen → "Recordings Missing"
  alert names the right side.
- [ ] Record Side A, close, reopen next day, record Side B → export numbers
  Side B tracks continuing after Side A.
