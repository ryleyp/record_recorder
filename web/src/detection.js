import { clamp } from "./utils.js";

export const DETECTION_PRESETS = {
  conservative: {
    preset: "conservative",
    silenceThresholdDB: -45,
    minimumGapSeconds: 2.5,
    minimumTrackSeconds: 45,
    minimumScore: 0.62
  },
  balanced: {
    preset: "balanced",
    silenceThresholdDB: -40,
    minimumGapSeconds: 1.5,
    minimumTrackSeconds: 30,
    minimumScore: 0.48
  },
  aggressive: {
    preset: "aggressive",
    silenceThresholdDB: -35,
    minimumGapSeconds: 1,
    minimumTrackSeconds: 25,
    minimumScore: 0.34
  }
};

export function defaultDetectionSettings() {
  return { ...DETECTION_PRESETS.balanced };
}

export function computeEnvelopeFromAudioBuffer(audioBuffer, hopSeconds = 0.05) {
  const hopFrames = Math.max(1, Math.floor(audioBuffer.sampleRate * hopSeconds));
  const channels = [];
  for (let channel = 0; channel < audioBuffer.numberOfChannels; channel += 1) {
    channels.push(audioBuffer.getChannelData(channel));
  }

  const valuesDB = [];
  for (let index = 0; index < audioBuffer.length; index += hopFrames) {
    const end = Math.min(index + hopFrames, audioBuffer.length);
    let sum = 0;
    for (let frame = index; frame < end; frame += 1) {
      let sample = 0;
      for (const channelData of channels) {
        sample += channelData[frame] || 0;
      }
      sample /= Math.max(channels.length, 1);
      sum += sample * sample;
    }
    const mean = sum / Math.max(end - index, 1);
    const rms = Math.sqrt(mean);
    valuesDB.push(rms <= 0 ? -120 : Math.max(-120, 20 * Math.log10(rms)));
  }
  return {
    hopSeconds,
    valuesDB,
    duration: valuesDB.length * hopSeconds
  };
}

export function computePeaksFromAudioBuffer(audioBuffer, bucketCount = 2400) {
  const count = Math.max(1, Math.min(bucketCount, audioBuffer.length));
  const framesPerBucket = Math.max(1, Math.ceil(audioBuffer.length / count));
  const channels = [];
  for (let channel = 0; channel < audioBuffer.numberOfChannels; channel += 1) {
    channels.push(audioBuffer.getChannelData(channel));
  }

  const peaks = [];
  for (let bucket = 0; bucket < count; bucket += 1) {
    const start = bucket * framesPerBucket;
    const end = Math.min(start + framesPerBucket, audioBuffer.length);
    let min = 0;
    let max = 0;
    for (let frame = start; frame < end; frame += 1) {
      let sample = 0;
      for (const channelData of channels) {
        sample += channelData[frame] || 0;
      }
      sample /= Math.max(channels.length, 1);
      if (sample < min) min = sample;
      if (sample > max) max = sample;
    }
    peaks.push({ min, max });
  }
  return peaks;
}

