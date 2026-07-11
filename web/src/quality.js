import { clamp, dbFromPeak } from "./utils.js";

export const VINYL_TARGETS = {
  idealPeakDBFS: -8,
  idealPeakRange: [-12, -6],
  acceptablePeakRange: [-18, -6],
  warningPeakDBFS: -3,
  rmsRange: [-24, -18],
  preferredDynamicRangeDB: 10,
  preferredNoiseFloorDBFS: -45
};

export function analyzeInputLevels(channelData, sampleRate) {
  const channels = normalizeChannels(channelData);
  const frameCount = channels[0]?.length || 0;
  const left = channels[0] || new Float32Array();
  const right = channels[1] || left;
  const mixed = mixChannels(channels);
  const peakL = peak(left);
  const peakR = peak(right);
  const peakDBFS = Math.max(dbFromPeak(peakL), dbFromPeak(peakR));
  const rmsL = rms(left);
  const rmsR = rms(right);
  const rmsDBFS = amplitudeToDBFS(rms(mixed));
  const clippingCount = countClippingFrames(channels);
  const dcOffsets = channels.map((channel) => mean(channel));
  const hum = detectHum(channels, sampleRate);
  const stereo = detectStereoBalance(channels);
  const hiss = detectHiss(channels, sampleRate);
  const maxDcOffset = dcOffsets.reduce((max, value) => Math.max(max, Math.abs(value)), 0);

  return {
    peak_dbfs: peakDBFS,
    peak_l_dbfs: dbFromPeak(peakL),
    peak_r_dbfs: dbFromPeak(peakR),
    rms_dbfs: rmsDBFS,
    rms_l_dbfs: amplitudeToDBFS(rmsL),
    rms_r_dbfs: amplitudeToDBFS(rmsR),
    short_term_average_dbfs: rmsDBFS,
    dynamic_range: peakDBFS - rmsDBFS,
    clipping_count: clippingCount,
    clipping_rate: frameCount > 0 ? clippingCount / frameCount : 0,
    dc_offset_l: dcOffsets[0] || 0,
    dc_offset_r: dcOffsets[1] || dcOffsets[0] || 0,
    max_dc_offset: maxDcOffset,
    dc_offset_detected: maxDcOffset > 0.02,
    hum_detected: hum.hum_detected,
    hum_level_dbfs: hum.hum_level_dbfs,
    hum_ratio_db: hum.hum_ratio_db,
    stereo_balance: stereo.stereo_balance,
    stereo_balance_db: stereo.stereo_balance_db,
    stereo_status: stereo.stereo_status,
    mono_detected: stereo.mono_detected,
    disconnected_channel: stereo.disconnected_channel,
    excessive_hiss: hiss.excessive_hiss,
    hiss_ratio_db: hiss.hiss_ratio_db,
    sample_rate: sampleRate || 0,
    channel_count: channels.length,
    duration_seconds: sampleRate > 0 ? frameCount / sampleRate : 0
  };
}

export function measureNoiseFloor(channelData, sampleRate) {
  const channels = normalizeChannels(channelData);
  const mixed = mixChannels(channels);
  const noiseFloor = amplitudeToDBFS(rms(mixed));
  return {
    noise_floor: noiseFloor,
    noise_floor_rating: noiseFloor < -55
      ? "Excellent"
      : noiseFloor < -45
        ? "Good"
        : noiseFloor < -35
          ? "Acceptable"
          : "Poor",
    duration_seconds: sampleRate > 0 ? (mixed.length / sampleRate) : 0
  };
}

export function detectHum(channelData, sampleRate) {
  const channels = normalizeChannels(channelData);
  const mixed = mixChannels(channels);
  if (!mixed.length || !sampleRate) {
    return { hum_detected: false, hum_level_dbfs: -120, hum_ratio_db: -120 };
  }

  const sampleCount = Math.min(mixed.length, Math.max(2048, Math.floor(sampleRate * 2)));
  const start = Math.max(0, Math.floor((mixed.length - sampleCount) / 2));
  const windowed = mixed.subarray(start, start + sampleCount);
  const totalRms = rms(windowed);
  const humAmplitude = Math.max(
    goertzelAmplitude(windowed, sampleRate, 60),
    goertzelAmplitude(windowed, sampleRate, 120) * 0.8
  );
  const humLevelDBFS = amplitudeToDBFS(humAmplitude);
  const humRatioDB = humLevelDBFS - amplitudeToDBFS(totalRms);
  return {
    hum_detected: humLevelDBFS > -55 && humRatioDB > -18,
    hum_level_dbfs: humLevelDBFS,
    hum_ratio_db: humRatioDB
  };
}

