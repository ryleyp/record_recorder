import test from "node:test";
import assert from "node:assert/strict";
import {
  createRecordingGapListener,
  finalizeRecordingGapListener,
  updateRecordingGapListener
} from "../src/gapListener.js";

test("gap listener finds music start after lead-in silence", () => {
  const listener = createRecordingGapListener({ noiseFloorDBFS: -55 });
  feed(listener, -60, 3);
  feed(listener, -22, 1);
  const summary = finalizeRecordingGapListener(listener, 4);

  assert.equal(listener.phase, "recording_music");
  assert.ok(summary.music_start_time >= 2.9 && summary.music_start_time <= 3.1);
  assert.ok(summary.suggested_trim_start >= 2.4 && summary.suggested_trim_start <= 2.7);
});

test("gap listener detects long run-out or flip gap", () => {
  const listener = createRecordingGapListener({ noiseFloorDBFS: -55 });
  feed(listener, -60, 2);
  feed(listener, -20, 4);
  feed(listener, -58, 7);
  const summary = finalizeRecordingGapListener(listener, 13);

  assert.equal(summary.long_gap_detected, true);
  assert.ok(summary.long_gap_start_time >= 5.9 && summary.long_gap_start_time <= 6.2);
  assert.ok(summary.suggested_trim_end >= 5.6 && summary.suggested_trim_end <= 6.1);
});

test("gap listener ignores short quiet breaks before music resumes", () => {
  const listener = createRecordingGapListener({ noiseFloorDBFS: -55 });
  feed(listener, -20, 3);
  feed(listener, -58, 3);
  feed(listener, -20, 2);
  const summary = finalizeRecordingGapListener(listener, 8);

  assert.equal(summary.long_gap_detected, false);
  assert.equal(summary.suggested_trim_end, 8);
});

function feed(listener, rmsDBFS, seconds) {
  const step = 0.1;
  for (let elapsed = 0; elapsed < seconds; elapsed += step) {
    updateRecordingGapListener(
      listener,
      { rms_dbfs: rmsDBFS, short_term_average_dbfs: rmsDBFS },
      step
    );
  }
}