export function detectTracks(envelope, settings = defaultDetectionSettings()) {
  const values = Array.from(envelope.valuesDB, Number);
  const hop = Number(envelope.hopSeconds) || 0.05;
  const duration = Number(envelope.duration) || values.length * hop;
  if (values.length <= 4) {
    return {
      boundaries: [],
      candidateGaps: [],
      suggestedTrimStart: 0,
      suggestedTrimEnd: duration,
      effectiveThresholdDB: settings.silenceThresholdDB
    };
  }

  const sorted = [...values].sort((a, b) => a - b);
  const noiseFloor = percentile(sorted, 0.05);
  const musicLevel = percentile(sorted, 0.85);

  const quietRuns = (threshold) => {
    const runs = [];
    let runStart = null;
    values.forEach((level, index) => {
      if (level < threshold) {
        if (runStart === null) runStart = index;
      } else if (runStart !== null) {
        runs.push({ start: runStart, end: index });
        runStart = null;
      }
    });
    if (runStart !== null) {
      runs.push({ start: runStart, end: values.length });
    }

    let trimStart = 0;
    let trimEnd = duration;
    if (runs.length && runs[0].start === 0 && (runs[0].end - runs[0].start) * hop >= 0.5) {
      trimStart = runs[0].end * hop;
      runs.shift();
    }
    const last = runs[runs.length - 1];
    if (last && last.end === values.length && (last.end - last.start) * hop >= 0.5) {
      trimEnd = last.start * hop;
      runs.pop();
    }
    return { runs, trimStart, trimEnd };
  };

  let threshold = Math.min(settings.silenceThresholdDB, musicLevel - 12, -20);
  let runResult = quietRuns(threshold);
  const hasUsableGap = runResult.runs.some(
    (run) => (run.end - run.start) * hop >= settings.minimumGapSeconds * 0.5
  );
  if (!hasUsableGap) {
    const adaptive = Math.min(
      Math.max(settings.silenceThresholdDB, noiseFloor + 8),
      musicLevel - 12,
      -20
    );
    if (adaptive > threshold + 0.5) {
      threshold = adaptive;
      runResult = quietRuns(threshold);
    }
  }

  const maximumGapSeconds = 15;
  const contextHops = Math.max(1, Math.floor(5 / hop));
  const gaps = [];

  for (const run of runResult.runs) {
    const gapLength = (run.end - run.start) * hop;
    if (
      gapLength < settings.minimumGapSeconds * 0.5 ||
      gapLength > maximumGapSeconds
    ) {
      continue;
    }

    const gapValues = values.slice(run.start, run.end);
    const quietHalf = [...gapValues]
      .sort((a, b) => a - b)
      .slice(0, Math.max(1, Math.floor(gapValues.length / 2)));
    const gapLevel = mean(quietHalf);

    const beforeStart = Math.max(0, run.start - contextHops);
    const beforeValues = values.slice(beforeStart, run.start);
    const afterValues = values.slice(run.end, Math.min(values.length, run.end + contextHops));
    const beforeLevel = beforeValues.length ? mean(beforeValues) : musicLevel;
    const afterLevel = afterValues.length ? mean(afterValues) : musicLevel;
    const surroundLevel = (beforeLevel + afterLevel) / 2;

    const durationScore = Math.min(gapLength / settings.minimumGapSeconds, 2) / 2;
    const depthScore = clamp((surroundLevel - gapLevel) / 25, 0, 1);
    const edgeValues = values.slice(run.end, Math.min(values.length, run.end + Math.max(1, Math.floor(1.5 / hop))));
    const edgeLevel = edgeValues.length ? mean(edgeValues) : afterLevel;
    const edgeScore = clamp((edgeLevel - gapLevel) / 30, 0, 1);
    const score = 0.4 * durationScore + 0.35 * depthScore + 0.25 * edgeScore;

    let quietestIndex = run.start;
    let quietestLevel = Infinity;
    for (let index = run.start; index < run.end; index += 1) {
      if (values[index] < quietestLevel) {
        quietestLevel = values[index];
        quietestIndex = index;
      }
    }

    gaps.push({
      startTime: run.start * hop,
      endTime: run.end * hop,
      cutTime: (quietestIndex + 0.5) * hop,
      meanLevelDB: gapLevel,
      score,
      duration: gapLength
    });
  }

  let accepted = gaps
    .filter((gap) => gap.duration >= settings.minimumGapSeconds && gap.score >= settings.minimumScore)
    .sort((a, b) => a.cutTime - b.cutTime);

  while (accepted.length) {
    const cutPoints = [
      runResult.trimStart,
      ...accepted.map((gap) => gap.cutTime),
      runResult.trimEnd
    ].sort((a, b) => a - b);
    let shortSegmentIndex = null;
    for (let index = 0; index < cutPoints.length - 1; index += 1) {
      if (cutPoints[index + 1] - cutPoints[index] < settings.minimumTrackSeconds) {
        shortSegmentIndex = index;
        break;
      }
    }
    if (shortSegmentIndex === null) break;

    const leftBoundary = shortSegmentIndex - 1;
    const rightBoundary = shortSegmentIndex;
    let removeIndex;
    if (leftBoundary < 0) {
      removeIndex = rightBoundary;
    } else if (rightBoundary >= accepted.length) {
      removeIndex = leftBoundary;
    } else {
      removeIndex = accepted[leftBoundary].score <= accepted[rightBoundary].score
        ? leftBoundary
        : rightBoundary;
    }
    if (removeIndex < 0 || removeIndex >= accepted.length) break;
    accepted.splice(removeIndex, 1);
  }

  return {
    boundaries: accepted.map((gap) => gap.cutTime),
    candidateGaps: gaps,
    suggestedTrimStart: runResult.trimStart,
    suggestedTrimEnd: runResult.trimEnd,
    effectiveThresholdDB: threshold
  };
}

