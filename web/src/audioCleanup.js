import { clamp, dbFromPeak } from "./utils.js";

const CLICK_DELTA_THRESHOLD = 0.12;
const CLICK_NEIGHBOR_THRESHOLD = 0.16;
const CLICK_LOCAL_MOTION_RATIO = 0.55;

export function defaultImportCleanupOptions() {
  return {
    applyCleanup: true,
    preset: "standard",
    removeDCOffset: true,
    highPassRumble: true,
    highPassFrequency: 28,
    balanceChannels: true,
    gentleDeClick: false,
    normalizePeaks: false,
    normalizeTargetDBFS: -1
  };
}

export function cleanupOptionsForPreset(preset) {
  const base = defaultImportCleanupOptions();
  switch (preset) {
    case "off":
      return {
        ...base,
        applyCleanup: false,
        preset,
        removeDCOffset: false,
        highPassRumble: false,
        balanceChannels: false,
        gentleDeClick: false,
        normalizePeaks: false
      };
    case "gentle":
      return {
        ...base,
        preset,
        gentleDeClick: false,
        normalizePeaks: false
      };
    case "restore":
      return {
        ...base,
        preset,
        gentleDeClick: true,
        normalizePeaks: false
      };
    case "standard":
    default:
      return {
        ...base,
        preset: "standard",
        gentleDeClick: true,
        normalizePeaks: false
      };
  }
}

export function analyzeImportAudioBuffer(audioBuffer) {
  return analyzeImportChannelData(channelDataFromAudioBuffer(audioBuffer), audioBuffer.sampleRate);
}

export function analyzeImportChannelData(channelData, sampleRate) {
  const channels = normalizeChannels(channelData);
  const peaks = channels.map(peak);
  const rmsValues = channels.map(rms);
  const dcOffsets = channels.map(mean);
  const peakDBFS = dbFromPeak(Math.max(...peaks, 0));
  const rmsDBFS = dbFromPeak(rms(mixChannels(channels)));
  const balanceDB = channels.length >= 2
    ? dbFromPeak(rmsValues[0]) - dbFromPeak(rmsValues[1])
    : null;
  const maxDCOffset = dcOffsets.reduce((max, value) => Math.max(max, Math.abs(value)), 0);
  const clickCandidates = detectClickPopCandidates(channels);
  const noiseProfile = estimateSurfaceNoiseProfile(channels, sampleRate);
  const analysis = {
    sample_rate: sampleRate,
    channel_count: channels.length,
    peak_dbfs: peakDBFS,
    rms_dbfs: rmsDBFS,
    dynamic_range: peakDBFS - rmsDBFS,
    dc_offset: maxDCOffset,
    dc_offset_detected: maxDCOffset > 0.01,
    stereo_balance_db: balanceDB,
    channel_imbalance_detected: typeof balanceDB === "number" && Math.abs(balanceDB) > 1.5,
    click_pop_candidates: clickCandidates,
    noise_floor_dbfs: noiseProfile.noise_floor_dbfs,
    noise_floor_rating: noiseProfile.noise_floor_rating,
    rumble_filter_recommended: true
  };
  return {
    ...analysis,
    recommendations: generateImportOptimizationRecommendations(analysis)
  };
}

export function generateImportOptimizationRecommendations(analysis = {}) {
  const recommendations = [];
  if (analysis.dc_offset_detected) {
    recommendations.push("Remove DC offset");
  }
  if (analysis.rumble_filter_recommended) {
    recommendations.push("Apply 28 Hz rumble filter");
  }
  if (analysis.channel_imbalance_detected) {
    recommendations.push("Balance stereo channels");
  }
  if ((analysis.click_pop_candidates || 0) > 0) {
    recommendations.push("Try gentle de-click");
  }
  if (typeof analysis.noise_floor_dbfs === "number" && analysis.noise_floor_dbfs > -45) {
    recommendations.push("Use a cleaned source if surface noise is distracting");
  }
  if (!recommendations.length) {
    recommendations.push("No cleanup needed beyond edge fades");
  }
  return recommendations;
}

