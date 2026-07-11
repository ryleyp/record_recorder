# User Guide

This guide assumes no audio-software experience. Total time for your first
album: about the length of the record plus 10 minutes.

## What you need

- Your record player, with a volume knob and an AUX or headphone output.
- A USB audio input adapter (a small "USB sound card" with a line-in or mic
  jack). The Mac's own headphone jack cannot record audio.
- An AUX cable from the record player to the adapter.

Plug the record player's output into the adapter's **input**, and the adapter
into the Mac.

## Step 0 — Create a project

Open Vinyl Album Recorder and click **New Album Project**. Give it the album
name. Projects are saved automatically as you work, in
`Music/Vinyl Album Recorder`, and you can quit and come back any time —
recording Side A today and Side B tomorrow is fine.

## Step 1 — Connect

Your USB adapter should appear in the list (often called "USB Audio Device").
Click it, then **Continue**. If the list is empty, plug the adapter in and
click Refresh.

macOS will ask for **microphone permission** the first time. Click Allow —
macOS calls all audio inputs "microphones", including line-in adapters.

If the app warns the device is **mono**, your adapter has a microphone-only
input; the recording will still work but won't be stereo.

## Step 2 — Set Levels

Put on the record and play its loudest song (usually the opener). Watch the
two meters:

- Peaks should land **between the two green lines** (-12 to -6 dBFS).
- If the red **CLIP** lamp lights, the signal is distorting — turn the record
  player's volume **down**.
- Too quiet is safer than too loud, but try to get into the green zone.

The "Loudest peak so far" line remembers the highest level it heard and tells
you in plain words whether it's right. When it says "Perfect", lift the
needle, cue back to the start, and continue.

Leave "Play input through the speakers" **off** unless you're wearing
headphones — otherwise the record player can hear the speakers and howl.

## Step 3 — Record

1. Pick **Side A** or **Side B**.
2. Click the big red **Record** button.
3. Drop the needle at the start of the side.
4. Let the whole side play. You'll see the elapsed time, live meters, and
   remaining disk space. The Mac won't go to sleep.
5. When the needle reaches the run-out groove, click **Stop & Continue**.

Pause/Resume is available (space bar). **Discard** deletes the take after
asking you to confirm. Don't worry about the silence before the first song or
after the last — it's trimmed automatically in the next step.

If the app or Mac crashes mid-side, reopen the project: the audio captured
before the crash is recovered automatically.

## Step 4 — Detect Tracks

Click **Detect Track Boundaries**. The app scans the side for the quiet gaps
between songs and lists the tracks it found with their lengths.

If the result looks wrong:

- **Too few tracks found** → try the **Aggressive** preset (short/noisy gaps).
- **A song got split in half** → try **Conservative** (quiet passages).
- Fine-tune with the sliders if you like — threshold is "how quiet counts as
  a gap", minimum gap is "how long the quiet must last".

Re-run as often as you want; the recording itself is never changed.

## Step 5 — Review Tracks

The waveform shows the whole side:

- **Yellow markers** are the cuts between tracks. Drag to adjust; the top
  circle is the handle.
- **Green/red markers** trim the silence at the very start and end.
- Click anywhere to move the playhead; press **space** to play/pause.
- **Cut** (in the track list) plays 3 seconds before and after a cut so you
  can hear whether it lands in the right place. **Start** plays the first
  5 seconds of a track.
- **Add Marker** (⌘M) drops a new cut at the playhead; **Delete Marker**
  removes the selected one. ⌘Z / ⇧⌘Z undo and redo.
- Zoom in with the magnifier slider to place a cut precisely.
- Tracks under 30 seconds get a warning flag — they're often false splits.

## Step 6 — Album Details

Fill in the album title, artist, year, and genre, and drop the cover art onto
the artwork square (drag a JPEG/PNG from Finder or a browser). Then type each
track's name in the table. Anything left blank exports as "Track 01",
"Track 02", … Numbers continue across sides automatically — if Side A has
5 tracks, Side B starts at 6.

## Step 7 — Export

Keep the defaults (320 kbps, no normalization) unless you have a reason not
to, choose where the album should go (default: your Music folder), and click
**Export Album**. You get:

```
Music/Artist Name/Album Name/
  01 - First Song.mp3 …
  Album Artwork.jpg
  Album Name.m3u
  Original Recordings/Side A.wav, Side B.wav
```

Then click **Reveal Album in Finder** or **Open in Apple Music**, and use
**"How do I get this onto my iPod?"** for step-by-step sync instructions.

## Tips

- Clean the record first; loud pops can confuse the level check.
- The "Original Recordings" WAVs are your archival copies — keep them and you
  can re-export at any quality later without touching the turntable.
- One project = one album. Use New Album Project for the next record.