export function parseTracklist(text) {
  const result = {
    entries: [],
    albumTitle: "",
    albumArtist: "",
    year: null
  };

  for (const rawLine of String(text || "").split(/\r?\n/)) {
    const line = rawLine.trim();
    if (!line) continue;

    const artist = headerValue(line, ["artist", "album artist"]);
    if (artist) {
      result.albumArtist = artist;
      continue;
    }
    const album = headerValue(line, ["album", "album title", "title"]);
    if (album) {
      result.albumTitle = album;
      continue;
    }
    const year = headerValue(line, ["year"]);
    if (year && /^\d{4}$/.test(year)) {
      result.year = Number(year);
      continue;
    }

    let working = line;
    let duration = null;
    const durationMatch = working.match(/[\s\-\u2013\u2014(\[]*((?:\d{1,2}:)?\d{1,2}:\d{2})[\)\]]?\s*$/);
    if (durationMatch) {
      duration = secondsFromTimestamp(durationMatch[1]);
      working = working.slice(0, durationMatch.index);
    }

    working = working.replace(/^(?:[AB])?\d{1,3}[\.):\-]?\s+|^(?:[AB])?\d{1,3}\s*[\-\u2013\u2014.]\s*/i, "");
    const title = working.replace(/^[\s\-\u2013\u2014]+|[\s\-\u2013\u2014]+$/g, "");
    if (title) {
      result.entries.push({ title, duration });
    }
  }

  return result;
}

export function secondsFromTimestamp(token) {
  const parts = String(token || "").split(":");
  if (parts.length !== 2 && parts.length !== 3) return null;
  if (!parts.every((part) => /^\d+$/.test(part))) return null;
  const numbers = parts.map(Number);
  if (numbers.some((value) => !Number.isFinite(value))) return null;
  if (numbers.length === 2) {
    if (numbers[1] >= 60) return null;
    return numbers[0] * 60 + numbers[1];
  }
  if (numbers[1] >= 60 || numbers[2] >= 60) return null;
  return numbers[0] * 3600 + numbers[1] * 60 + numbers[2];
}

export function alignTracklist(entries, detection) {
  return alignTracklistDetailed(entries, detection).boundaries;
}

export function alignTracklistDetailed(entries, detection, options = {}) {
  const count = entries.length;
  if (count < 2) {
    return {
      boundaries: [],
      alignments: [],
      mode: "none",
      summary: "Need at least two tracks to place splits."
    };
  }
  const start = detection.suggestedTrimStart || 0;
  const end = detection.suggestedTrimEnd || 0;
  if (end <= start) {
    return {
      boundaries: [],
      alignments: [],
      mode: "none",
      summary: "Could not measure the usable side length."
    };
  }

  const allRuntimes = entries.every((entry) => entry.duration != null);
  if (allRuntimes) {
    return alignWithRuntimes(entries, detection, options);
  }

  const cuts = [...(detection.candidateGaps || [])]
    .sort((a, b) => b.score - a.score)
    .slice(0, count - 1)
    .map((gap) => gap.cutTime)
    .sort((a, b) => a - b);

  while (cuts.length < count - 1) {
    const points = [start, ...cuts, end].sort((a, b) => a - b);
    let longestIndex = 0;
    let longestLength = 0;
    for (let index = 0; index < points.length - 1; index += 1) {
      const length = points[index + 1] - points[index];
      if (length > longestLength) {
        longestLength = length;
        longestIndex = index;
      }
    }
    cuts.push((points[longestIndex] + points[longestIndex + 1]) / 2);
    cuts.sort((a, b) => a - b);
  }
  return {
    boundaries: cuts,
    alignments: cuts.map((cutTime, index) => ({
      trackIndex: index,
      expectedTime: null,
      cutTime,
      source: "silence",
      confidence: "medium",
      confidenceScore: 0.6,
      distanceSeconds: null,
      gapScore: null,
      note: "No runtime available; split selected from the strongest detected quiet gaps."
    })),
    mode: "silence",
    summary: `Placed ${cuts.length} splits from detected quiet gaps.`
  };
}