export function estimateSurfaceNoiseProfile(channelData, sampleRate) {
  const mixed = mixChannels(normalizeChannels(channelData));
  if (!mixed.length || !sampleRate) {
    return {
      noise_floor_dbfs: -120,
      noise_floor_rating: "Not measured"
    };
  }
  const windowFrames = Math.max(1, Math.floor(sampleRate));
  const stepFrames = Math.max(1, Math.floor(sampleRate / 2));
  let quietest = Infinity;
  for (let start = 0; start < mixed.length; start += stepFrames) {
    const end = Math.min(start + windowFrames, mixed.length);
    if (end - start < windowFrames * 0.4) continue;
    const value = rms(mixed.subarray(start, end));
    if (value < quietest) quietest = value;
  }
  const noiseFloor = Number.isFinite(quietest) ? dbFromPeak(quietest) : -120;
  return {
    noise_floor_dbfs: noiseFloor,
    noise_floor_rating: noiseFloor < -55
      ? "Excellent"
      : noiseFloor < -45
        ? "Good"
        : noiseFloor < -35
          ? "Acceptable"
          : "Poor"
  };
}

export function applyImportCleanupToAudioBuffer(audioBuffer, options = defaultImportCleanupOptions()) {
  const before = analyzeImportAudioBuffer(audioBuffer);
  const cleaned = optimizeImportChannelData(
    channelDataFromAudioBuffer(audioBuffer),
    audioBuffer.sampleRate,
    options
  );
  const cleanedBuffer = audioBufferFromChannelData(cleaned.channels, audioBuffer.sampleRate);
  const after = analyzeImportAudioBuffer(cleanedBuffer);
  return {
    audioBuffer: cleanedBuffer,
    metadata: {
      options: { ...options },
      applied: cleaned.applied,
      click_repairs: cleaned.clickRepairs,
      analysis_before: before,
      analysis_after: after
    }
  };
}

export function optimizeImportChannelData(channelData, sampleRate, options = defaultImportCleanupOptions()) {
  const mergedOptions = { ...defaultImportCleanupOptions(), ...options };
  const channels = normalizeChannels(channelData).map((channel) => new Float32Array(channel));
  const applied = [];
  let clickRepairs = 0;

  if (mergedOptions.removeDCOffset) {
    channels.forEach(removeDCOffset);
    applied.push("Remove DC offset");
  }

  if (mergedOptions.highPassRumble) {
    channels.forEach((channel) => highPassFilter(channel, sampleRate, mergedOptions.highPassFrequency));
    applied.push(`${Math.round(mergedOptions.highPassFrequency)} Hz rumble filter`);
  }

  if (mergedOptions.balanceChannels && channels.length >= 2) {
    const balanced = balanceStereoChannels(channels);
    if (balanced) {
      applied.push("Stereo balance correction");
    }
  }

  if (mergedOptions.gentleDeClick) {
    clickRepairs = channels.reduce((sum, channel) => sum + gentleDeClick(channel), 0);
    applied.push("Gentle de-click");
  }

  if (mergedOptions.normalizePeaks) {
    const gain = normalizationGain(channels, mergedOptions.normalizeTargetDBFS);
    channels.forEach((channel) => applyGain(channel, gain));
    applied.push(`Peak normalize to ${mergedOptions.normalizeTargetDBFS} dBFS`);
  }

  channels.forEach(limitSamples);
  return {
    channels,
    applied,
    clickRepairs
  };
}

export function detectClickPopCandidates(channelData) {
  const channels = normalizeChannels(channelData);
  let count = 0;
  for (const channel of channels) {
    for (let index = 2; index < channel.length - 2; index += 1) {
      if (clickCandidateAt(channel, index)) {
        count += 1;
      }
    }
  }
  return count;
}

function channelDataFromAudioBuffer(audioBuffer) {
  const channels = [];
  for (let index = 0; index < audioBuffer.numberOfChannels; index += 1) {
    channels.push(audioBuffer.getChannelData(index));
  }
  return channels;
}

function audioBufferFromChannelData(channelData, sampleRate) {
  const channels = normalizeChannels(channelData);
  const audioBuffer = new AudioBuffer({
    length: channels[0].length,
    numberOfChannels: channels.length,
    sampleRate
  });
  channels.forEach((channel, index) => {
    audioBuffer.copyToChannel(channel, index);
  });
  return audioBuffer;
}

function normalizeChannels(channelData) {
  const channels = Array.from(channelData || []).filter(Boolean);
  if (!channels.length) return [new Float32Array()];
  return channels;
}

