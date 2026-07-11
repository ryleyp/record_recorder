# Signed-App Preparation Checklist

The repository builds and runs locally with ad-hoc signing (`CODE_SIGN_IDENTITY = "-"`).
To distribute the app to other Macs:

## 1. Developer ID signing

- [ ] Enroll in the Apple Developer Program.
- [ ] In Xcode › Signing & Capabilities for the **VinylAlbumRecorder** target:
  set your Team, change signing to your **Developer ID Application**
  certificate (for distribution outside the App Store).
- [ ] Keep `ENABLE_HARDENED_RUNTIME = YES` (already set). The entitlements
  file already contains `com.apple.security.device.audio-input`, which the
  hardened runtime requires for microphone/line-in capture.
- [ ] Bump `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` as appropriate.

## 2. Archive & notarize

- [ ] `Product › Archive` (or `xcodebuild archive …`).
- [ ] Export with the "Developer ID" method.
- [ ] Notarize: `xcrun notarytool submit VinylAlbumRecorder.zip --keychain-profile <profile> --wait`
- [ ] Staple: `xcrun stapler staple VinylAlbumRecorder.app`
- [ ] Verify: `spctl -a -vv VinylAlbumRecorder.app` → "accepted, source=Notarized Developer ID".

## 3. First-run verification on a clean machine

- [ ] Gatekeeper opens the app without right-click workarounds.
- [ ] Microphone permission prompt appears with the explanatory text.
- [ ] Record/export a short test side end-to-end.

## 4. If App Store distribution is ever wanted

- [ ] Enable App Sandbox and add: `com.apple.security.device.audio-input`,
  `com.apple.security.files.user-selected.read-write`.
- [ ] Replace persisted absolute paths (export destination) with
  security-scoped bookmarks.
- [ ] Register an exported UTI for `.vinylproj` and declare it as a document
  package so sandboxed open panels treat it correctly.
- [ ] Re-review LGPL obligations for LAME under App Store terms — the safe
  route is converting LAME to a dynamically linked, replaceable library or
  switching the encoder.