export function detectStereoBalance(channelData) {
  const channels = normalizeChannels(channelData);
  if (channels.length < 2) {
    return {
      stereo_balance: "Mono input",
      stereo_balance_db: null,
      stereo_status: "mono",
      mono_detected: true,
      disconnected_channel: null
    };
  }

  const leftRms = rms(channels[0]);
  const rightRms = rms(channels[1]);
  const leftDB = amplitudeToDBFS(leftRms);
  const rightDB = amplitudeToDBFS(rightRms);
  const diff = leftDB - rightDB;
  const absDiff = Math.abs(diff);
  const activeLeft = leftDB > -65;
  const activeRight = rightDB > -65;
  const correlation = channelCorrelation(channels[0], channels[1]);

  if (activeLeft && !activeRight) {
    return {
      stereo_balance: "Right channel disconnected",
      stereo_balance_db: diff,
      stereo_status: "disconnected",
      mono_detected: false,
      disconnected_channel: "R"
    };
  }
  if (!activeLeft && activeRight) {
    return {
      stereo_balance: "Left channel disconnected",
      stereo_balance_db: diff,
      stereo_status: "disconnected",
      mono_detected: false,
      disconnected_channel: "L"
    };
  }
  if (activeLeft && activeRight && correlation > 0.995 && absDiff < 0.5) {
    return {
      stereo_balance: "Dual mono",
      stereo_balance_db: diff,
      stereo_status: "mono",
      mono_detected: true,
      disconnected_channel: null
    };
  }
  if (absDiff > 6) {
    return {
      stereo_balance: "Severe imbalance",
      stereo_balance_db: diff,
      stereo_status: "severe_imbalance",
      mono_detected: false,
      disconnected_channel: null
    };
  }
  if (absDiff > 3) {
    return {
      stereo_balance: "Channel imbalance",
      stereo_balance_db: diff,
      stereo_status: "imbalance",
      mono_detected: false,
      disconnected_channel: null
    };
  }
  return {
    stereo_balance: "Excellent",
    stereo_balance_db: diff,
    stereo_status: "excellent",
    mono_detected: false,
    disconnected_channel: null
  };
}

export function calculateRecordingScore(stats = {}) {
  let score = 100;
  const peak = stats.peak_dbfs ?? -120;
  const rmsLevel = stats.rms_dbfs ?? -120;
  const dynamicRange = stats.dynamic_range ?? 0;
  const noiseFloor = stats.noise_floor;

  if (peak >= 0 || (stats.clipping_count ?? 0) > 0) {
    score -= 32;
  } else if (peak > -3) {
    score -= 22;
  } else if (peak > -6) {
    score -= 10;
  } else if (peak < -24) {
    score -= 24;
  } else if (peak < -18) {
    score -= 14;
  } else if (peak < -12) {
    score -= 5;
  }

  if (rmsLevel < -30 || rmsLevel > -14) {
    score -= 10;
  } else if (rmsLevel < -24 || rmsLevel > -18) {
    score -= 4;
  }

  if (dynamicRange < 6) {
    score -= 14;
  } else if (dynamicRange < VINYL_TARGETS.preferredDynamicRangeDB) {
    score -= 6;
  }

  if (typeof noiseFloor === "number") {
    if (noiseFloor > -35) score -= 18;
    else if (noiseFloor > -45) score -= 9;
    else if (noiseFloor > -55) score -= 3;
  }

  if (stats.hum_detected) score -= 10;
  if (stats.excessive_hiss) score -= 7;
  if (stats.dc_offset_detected) score -= 6;
  if (stats.stereo_status === "disconnected") score -= 20;
  else if (stats.stereo_status === "severe_imbalance") score -= 14;
  else if (stats.stereo_status === "imbalance") score -= 8;
  else if (stats.stereo_status === "mono") score -= 6;

  const overall = Math.round(clamp(score, 0, 100));
  return {
    overall,
    input_level: levelGrade(peak),
    noise_floor: noiseFloorGrade(noiseFloor),
    stereo_balance: stereoGrade(stats.stereo_status),
    clipping: (stats.clipping_count ?? 0) > 0 || peak >= 0 ? "Clipping detected" : "None"
  };
}