export function parseAudacityLabels(text) {
  const labels = [];
  for (const rawLine of String(text || "").split(/\r?\n/)) {
    const line = rawLine.trim();
    if (!line || line.startsWith("\\")) continue;
    const fields = line.split("\t");
    if (fields.length < 2) continue;
    const start = Number(fields[0].trim());
    const end = Number(fields[1].trim());
    if (!Number.isFinite(start) || !Number.isFinite(end)) continue;
    labels.push({
      start,
      end: Math.max(start, end),
      title: fields.length >= 3 ? fields[2].trim() : ""
    });
  }
  return labels.sort((a, b) => a.start - b.start);
}

export function applyAudacityLabels(labels, duration) {
  const valid = labels.filter((label) => label.start >= 0 && label.start <= duration);
  if (!valid.length) return null;

  const regions = valid.filter((label) => label.end > label.start + 0.05);
  if (regions.length === valid.length && regions.length) {
    return {
      boundaries: regions.slice(1).map((label) => label.start),
      trimStart: regions[0].start,
      trimEnd: Math.min(regions[regions.length - 1].end, duration),
      titles: regions.map((label) => label.title)
    };
  }

  let trimStart = 0;
  let trimEnd = duration;
  const cuts = valid.map((label) => label.start);
  if (cuts[0] < 2) {
    trimStart = cuts.shift();
  }
  if (cuts[cuts.length - 1] > duration - 2) {
    trimEnd = cuts.pop();
  }
  return {
    boundaries: cuts,
    trimStart,
    trimEnd,
    titles: valid.map((label) => label.title).filter(Boolean)
  };
}