function removeDCOffset(channel) {
  const offset = mean(channel);
  for (let index = 0; index < channel.length; index += 1) {
    channel[index] -= offset;
  }
}

function highPassFilter(channel, sampleRate, cutoffHz) {
  if (!sampleRate || !cutoffHz) return;
  const rc = 1 / (2 * Math.PI * cutoffHz);
  const dt = 1 / sampleRate;
  const alpha = rc / (rc + dt);
  let previousInput = channel[0] || 0;
  let previousOutput = 0;
  for (let index = 0; index < channel.length; index += 1) {
    const input = channel[index];
    const output = alpha * (previousOutput + input - previousInput);
    channel[index] = output;
    previousInput = input;
    previousOutput = output;
  }
}

function balanceStereoChannels(channels) {
  const leftRms = rms(channels[0]);
  const rightRms = rms(channels[1]);
  if (leftRms <= 0 || rightRms <= 0) return false;
  const leftDB = dbFromPeak(leftRms);
  const rightDB = dbFromPeak(rightRms);
  const diff = leftDB - rightDB;
  if (Math.abs(diff) < 1 || Math.abs(diff) > 9) return false;
  const target = (leftRms + rightRms) / 2;
  applyGain(channels[0], clamp(target / leftRms, 0.5, 2.0));
  applyGain(channels[1], clamp(target / rightRms, 0.5, 2.0));
  return true;
}

function gentleDeClick(channel) {
  let repairs = 0;
  for (let index = 2; index < channel.length - 2; index += 1) {
    if (clickCandidateAt(channel, index)) {
      const local = localClickReplacement(channel, index);
      channel[index] = local;
      repairs += 1;
    }
  }
  return repairs;
}

function clickCandidateAt(channel, index) {
  const local = localClickReplacement(channel, index);
  const delta = Math.abs(channel[index] - local);
  if (delta < CLICK_DELTA_THRESHOLD) return false;

  const neighborDelta = Math.abs(channel[index - 1] - channel[index + 1]);
  if (neighborDelta > CLICK_NEIGHBOR_THRESHOLD && neighborDelta > delta * 0.75) return false;

  const localMotion = (
    Math.abs(channel[index - 2] - channel[index - 1]) +
    Math.abs(channel[index - 1] - channel[index + 1]) +
    Math.abs(channel[index + 1] - channel[index + 2])
  ) / 3;
  return localMotion <= delta * CLICK_LOCAL_MOTION_RATIO;
}

function localClickReplacement(channel, index) {
  return (channel[index - 2] + channel[index - 1] + channel[index + 1] + channel[index + 2]) / 4;
}

function normalizationGain(channels, targetDBFS) {
  const currentPeak = Math.max(...channels.map(peak), 0);
  if (currentPeak <= 0) return 1;
  const target = Math.pow(10, targetDBFS / 20);
  return clamp(target / currentPeak, 0.1, Math.pow(10, 12 / 20));
}

function applyGain(channel, gain) {
  for (let index = 0; index < channel.length; index += 1) {
    channel[index] *= gain;
  }
}

function limitSamples(channel) {
  for (let index = 0; index < channel.length; index += 1) {
    channel[index] = clamp(channel[index], -1, 1);
  }
}

function mixChannels(channels) {
  const mixed = new Float32Array(channels[0]?.length || 0);
  for (let frame = 0; frame < mixed.length; frame += 1) {
    let value = 0;
    channels.forEach((channel) => {
      value += channel[frame] || 0;
    });
    mixed[frame] = value / channels.length;
  }
  return mixed;
}

function peak(samples) {
  let value = 0;
  for (let index = 0; index < samples.length; index += 1) {
    value = Math.max(value, Math.abs(samples[index]));
  }
  return value;
}

function rms(samples) {
  if (!samples.length) return 0;
  let sum = 0;
  for (let index = 0; index < samples.length; index += 1) {
    sum += samples[index] * samples[index];
  }
  return Math.sqrt(sum / samples.length);
}

function mean(samples) {
  if (!samples.length) return 0;
  let sum = 0;
  for (let index = 0; index < samples.length; index += 1) {
    sum += samples[index];
  }
  return sum / samples.length;
}