export function generateRecordingRecommendations(stats = {}) {
  const recommendations = [
    "For vinyl recording: record lossless WAV first, aim for peaks around -10 dBFS, avoid normalization during recording, avoid recording hotter than -6 dBFS, and preserve headroom for pops and transients."
  ];
  const peak = stats.peak_dbfs ?? -120;
  if (peak < -18) {
    const increase = Math.round((Math.pow(10, (-10 - peak) / 20) - 1) * 100 / 5) * 5;
    recommendations.push(`Input level is too low. Increase record player volume by approximately ${clamp(increase, 10, 100)}%.`);
  } else if (peak > -3 || (stats.clipping_count ?? 0) > 0) {
    recommendations.push("Input level is too high. Reduce volume and leave more headroom for record pops.");
  } else if (peak > -6) {
    recommendations.push("Input level is slightly high. Reduce volume slightly to keep peaks below -6 dBFS.");
  } else if (peak >= -12 && peak <= -6 && (stats.rms_dbfs ?? -120) >= -24 && (stats.rms_dbfs ?? -120) <= -18) {
    recommendations.push("Levels look excellent for vinyl recording.");
  }

  if (typeof stats.noise_floor === "number" && stats.noise_floor > -45) {
    recommendations.push("Surface noise is elevated. Clean record, clean stylus, reduce electrical interference, lower headphone output level, or use LINE OUT instead of headphone output.");
  }
  if (stats.hum_detected) {
    recommendations.push("60 Hz hum is visible. Move audio cables away from power adapters and check turntable grounding.");
  }
  if (stats.stereo_status === "disconnected") {
    recommendations.push(`One RCA channel may be disconnected. Check the ${stats.disconnected_channel || ""} channel cable and adapter.`);
  } else if (stats.stereo_status === "imbalance" || stats.stereo_status === "severe_imbalance") {
    recommendations.push("Stereo balance is uneven. Check RCA seating and the USB adapter input mode.");
  } else if (stats.stereo_status === "mono") {
    recommendations.push("Input appears mono or dual-mono. Use a stereo line input adapter if the record source is stereo.");
  }
  if (stats.dc_offset_detected) {
    recommendations.push("DC offset is elevated. Try a different USB audio adapter or input mode.");
  }
  if (stats.excessive_hiss) {
    recommendations.push("High-frequency hiss is elevated. Lower a noisy headphone output and prefer a fixed LINE OUT when available.");
  }
  if ((stats.dynamic_range ?? 0) < VINYL_TARGETS.preferredDynamicRangeDB) {
    recommendations.push("Dynamic range is low for vinyl. Confirm the input is not being auto-leveled by the operating system or adapter.");
  }

  return [...new Set(recommendations)];
}

export function mergeQualityStats(levelStats = {}, noiseStats = {}) {
  return {
    ...levelStats,
    ...(typeof noiseStats.noise_floor === "number" ? noiseStats : {}),
    score: calculateRecordingScore({ ...levelStats, ...noiseStats })
  };
}

export function qualityStatsFromAudioBuffer(audioBuffer, noiseFloor) {
  if (!audioBuffer) return null;
  const channels = [];
  for (let index = 0; index < audioBuffer.numberOfChannels; index += 1) {
    channels.push(audioBuffer.getChannelData(index));
  }
  const stats = analyzeInputLevels(channels, audioBuffer.sampleRate);
  if (typeof noiseFloor === "number") {
    stats.noise_floor = noiseFloor;
    stats.noise_floor_rating = measureNoiseFloor(channels, audioBuffer.sampleRate).noise_floor_rating;
  }
  stats.score = calculateRecordingScore(stats);
  stats.recommendations = generateRecordingRecommendations(stats);
  return stats;
}

