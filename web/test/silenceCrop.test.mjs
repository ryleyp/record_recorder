import test from "node:test";
import assert from "node:assert/strict";
import {
  detectLongSilenceRangesFromChannelData,
  subtractSkipRanges,
  summarizeSilenceCrop
} from "../src/silenceCrop.js";

test("detectLongSilenceRangesFromChannelData finds long quiet runs with padding", () => {
  const sampleRate = 100;
  const samples = new Float32Array(sampleRate * 12);
  fill(samples, 0, 2 * sampleRate, 0.2);
  fill(samples, 2 * sampleRate, 8 * sampleRate, 0.0005);
  fill(samples, 8 * sampleRate, 12 * sampleRate, 0.2);

  const ranges = detectLongSilenceRangesFromChannelData([samples], sampleRate, {
    thresholdDBFS: -50,
    minimumSilenceSeconds: 4,
    keepPaddingSeconds: 0.5
  });

  assert.equal(ranges.length, 1);
  assert.ok(ranges[0].start > 2.4 && ranges[0].start < 2.6);
  assert.ok(ranges[0].end > 7.4 && ranges[0].end < 7.6);
});

test("detectLongSilenceRangesFromChannelData ignores short quiet runs", () => {
  const sampleRate = 100;
  const samples = new Float32Array(sampleRate * 8);
  fill(samples, 0, 2 * sampleRate, 0.2);
  fill(samples, 2 * sampleRate, 4 * sampleRate, 0.0005);
  fill(samples, 4 * sampleRate, 8 * sampleRate, 0.2);

  const ranges = detectLongSilenceRangesFromChannelData([samples], sampleRate, {
    thresholdDBFS: -50,
    minimumSilenceSeconds: 4,
    keepPaddingSeconds: 0.5
  });

  assert.equal(ranges.length, 0);
});

test("detectLongSilenceRangesFromChannelData does not cancel out-of-phase stereo", () => {
  const sampleRate = 100;
  const left = new Float32Array(sampleRate * 6);
  const right = new Float32Array(sampleRate * 6);
  left.fill(0.2);
  right.fill(-0.2);

  const ranges = detectLongSilenceRangesFromChannelData([left, right], sampleRate, {
    thresholdDBFS: -50,
    minimumSilenceSeconds: 4,
    keepPaddingSeconds: 0.5
  });

  assert.equal(ranges.length, 0);
});

test("subtractSkipRanges removes silence from export ranges", () => {
  const keep = subtractSkipRanges(0, 12, [{ start: 2.5, end: 7.5 }]);

  assert.deepEqual(keep, [
    { start: 0, end: 2.5 },
    { start: 7.5, end: 12 }
  ]);
  assert.equal(summarizeSilenceCrop([{ start: 2.5, end: 7.5 }]).removedSeconds, 5);
});

function fill(samples, start, end, value) {
  for (let index = start; index < end; index += 1) {
    samples[index] = value;
  }
}