function alignWithRuntimes(entries, detection, options = {}) {
  const start = detection.suggestedTrimStart || 0;
  const end = detection.suggestedTrimEnd || 0;
  const musicLength = end - start;
  const totalRuntime = entries.reduce((sum, entry) => sum + (entry.duration || 0), 0);
  if (totalRuntime <= 0) {
    return {
      boundaries: [],
      alignments: [],
      mode: "runtime",
      summary: "Track runtimes were not usable."
    };
  }

  const scale = clamp(musicLength / totalRuntime, 0.85, 1.15);
  const expectedDurations = entries.map((entry) => (entry.duration || 0) * scale);
  const medianDuration = median(expectedDurations);
  const windowSeconds = options.windowSeconds ?? clamp(
    Math.max(8, musicLength * 0.03, medianDuration * 0.12),
    8,
    35
  );
  const candidateGaps = [...(detection.candidateGaps || [])]
    .filter((gap) => gap.cutTime > start + 0.5 && gap.cutTime < end - 0.5)
    .sort((a, b) => a.cutTime - b.cutTime);
  const expectedCuts = [];
  let cumulative = start;
  for (const duration of expectedDurations.slice(0, -1)) {
    cumulative += duration;
    expectedCuts.push(clamp(cumulative, start + 1, end - 1));
  }

  const candidatesByCut = expectedCuts.map((expected, index) => {
    const candidates = candidateGaps
      .map((gap) => runtimeCandidateFromGap(gap, expected, windowSeconds))
      .filter(Boolean);
    candidates.push({
      time: expected,
      expectedTime: expected,
      source: "runtime",
      gap: null,
      gapIndex: -1,
      silenceScore: 0.25,
      distanceScore: 1,
      distanceSeconds: 0,
      baseScore: 0.42
    });
    return dedupeCandidates(candidates)
      .filter((candidate) => candidate.time > start && candidate.time < end)
      .sort((a, b) => a.time - b.time || b.baseScore - a.baseScore)
      .map((candidate) => ({ ...candidate, cutIndex: index }));
  });

  const chosen = chooseRuntimeCandidates(candidatesByCut, expectedDurations, start, end);
  const boundaries = chosen.map((candidate) => candidate.time).sort((a, b) => a - b);
  const alignments = chosen.map((candidate, index) => {
    const previousTime = index === 0 ? start : chosen[index - 1].time;
    const nextTime = index === chosen.length - 1 ? end : chosen[index + 1].time;
    const leftDurationScore = segmentDurationScore(candidate.time - previousTime, expectedDurations[index]);
    const rightDurationScore = segmentDurationScore(nextTime - candidate.time, expectedDurations[index + 1]);
    const confidenceScore = confidenceForCandidate(candidate, leftDurationScore, rightDurationScore);
    const confidence = confidenceLabel(confidenceScore, candidate.source);
    return {
      trackIndex: index,
      expectedTime: candidate.expectedTime,
      cutTime: candidate.time,
      gapStartTime: candidate.gap?.startTime ?? null,
      gapEndTime: candidate.gap?.endTime ?? null,
      source: candidate.source,
      confidence,
      confidenceScore,
      distanceSeconds: candidate.distanceSeconds,
      gapScore: candidate.gap?.score ?? null,
      note: runtimeAlignmentNote(candidate, confidence, windowSeconds)
    };
  });
  const high = alignments.filter((alignment) => alignment.confidence === "high").length;
  const medium = alignments.filter((alignment) => alignment.confidence === "medium").length;
  const low = alignments.filter((alignment) => alignment.confidence === "low").length;
  return {
    boundaries,
    alignments,
    mode: "runtime",
    scale,
    searchWindowSeconds: windowSeconds,
    summary: `Runtime-guided split: ${high} high, ${medium} medium, ${low} low confidence.`
  };
}

function runtimeCandidateFromGap(gap, expectedTime, windowSeconds) {
  const distance = Math.abs(gap.cutTime - expectedTime);
  if (distance > windowSeconds) return null;
  const distanceScore = clamp(1 - distance / windowSeconds, 0, 1);
  const silenceScore = clamp(gap.score ?? 0, 0, 1);
  return {
    time: gap.cutTime,
    expectedTime,
    source: "silence",
    gap,
    gapIndex: gap.cutTime,
    silenceScore,
    distanceScore,
    distanceSeconds: distance,
    baseScore: 0.6 * silenceScore + 0.4 * distanceScore
  };
}

