import test from "node:test";
import assert from "node:assert/strict";
import {
  analyzeImportChannelData,
  cleanupOptionsForPreset,
  detectClickPopCandidates,
  estimateSurfaceNoiseProfile,
  optimizeImportChannelData
} from "../src/audioCleanup.js";

test("import cleanup removes DC offset", () => {
  const samples = new Float32Array(48000).fill(0.12);
  const result = optimizeImportChannelData([samples], 48000, {
    removeDCOffset: true,
    highPassRumble: false,
    balanceChannels: false,
    gentleDeClick: false,
    normalizePeaks: false
  });
  const analysis = analyzeImportChannelData(result.channels, 48000);

  assert.ok(analysis.dc_offset < 0.001);
  assert.ok(result.applied.includes("Remove DC offset"));
});

test("import cleanup reduces low-frequency rumble", () => {
  const rumble = sine(48000, 10, 1, 0.5);
  const before = rms(rumble);
  const result = optimizeImportChannelData([rumble], 48000, {
    removeDCOffset: false,
    highPassRumble: true,
    highPassFrequency: 28,
    balanceChannels: false,
    gentleDeClick: false,
    normalizePeaks: false
  });
  const after = rms(result.channels[0]);

  assert.ok(after < before * 0.55);
});

test("import cleanup balances uneven stereo channels", () => {
  const left = sine(48000, 440, 1, 0.5);
  const right = sine(48000, 440, 1, 0.18);
  const result = optimizeImportChannelData([left, right], 48000, {
    removeDCOffset: false,
    highPassRumble: false,
    balanceChannels: true,
    gentleDeClick: false,
    normalizePeaks: false
  });
  const analysis = analyzeImportChannelData(result.channels, 48000);

  assert.ok(Math.abs(analysis.stereo_balance_db) < 1.5);
  assert.ok(result.applied.includes("Stereo balance correction"));
});

test("gentle de-click repairs isolated spikes", () => {
  const samples = sine(48000, 440, 1, 0.1);
  samples[1000] = 0.9;
  const result = optimizeImportChannelData([samples], 48000, {
    removeDCOffset: false,
    highPassRumble: false,
    balanceChannels: false,
    gentleDeClick: true,
    normalizePeaks: false
  });

  assert.equal(result.clickRepairs, 1);
  assert.ok(Math.abs(result.channels[0][1000]) < 0.2);
});

test("import analysis reports click candidates and recommendations", () => {
  const samples = sine(48000, 440, 1, 0.08);
  samples[1200] = 0.95;
  assert.equal(detectClickPopCandidates([samples]), 1);
  const analysis = analyzeImportChannelData([samples], 48000);

  assert.ok(analysis.click_pop_candidates >= 1);
  assert.ok(analysis.recommendations.some((item) => item.includes("de-click")));
});

test("surface noise profile rates quiet windows", () => {
  const noisy = new Float32Array(48000 * 2);
  for (let index = 0; index < noisy.length; index += 1) {
    noisy[index] = index < 48000 ? 0.003 : 0.08 * Math.sin(index / 20);
  }
  const profile = estimateSurfaceNoiseProfile([noisy], 48000);

  assert.equal(profile.noise_floor_rating, "Good");
  assert.ok(profile.noise_floor_dbfs > -55 && profile.noise_floor_dbfs < -45);
});

test("cleanup presets map to expected options", () => {
  assert.equal(cleanupOptionsForPreset("off").applyCleanup, false);
  assert.equal(cleanupOptionsForPreset("standard").gentleDeClick, true);
  assert.equal(cleanupOptionsForPreset("restore").gentleDeClick, true);
});

function sine(sampleRate, frequency, seconds, amplitude) {
  const samples = new Float32Array(sampleRate * seconds);
  for (let index = 0; index < samples.length; index += 1) {
    samples[index] = Math.sin((2 * Math.PI * frequency * index) / sampleRate) * amplitude;
  }
  return samples;
}

function rms(samples) {
  let sum = 0;
  for (let index = 0; index < samples.length; index += 1) {
    sum += samples[index] * samples[index];
  }
  return Math.sqrt(sum / samples.length);
}
