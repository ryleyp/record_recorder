# Vinyl Album Recorder

A browser web app for recording or importing vinyl sides, detecting track
breaks, editing album metadata, and exporting a ZIP package of WAV tracks.

The app is designed for GitHub Pages: it is static, dependency-free, and runs
locally in the browser after it loads. No account, backend, database, or build
step is required.

## Run the Web App

Open `web/index.html` from a local web server:

```bash
cd web
python3 -m http.server 8000
```

Then visit `http://localhost:8000`.

Recording from a USB audio input requires a secure browser context. GitHub
Pages works because it is HTTPS; local `localhost` also works in modern
browsers.

## iPad

Use the GitHub Pages HTTPS version in Safari, then choose Share > Add to Home
Screen for the app-like version. Connect the USB turntable or audio interface
before opening the app, tap Refresh in Recording Input, allow audio input
access, and select the source before setting levels or recording.

## GitHub Pages

This repo includes `.github/workflows/pages.yml`. After the changes are pushed
to `main` or `master`, GitHub Actions uploads the `web/` folder and deploys it
to GitHub Pages.

If Pages has not been enabled yet:

1. Open the repository settings on GitHub.
2. Go to Pages.
3. Set the source to GitHub Actions.
4. Push to `main` or run the "Deploy Web App" workflow manually.

## Web Workflow

1. Add music by importing existing side recordings, or continue to level setup
   before recording through a USB input. Imported recordings can be optimized
   on the way in with cleanup presets, DC-offset removal, rumble filtering,
   stereo balance correction, click/pop detection, optional gentle de-click,
   noise-floor profiling, and optional peak normalization.
2. Set levels with live stereo meters, peak/RMS readouts, 12-second loudest
   section analysis, 5-second surface-noise measurement, automatic problem
   detection, and a 0-100 recording quality score.
3. Record Side A/Side B in the browser as lossless audio. During recording,
   the app listens for lead-in silence and long quiet run-out/flip gaps, then
   suggests start/end trims while preserving the full original capture.
4. Run track detection with the conservative, balanced, or aggressive preset.
5. Optionally paste a tracklist with runtimes or import Audacity label text.
   Runtime-guided splitting scales the listed runtimes to the actual side,
   searches near each expected cut for the best quiet gap, and labels each
   split as high, medium, or low confidence. The app also estimates playback
   speed/pitch drift from the listed runtimes.
6. Review the waveform and drag trim/cut markers.
7. Fill in album and track metadata.
8. Export a ZIP containing WAV tracks, an M3U playlist, artwork, original side
   WAVs, and `album-project.json`. Export can optionally crop long quiet
   sections from track WAVs while preserving the untouched side recordings.

## Browser Notes

- Browser audio decoding varies by browser. WAV, MP3, M4A, and AAC are the
  safest import formats.
- The web app exports WAV rather than MP3. The original macOS app's MP3 export
  used CoreAudio plus the vendored LAME encoder; that native pipeline is not
  available on GitHub Pages.
- The Set Levels stage targets vinyl-friendly capture: peaks around -10 dBFS,
  ideal peaks between -12 and -6 dBFS, average RMS around -24 to -18 dBFS, and
  noise floor below -45 dBFS where practical.
- Recording diagnostics are saved in `album-project.json`, including peak,
  RMS, dynamic range, noise floor, clipping count, hum detection, and stereo
  balance.
- Import optimization is non-destructive within the session: the cleaned
  working copy is used for splitting/export while the untouched import is used
  for the optional Original Recordings export.
- Export options include edge fades, optional peak normalization, gentle
  per-track loudness matching for a more even album without compression, and
  optional long-silence cropping with threshold, minimum length, and padding
  controls.
- Project save/load stores metadata, trims, and markers. Audio is kept in the
  current browser session and included in the final ZIP export.
- Large album sides can use substantial memory while encoding the final ZIP.

## Tests

The web detector/parser tests use Node's built-in test runner:

```bash
npm test --prefix web
```

## Original macOS App

The native SwiftUI app remains in `VinylAlbumRecorder/` with the Xcode project
at `VinylAlbumRecorder.xcodeproj`. It is useful as the historical source for
the detection and export behavior, and it still supports native MP3 tagging and
Finder integration.

```bash
xcodebuild -project VinylAlbumRecorder.xcodeproj \
           -scheme VinylAlbumRecorder -configuration Release build
```

## Documentation

- [docs/USER_GUIDE.md](docs/USER_GUIDE.md) - original native-app walkthrough
- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) - technical design
- [docs/DEPENDENCIES_AND_LICENSES.md](docs/DEPENDENCIES_AND_LICENSES.md) - LAME licensing and build details
- [docs/KNOWN_LIMITATIONS.md](docs/KNOWN_LIMITATIONS.md)
- [docs/SIGNING_CHECKLIST.md](docs/SIGNING_CHECKLIST.md)
- [docs/MANUAL_TEST_CHECKLIST.md](docs/MANUAL_TEST_CHECKLIST.md)
- [docs/IMPLEMENTATION_PLAN.md](docs/IMPLEMENTATION_PLAN.md)

## License

Application code: MIT (see LICENSE). The bundled LAME encoder under
`VinylAlbumRecorder/ThirdParty/lame/` is LGPL-2.1.
