import test from "node:test";
import assert from "node:assert/strict";
import { recordingSupportInfo } from "../src/recorder.js";

test("recordingSupportInfo returns stable browser capability flags", () => {
  const support = recordingSupportInfo();

  assert.equal(typeof support.audioWorklet, "boolean");
  assert.equal(typeof support.indexedDB, "boolean");
  assert.equal(typeof support.wakeLock, "boolean");
});