function normalizeChannels(channelData) {
  const channels = Array.from(channelData || []).filter(Boolean);
  if (!channels.length) return [new Float32Array()];
  return channels;
}

function peak(samples) {
  let value = 0;
  for (let index = 0; index < samples.length; index += 1) {
    const abs = Math.abs(samples[index]);
    if (abs > value) value = abs;
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

function amplitudeToDBFS(value) {
  return dbFromPeak(Math.abs(value));
}

function mixChannels(channels) {
  const frameCount = channels[0]?.length || 0;
  const mixed = new Float32Array(frameCount);
  for (let frame = 0; frame < frameCount; frame += 1) {
    let value = 0;
    for (const channel of channels) {
      value += channel[frame] || 0;
    }
    mixed[frame] = value / channels.length;
  }
  return mixed;
}

function countClippingFrames(channels) {
  const frameCount = channels[0]?.length || 0;
  let count = 0;
  for (let frame = 0; frame < frameCount; frame += 1) {
    if (channels.some((channel) => Math.abs(channel[frame] || 0) >= 0.999)) {
      count += 1;
    }
  }
  return count;
}

function goertzelAmplitude(samples, sampleRate, frequency) {
  const coefficient = 2 * Math.cos((2 * Math.PI * frequency) / sampleRate);
  let q0 = 0;
  let q1 = 0;
  let q2 = 0;
  for (let index = 0; index < samples.length; index += 1) {
    const window = 0.5 - 0.5 * Math.cos((2 * Math.PI * index) / Math.max(samples.length - 1, 1));
    q0 = coefficient * q1 - q2 + samples[index] * window;
    q2 = q1;
    q1 = q0;
  }
  const power = q1 * q1 + q2 * q2 - coefficient * q1 * q2;
  return Math.sqrt(Math.max(power, 0)) / (samples.length / 2);
}

function channelCorrelation(left, right) {
  const count = Math.min(left.length, right.length);
  if (!count) return 0;
  let xy = 0;
  let xx = 0;
  let yy = 0;
  for (let index = 0; index < count; index += 1) {
    xy += left[index] * right[index];
    xx += left[index] * left[index];
    yy += right[index] * right[index];
  }
  if (xx === 0 || yy === 0) return 0;
  return xy / Math.sqrt(xx * yy);
}

function detectHiss(channelData, sampleRate) {
  const channels = normalizeChannels(channelData);
  const mixed = mixChannels(channels);
  if (!mixed.length || !sampleRate) {
    return { excessive_hiss: false, hiss_ratio_db: -120 };
  }
  let highSum = 0;
  for (let index = 1; index < mixed.length; index += 1) {
    const diff = mixed[index] - mixed[index - 1];
    highSum += diff * diff;
  }
  const highRms = Math.sqrt(highSum / Math.max(mixed.length - 1, 1)) / Math.SQRT2;
  const totalRms = rms(mixed);
  const ratio = amplitudeToDBFS(highRms) - amplitudeToDBFS(totalRms);
  return {
    excessive_hiss: amplitudeToDBFS(totalRms) > -45 && ratio > -10,
    hiss_ratio_db: ratio
  };
}

function levelGrade(peak) {
  if (peak >= 0) return "Clipping";
  if (peak > VINYL_TARGETS.warningPeakDBFS) return "Clipping risk";
  if (peak > -6) return "Slightly high";
  if (peak >= -12) return "Excellent";
  if (peak >= -18) return "Acceptable";
  return "Too low";
}

function noiseFloorGrade(noiseFloor) {
  if (typeof noiseFloor !== "number") return "Not measured";
  if (noiseFloor < -55) return "Excellent";
  if (noiseFloor < -45) return "Good";
  if (noiseFloor < -35) return "Acceptable";
  return "Poor";
}

function stereoGrade(status) {
  switch (status) {
    case "excellent":
      return "Excellent";
    case "imbalance":
      return "Needs attention";
    case "severe_imbalance":
    case "disconnected":
      return "Problem detected";
    case "mono":
      return "Mono";
    default:
      return "Not measured";
  }
}
