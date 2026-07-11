import test from "node:test";
import assert from "node:assert/strict";
import {
  analyzeInputLevels,
  calculateRecordingScore,
  detectHum,
  detectStereoBalance,
  generateRecordingRecommendations,
  measureNoiseFloor
} from "../src/quality.js";

test("analyzeInputLevels reports peak, RMS, clipping, and dynamic range", () => {
  const sampleRate = 48000;
  const left = sine(sampleRate, 440, 1, 0.5);
  const right = sine(sampleRate, 440, 1, 0.25);
  left[100] = 1;
  const stats = analyzeInputLevels([left, right], sampleRate);

  assert.ok(stats.peak_dbfs > -0.1);
  assert.ok(stats.rms_dbfs < -7 && stats.rms_dbfs > -13);
  assert.ok(stats.dynamic_range > 7);
  assert.equal(stats.clipping_count, 1);
});

test("measureNoiseFloor classifies quiet surface noise", () => {
  const quiet = constantNoise(48000, 0.004);
  const result = measureNoiseFloor([quiet, quiet], 48000);

  assert.equal(result.noise_floor_rating, "Good");
  assert.ok(result.noise_floor > -55 && result.noise_floor < -45);
});

test("detectHum identifies strong 60 Hz content", () => {
  const sampleRate = 48000;
  const hum = sine(sampleRate, 60, 2, 0.08);
  const result = detectHum([hum, hum], sampleRate);

  assert.equal(result.hum_detected, true);
  assert.ok(result.hum_level_dbfs > -35);
});

test("detectStereoBalance warns on disconnected channel", () => {
  const left = sine(48000, 440, 1, 0.25);
  const right = new Float32Array(left.length);
  const result = detectStereoBalance([left, right]);

  assert.equal(result.stereo_status, "disconnected");
  assert.equal(result.disconnected_channel, "R");
});

test("calculateRecordingScore rewards vinyl-friendly levels", () => {
  const score = calculateRecordingScore({
    peak_dbfs: -8,
    rms_dbfs: -21,
    dynamic_range: 13,
    noise_floor: -50,
    clipping_count: 0,
    stereo_status: "excellent"
  });

  assert.ok(score.overall >= 90);
  assert.equal(score.input_level, "Excellent");
  assert.equal(score.clipping, "None");
});

test("generateRecordingRecommendations suggests gain changes", () => {
  const recommendations = generateRecordingRecommendations({
    peak_dbfs: -24,
    rms_dbfs: -32,
    dynamic_range: 8,
    noise_floor: -34,
    stereo_status: "imbalance"
  });

  assert.ok(recommendations.some((text) => text.includes("Input level is too low")));
  assert.ok(recommendations.some((text) => text.includes("Surface noise is elevated")));
});

function sine(sampleRate, frequency, seconds, amplitude) {
  const samples = new Float32Array(sampleRate * seconds);
  for (let index = 0; index < samples.length; index += 1) {
    samples[index] = Math.sin((2 * Math.PI * frequency * index) / sampleRate) * amplitude;
  }
  return samples;
}

function constantNoise(sampleRate, amplitude) {
  const samples = new Float32Array(sampleRate);
  for (let index = 0; index < samples.length; index += 1) {
    samples[index] = amplitude * (index % 2 === 0 ? 1 : -1);
  }
  return samples;
}
