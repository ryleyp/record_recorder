import { clamp, dbFromPeak } from "./utils.js";

export function defaultSilenceCropSettings() {
  return {
    enabled: false,
    thresholdDBFS: -50,
    minimumSilenceSeconds: 4,
    keepPaddingSeconds: 0.35
  };
}

export function detectLongSilenceRanges(audioBuffer, settings = defaultSilenceCropSettings(), startSeconds = 0, endSeconds = audioBuffer.duration) {
  const channels = [];
  for (let index = 0; index < audioBuffer.numberOfChannels; index += 1) {
    channels.push(audioBuffer.getChannelData(index));
  }
  return detectLongSilenceRangesFromChannelData(
    channels,
    audioBuffer.sampleRate,
    settings,
    startSeconds,
    endSeconds
  );
}

export function detectLongSilenceRangesFromChannelData(channelData, sampleRate, settings = defaultSilenceCropSettings(), startSeconds = 0, endSeconds = null) {
  const channels = Array.from(channelData || []).filter(Boolean);
  if (!channels.length || !sampleRate) return [];

  const mergedSettings = { ...defaultSilenceCropSettings(), ...settings };
  const duration = channels[0].length / sampleRate;
  const start = clamp(startSeconds, 0, duration);
  const end = clamp(endSeconds ?? duration, start, duration);
  const hopSeconds = 0.05;
  const hopFrames = Math.max(1, Math.round(sampleRate * hopSeconds));
  const startFrame = Math.floor(start * sampleRate);
  const endFrame = Math.floor(end * sampleRate);

  const quietRuns = [];
  let runStart = null;

  for (let frame = startFrame; frame < endFrame; frame += hopFrames) {
    const frameEnd = Math.min(frame + hopFrames, endFrame);
    const rmsDBFS = windowRmsDBFS(channels, frame, frameEnd);
    if (rmsDBFS <= mergedSettings.thresholdDBFS) {
      if (runStart == null) runStart = frame;
    } else if (runStart != null) {
      quietRuns.push({ startFrame: runStart, endFrame: frame });
      runStart = null;
    }
  }
  if (runStart != null) {
    quietRuns.push({ startFrame: runStart, endFrame });
  }

  return quietRuns
    .map((run) => ({
      start: run.startFrame / sampleRate,
      end: run.endFrame / sampleRate
    }))
    .filter((run) => run.end - run.start >= mergedSettings.minimumSilenceSeconds)
    .map((run) => {
      const cropStart = clamp(run.start + mergedSettings.keepPaddingSeconds, start, end);
      const cropEnd = clamp(run.end - mergedSettings.keepPaddingSeconds, start, end);
      return {
        start: cropStart,
        end: cropEnd,
        originalStart: run.start,
        originalEnd: run.end,
        durationRemoved: Math.max(0, cropEnd - cropStart)
      };
    })
    .filter((range) => range.end > range.start);
}

export function subtractSkipRanges(startSeconds, endSeconds, skipRanges = []) {
  let keepRanges = [{ start: startSeconds, end: endSeconds }];
  const normalized = skipRanges
    .map((range) => ({
      start: clamp(range.start, startSeconds, endSeconds),
      end: clamp(range.end, startSeconds, endSeconds)
    }))
    .filter((range) => range.end > range.start)
    .sort((a, b) => a.start - b.start);

  for (const skip of normalized) {
    keepRanges = keepRanges.flatMap((range) => {
      if (skip.end <= range.start || skip.start >= range.end) return [range];
      const next = [];
      if (skip.start > range.start) next.push({ start: range.start, end: skip.start });
      if (skip.end < range.end) next.push({ start: skip.end, end: range.end });
      return next;
    });
  }
  return keepRanges.filter((range) => range.end > range.start);
}

export function summarizeSilenceCrop(ranges = []) {
  const removedSeconds = ranges.reduce((sum, range) => sum + Math.max(0, range.end - range.start), 0);
  return {
    count: ranges.length,
    removedSeconds
  };
}

function windowRmsDBFS(channels, startFrame, endFrame) {
  let sum = 0;
  let count = 0;
  for (let frame = startFrame; frame < endFrame; frame += 1) {
    for (const channel of channels) {
      const sample = channel[frame] || 0;
      sum += sample * sample;
      count += 1;
    }
  }
  return dbFromPeak(Math.sqrt(sum / Math.max(count, 1)));
}
