import { clamp } from "./utils.js";

const DEFAULT_NOISE_FLOOR_DBFS = -55;
const MUSIC_CONFIRM_SECONDS = 0.45;
const MUSIC_RESUME_SECONDS = 0.6;
const LEAD_IN_PREROLL_SECONDS = 0.45;
const RUNOUT_PREROLL_SECONDS = 0.25;
const LONG_GAP_SECONDS = 6;

export function createRecordingGapListener(options = {}) {
  const noiseFloorDBFS = typeof options.noiseFloorDBFS === "number"
    ? options.noiseFloorDBFS
    : DEFAULT_NOISE_FLOOR_DBFS;
  const startThresholdDBFS = options.startThresholdDBFS ?? clamp(noiseFloorDBFS + 14, -46, -28);
  const quietThresholdDBFS = options.quietThresholdDBFS ?? clamp(noiseFloorDBFS + 8, -54, -34);
  return {
    noiseFloorDBFS,
    startThresholdDBFS,
    quietThresholdDBFS,
    elapsedSeconds: 0,
    phase: "waiting_for_music",
    musicAccumSeconds: 0,
    resumeAccumSeconds: 0,
    musicStartTime: null,
    suggestedTrimStart: 0,
    suggestedTrimEnd: null,
    lastMusicTime: null,
    quietRunStart: null,
    currentQuietSeconds: 0,
    longGapDetected: false,
    longGapStartTime: null,
    status: "Listening for music start"
  };
}

export function updateRecordingGapListener(listener, stats, frameSeconds) {
  const seconds = Math.max(0, Number(frameSeconds) || 0);
  const rmsDBFS = stats?.short_term_average_dbfs ?? stats?.rms_dbfs ?? -120;
  const previousElapsed = listener.elapsedSeconds;
  listener.elapsedSeconds += seconds;

  const isMusic = rmsDBFS >= listener.startThresholdDBFS;
  const isQuiet = rmsDBFS <= listener.quietThresholdDBFS;

  if (listener.phase === "waiting_for_music") {
    if (isMusic) {
      listener.musicAccumSeconds += seconds;
      if (listener.musicAccumSeconds >= MUSIC_CONFIRM_SECONDS) {
        const startTime = listener.elapsedSeconds - listener.musicAccumSeconds;
        listener.musicStartTime = startTime;
        listener.suggestedTrimStart = Math.max(0, startTime - LEAD_IN_PREROLL_SECONDS);
        listener.lastMusicTime = listener.elapsedSeconds;
        listener.phase = "recording_music";
        listener.status = "Music detected";
      } else {
        listener.status = "Confirming music start";
      }
    } else {
      listener.musicAccumSeconds = 0;
      listener.status = "Listening for music start";
    }
    return snapshot(listener);
  }

  if (listener.phase === "recording_music") {
    if (isQuiet) {
      if (listener.quietRunStart == null) {
        listener.quietRunStart = previousElapsed;
      }
      listener.currentQuietSeconds = listener.elapsedSeconds - listener.quietRunStart;
      listener.status = `Quiet gap ${listener.currentQuietSeconds.toFixed(1)}s`;
      if (listener.currentQuietSeconds >= LONG_GAP_SECONDS) {
        listener.longGapDetected = true;
        listener.longGapStartTime = listener.quietRunStart;
        listener.suggestedTrimEnd = Math.max(
          listener.suggestedTrimStart,
          listener.quietRunStart - RUNOUT_PREROLL_SECONDS
        );
        listener.phase = "long_gap";
        listener.resumeAccumSeconds = 0;
        listener.status = "Long gap detected - ready to stop and flip";
      }
    } else {
      listener.quietRunStart = null;
      listener.currentQuietSeconds = 0;
      listener.lastMusicTime = listener.elapsedSeconds;
      listener.status = "Recording music";
    }
    return snapshot(listener);
  }

  if (listener.phase === "long_gap") {
    if (isMusic) {
      listener.resumeAccumSeconds += seconds;
      if (listener.resumeAccumSeconds >= MUSIC_RESUME_SECONDS) {
        listener.phase = "recording_music";
        listener.quietRunStart = null;
        listener.currentQuietSeconds = 0;
        listener.longGapDetected = false;
        listener.longGapStartTime = null;
        listener.suggestedTrimEnd = null;
        listener.lastMusicTime = listener.elapsedSeconds;
        listener.status = "Music resumed";
      }
    } else {
      listener.resumeAccumSeconds = 0;
      listener.currentQuietSeconds = listener.quietRunStart == null
        ? 0
        : listener.elapsedSeconds - listener.quietRunStart;
      listener.status = "Long gap detected - ready to stop and flip";
    }
  }

  return snapshot(listener);
}

export function finalizeRecordingGapListener(listener, durationSeconds) {
  if (!listener) {
    return null;
  }
  const duration = Math.max(0, Number(durationSeconds) || listener.elapsedSeconds || 0);
  const trimStart = clamp(listener.suggestedTrimStart || 0, 0, duration);
  const trimEnd = listener.suggestedTrimEnd == null
    ? duration
    : clamp(listener.suggestedTrimEnd, trimStart, duration);
  return {
    noise_floor_dbfs: listener.noiseFloorDBFS,
    start_threshold_dbfs: listener.startThresholdDBFS,
    quiet_threshold_dbfs: listener.quietThresholdDBFS,
    music_start_time: listener.musicStartTime,
    long_gap_detected: listener.longGapDetected,
    long_gap_start_time: listener.longGapStartTime,
    suggested_trim_start: trimStart,
    suggested_trim_end: trimEnd,
    status: listener.status
  };
}

function snapshot(listener) {
  return {
    phase: listener.phase,
    status: listener.status,
    musicStartTime: listener.musicStartTime,
    suggestedTrimStart: listener.suggestedTrimStart,
    suggestedTrimEnd: listener.suggestedTrimEnd,
    longGapDetected: listener.longGapDetected,
    longGapStartTime: listener.longGapStartTime,
    currentQuietSeconds: listener.currentQuietSeconds,
    startThresholdDBFS: listener.startThresholdDBFS,
    quietThresholdDBFS: listener.quietThresholdDBFS
  };
}