function chooseRuntimeCandidates(candidatesByCut, expectedDurations, start, end) {
  const dp = candidatesByCut.map((candidates) => candidates.map(() => ({
    score: -Infinity,
    previousIndex: -1
  })));
  const minGap = 1;

  candidatesByCut.forEach((candidates, cutIndex) => {
    candidates.forEach((candidate, candidateIndex) => {
      if (cutIndex === 0) {
        const segmentScore = segmentDurationScore(candidate.time - start, expectedDurations[0]);
        dp[cutIndex][candidateIndex].score = candidate.baseScore + 0.3 * segmentScore;
        return;
      }
      candidatesByCut[cutIndex - 1].forEach((previous, previousIndex) => {
        if (previous.time + minGap >= candidate.time) return;
        const segmentScore = segmentDurationScore(
          candidate.time - previous.time,
          expectedDurations[cutIndex]
        );
        const score = dp[cutIndex - 1][previousIndex].score
          + candidate.baseScore
          + 0.3 * segmentScore;
        if (score > dp[cutIndex][candidateIndex].score) {
          dp[cutIndex][candidateIndex] = {
            score,
            previousIndex
          };
        }
      });
    });
  });

  const lastCutIndex = candidatesByCut.length - 1;
  if (lastCutIndex < 0) return [];
  let bestIndex = 0;
  let bestScore = -Infinity;
  const finalExpectedDuration = expectedDurations[expectedDurations.length - 1];
  candidatesByCut[lastCutIndex].forEach((candidate, index) => {
    const finalSegmentScore = segmentDurationScore(end - candidate.time, finalExpectedDuration);
    const score = dp[lastCutIndex][index].score + 0.35 * finalSegmentScore;
    if (score > bestScore) {
      bestScore = score;
      bestIndex = index;
    }
  });

  const chosen = [];
  let cursor = bestIndex;
  for (let cutIndex = lastCutIndex; cutIndex >= 0; cutIndex -= 1) {
    chosen.unshift(candidatesByCut[cutIndex][cursor]);
    cursor = dp[cutIndex][cursor].previousIndex;
    if (cursor < 0 && cutIndex > 0) {
      const fallback = candidatesByCut
        .slice(0, cutIndex)
        .map((candidates) => candidates.find((candidate) => candidate.source === "runtime") || candidates[0]);
      return [...fallback, ...chosen].sort((a, b) => a.time - b.time);
    }
  }
  return chosen;
}

function segmentDurationScore(actual, expected) {
  if (!Number.isFinite(actual) || !Number.isFinite(expected) || expected <= 0) return 0;
  const tolerance = Math.max(8, expected * 0.18);
  return clamp(1 - Math.abs(actual - expected) / tolerance, 0, 1);
}

function confidenceForCandidate(candidate, leftDurationScore, rightDurationScore) {
  return clamp(
    0.5 * candidate.silenceScore
      + 0.3 * candidate.distanceScore
      + 0.2 * Math.min(leftDurationScore, rightDurationScore),
    0,
    1
  );
}

function confidenceLabel(score, source) {
  if (source !== "silence") return "low";
  if (score >= 0.76) return "high";
  if (score >= 0.55) return "medium";
  return "low";
}

function runtimeAlignmentNote(candidate, confidence, windowSeconds) {
  if (candidate.source !== "silence") {
    return "No quiet gap was found near the expected runtime, so this split uses the runtime estimate.";
  }
  const roundedDistance = Math.round(candidate.distanceSeconds);
  if (confidence === "high") {
    return `Snapped to a strong quiet gap ${roundedDistance}s from the expected runtime.`;
  }
  if (confidence === "medium") {
    return `Snapped to a nearby quiet gap ${roundedDistance}s from the expected runtime; quick review suggested.`;
  }
  return `Closest quiet gap was weak or far from the expected runtime (${roundedDistance}s of ${Math.round(windowSeconds)}s window).`;
}

function dedupeCandidates(candidates) {
  const result = [];
  for (const candidate of candidates.sort((a, b) => b.baseScore - a.baseScore)) {
    if (!result.some((existing) => Math.abs(existing.time - candidate.time) < 0.25)) {
      result.push(candidate);
    }
  }
  return result;
}

function median(values) {
  const sorted = values.filter(Number.isFinite).sort((a, b) => a - b);
  if (!sorted.length) return 0;
  const middle = Math.floor(sorted.length / 2);
  return sorted.length % 2 === 0
    ? (sorted[middle - 1] + sorted[middle]) / 2
    : sorted[middle];
}

function headerValue(line, keys) {
  const lower = line.toLowerCase();
  for (const key of keys) {
    if (lower.startsWith(`${key}:`)) {
      const value = line.slice(key.length + 1).trim();
      return value || "";
    }
  }
  return "";
}

function percentile(sortedValues, fraction) {
  if (!sortedValues.length) return -120;
  const index = Math.floor((sortedValues.length - 1) * fraction);
  return sortedValues[index];
}

function mean(values) {
  if (!values.length) return -120;
  return values.reduce((sum, value) => sum + value, 0) / values.length;
}
