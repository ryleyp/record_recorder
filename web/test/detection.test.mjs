import test from "node:test";
import assert from "node:assert/strict";
import {
  DETECTION_PRESETS,
  alignTracklist,
  applyAudacityLabels,
  detectTracks,
  parseAudacityLabels,
  parseTracklist,
  secondsFromTimestamp
} from "../src/detection.js";
import { crc32 } from "../src/zip.js";

test("detectTracks finds clear gaps and trims edge silence", () => {
  const hopSeconds = 0.05;
  const valuesDB = [
    ...repeat(-90, 20),
    ...repeat(-8, 120),
    ...repeat(-80, 50),
    ...repeat(-9, 120),
    ...repeat(-82, 48),
    ...repeat(-10, 120),
    ...repeat(-90, 20)
  ];
  const result = detectTracks(
    { hopSeconds, valuesDB, duration: valuesDB.length * hopSeconds },
    { ...DETECTION_PRESETS.aggressive, minimumTrackSeconds: 4 }
  );

  assert.equal(result.boundaries.length, 2);
  assert.ok(result.suggestedTrimStart > 0.8 && result.suggestedTrimStart < 1.2);
  assert.ok(result.suggestedTrimEnd > 23.5 && result.suggestedTrimEnd < 24.2);
});

test("parseTracklist extracts headers, titles, and runtimes", () => {
  const parsed = parseTracklist(`
    Artist: Fleetwood Mac
    Album: Rumours
    Year: 1977
    A1. Second Hand News 2:56
    A2 - Dreams (4:14)
    Never Going Back Again
  `);

  assert.equal(parsed.albumArtist, "Fleetwood Mac");
  assert.equal(parsed.albumTitle, "Rumours");
  assert.equal(parsed.year, 1977);
  assert.deepEqual(parsed.entries.map((entry) => entry.title), [
    "Second Hand News",
    "Dreams",
    "Never Going Back Again"
  ]);
  assert.equal(parsed.entries[0].duration, 176);
  assert.equal(parsed.entries[1].duration, 254);
  assert.equal(parsed.entries[2].duration, null);
});

test("alignTracklist snaps runtimes to nearby gaps", () => {
  const entries = [
    { title: "One", duration: 120 },
    { title: "Two", duration: 180 },
    { title: "Three", duration: 120 }
  ];
  const detection = {
    suggestedTrimStart: 0,
    suggestedTrimEnd: 420,
    candidateGaps: [
      { cutTime: 121, score: 0.6 },
      { cutTime: 299, score: 0.8 }
    ]
  };
  assert.deepEqual(alignTracklist(entries, detection), [121, 299]);
});

test("Audacity label regions become trims, boundaries, and titles", () => {
  const labels = parseAudacityLabels("0.500000\t12.000000\tIntro\n12.000000\t30.000000\tSong\n");
  const applied = applyAudacityLabels(labels, 40);
  assert.deepEqual(applied.boundaries, [12]);
  assert.equal(applied.trimStart, 0.5);
  assert.equal(applied.trimEnd, 30);
  assert.deepEqual(applied.titles, ["Intro", "Song"]);
});

test("timestamp parser rejects impossible timestamps", () => {
  assert.equal(secondsFromTimestamp("1:02:03"), 3723);
  assert.equal(secondsFromTimestamp("4:59"), 299);
  assert.equal(secondsFromTimestamp("4:99"), null);
});

test("crc32 matches a known vector", () => {
  assert.equal(crc32(new TextEncoder().encode("123456789")), 0xcbf43926);
});

function repeat(value, count) {
  return Array.from({ length: count }, () => value);
}
