import test from "node:test";
import assert from "node:assert/strict";
import { cleanTrackTitle } from "../src/utils.js";

test("cleanTrackTitle removes leading track numbers from export titles", () => {
  assert.equal(cleanTrackTitle("01 - Dreams", "Track 01", 1), "Dreams");
  assert.equal(cleanTrackTitle("1. Second Hand News", "Track 01", 1), "Second Hand News");
  assert.equal(cleanTrackTitle("Track 01 - Dreams", "Track 01", 1), "Dreams");
  assert.equal(cleanTrackTitle("A2. Never Going Back Again", "Track 02", 8), "Never Going Back Again");
});

test("cleanTrackTitle keeps numeric song titles unless they match the export track number", () => {
  assert.equal(cleanTrackTitle("99 Luftballons", "Track 01", 1), "99 Luftballons");
  assert.equal(cleanTrackTitle("01 Dreams", "Track 02", 2), "01 Dreams");
  assert.equal(cleanTrackTitle("01 Dreams", "Track 01", 1), "Dreams");
});
