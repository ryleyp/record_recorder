import {
  analyzeImportAudioBuffer,
  applyImportCleanupToAudioBuffer,
  cleanupOptionsForPreset,
  defaultImportCleanupOptions
} from "./audioCleanup.js";
import {
  DETECTION_PRESETS,
  alignTracklistDetailed,
  applyAudacityLabels,
  computeEnvelopeFromAudioBuffer,
  computePeaksFromAudioBuffer,
  defaultDetectionSettings,
  detectTracks,
  parseAudacityLabels,
  parseTracklist
} from "./detection.js";
import {
  createRecordingGapListener,
  finalizeRecordingGapListener,
  updateRecordingGapListener
} from "./gapListener.js";
import {
  analyzeInputLevels,
  calculateRecordingScore,
  generateRecordingRecommendations,
  measureNoiseFloor,
  mergeQualityStats,
  qualityStatsFromAudioBuffer
} from "./quality.js";
import {
  BrowserRecorder,
  InputMonitor,
  listAudioInputs,
  requestAudioInputPermission
} from "./recorder.js";
import {
  defaultSilenceCropSettings,
  detectLongSilenceRanges,
  summarizeSilenceCrop
} from "./silenceCrop.js";
import { encodeAudioBufferToWav, encodeSegmentToWav } from "./wav.js";
import { createZip } from "./zip.js";
import {
  clamp,
  dbFromPeak,
  downloadBlob,
  formatDB,
  formatTime,
  meterPercent,
  nextFrame,
  readFileAsDataURL,
  sanitizeFileName,
  uniqueId
} from "./utils.js";

const SIDE_LABELS = ["A", "B"];
const LEVEL_ANALYSIS_SECONDS = 12;
const NOISE_MEASUREMENT_SECONDS = 5;
const ROLLING_ANALYSIS_SECONDS = 3;

const state = {
  activeStep: "add",
  detectSide: "A",
  reviewSide: "A",
  monitor: null,
  monitorRolling: null,
  activeCapture: null,
  levelStats: null,
  noiseStats: null,
  recordingRolling: null,
  recordingGapListener: null,
  recordingGapSnapshot: null,
  recordingClipCount: 0,
  lastSilenceCropSummary: null,
  inputDevices: [],
  selectedInputDeviceId: "",
  storageTimer: 0,
  recorder: null,
  recordingSide: null,
  decodeContext: null,
  playbackContext: null,
  playbackSource: null,
  selectedMarker: null,
  draggingMarker: null,
  project: createProject()
};

const dom = {
  statusLine: byId("statusLine"),
  saveProjectButton: byId("saveProjectButton"),
  loadProjectInput: byId("loadProjectInput"),
  inputDeviceSelect: byId("inputDeviceSelect"),
  refreshDevicesButton: byId("refreshDevicesButton"),
  meterLeft: byId("meterLeft"),
  meterRight: byId("meterRight"),
  meterLeftText: byId("meterLeftText"),
  meterRightText: byId("meterRightText"),
  recordSideAButton: byId("recordSideAButton"),
  recordSideBButton: byId("recordSideBButton"),
  stopRecordingButton: byId("stopRecordingButton"),
  recordInputDeviceSelect: byId("recordInputDeviceSelect"),
  recordRefreshDevicesButton: byId("recordRefreshDevicesButton"),
  recordInputStatus: byId("recordInputStatus"),
  recordingClock: byId("recordingClock"),
  recordingStorage: byId("recordingStorage"),
  recordingClipCount: byId("recordingClipCount"),
  recordingQualityScore: byId("recordingQualityScore"),
  recordingPeakReadout: byId("recordingPeakReadout"),
  recordingRmsReadout: byId("recordingRmsReadout"),
  recordingNoiseFloor: byId("recordingNoiseFloor"),
  recordingProblemStatus: byId("recordingProblemStatus"),
  recordingGapStatus: byId("recordingGapStatus"),
  recordingTrimSuggestion: byId("recordingTrimSuggestion"),
  importSideAInput: byId("importSideAInput"),
  importSideBInput: byId("importSideBInput"),
  cleanupPresetSelect: byId("cleanupPresetSelect"),
  applyImportCleanupInput: byId("applyImportCleanupInput"),
  removeDCOffsetInput: byId("removeDCOffsetInput"),
  highPassRumbleInput: byId("highPassRumbleInput"),
  balanceChannelsInput: byId("balanceChannelsInput"),
  gentleDeClickInput: byId("gentleDeClickInput"),
  normalizeImportInput: byId("normalizeImportInput"),
  importOptimizationStatus: byId("importOptimizationStatus"),
  tracklistAlignmentStatus: byId("tracklistAlignmentStatus"),
  sideAFileName: byId("sideAFileName"),
  sideBFileName: byId("sideBFileName"),
  sideSummaryAdd: byId("sideSummaryAdd"),
  sideSummaryRecord: byId("sideSummaryRecord"),
  sideSummaryDetails: byId("sideSummaryDetails"),
  sideSummaryExport: byId("sideSummaryExport"),
  startMonitorButton: byId("startMonitorButton"),
  stopMonitorButton: byId("stopMonitorButton"),
  analyzeLevelsButton: byId("analyzeLevelsButton"),
  measureNoiseButton: byId("measureNoiseButton"),
  analysisProgress: byId("analysisProgress"),
  analysisStatus: byId("analysisStatus"),
  overallQualityScore: byId("overallQualityScore"),
  levelPeakReadout: byId("levelPeakReadout"),
  levelRmsReadout: byId("levelRmsReadout"),
  levelShortTermReadout: byId("levelShortTermReadout"),
  levelClipReadout: byId("levelClipReadout"),
  analysisPeak: byId("analysisPeak"),
  analysisRms: byId("analysisRms"),
  analysisDynamicRange: byId("analysisDynamicRange"),
  analysisClips: byId("analysisClips"),
  qualityBreakdown: byId("qualityBreakdown"),
  noiseFloorCard: byId("noiseFloorCard"),
  problemList: byId("problemList"),
  recommendationList: byId("recommendationList"),
  thresholdInput: byId("thresholdInput"),
  thresholdOutput: byId("thresholdOutput"),
  gapInput: byId("gapInput"),
  gapOutput: byId("gapOutput"),
  trackMinInput: byId("trackMinInput"),
  trackMinOutput: byId("trackMinOutput"),
  detectButton: byId("detectButton"),
  detectResultText: byId("detectResultText"),
  tracklistInput: byId("tracklistInput"),
  applyTracklistButton: byId("applyTracklistButton"),
  labelFileInput: byId("labelFileInput"),
  detectTrackList: byId("detectTrackList"),
  waveformCanvas: byId("waveformCanvas"),
  addMarkerButton: byId("addMarkerButton"),
  deleteMarkerButton: byId("deleteMarkerButton"),
  playSelectionButton: byId("playSelectionButton"),
  stopPlaybackButton: byId("stopPlaybackButton"),
  reviewTrackList: byId("reviewTrackList"),
  albumTitleInput: byId("albumTitleInput"),
  albumArtistInput: byId("albumArtistInput"),
  yearInput: byId("yearInput"),
  genreInput: byId("genreInput"),
  discNumberInput: byId("discNumberInput"),
  discTotalInput: byId("discTotalInput"),
  artworkInput: byId("artworkInput"),
  artworkPreview: byId("artworkPreview"),
  artworkText: byId("artworkText"),
  albumTrackList: byId("albumTrackList"),
  normalizeInput: byId("normalizeInput"),
  matchLoudnessInput: byId("matchLoudnessInput"),
  cropLongSilenceInput: byId("cropLongSilenceInput"),
  cropSilenceThresholdInput: byId("cropSilenceThresholdInput"),
  cropSilenceMinimumInput: byId("cropSilenceMinimumInput"),
  cropSilencePaddingInput: byId("cropSilencePaddingInput"),
  silenceCropStatus: byId("silenceCropStatus"),
  playlistInput: byId("playlistInput"),
  originalsInput: byId("originalsInput"),
  fadeInInput: byId("fadeInInput"),
  fadeOutInput: byId("fadeOutInput"),
  exportButton: byId("exportButton"),
  exportTrackList: byId("exportTrackList"),
  exportProgress: byId("exportProgress"),
  exportStatus: byId("exportStatus"),
  recordInputDialog: byId("recordInputDialog"),
  dialogInputDeviceSelect: byId("dialogInputDeviceSelect"),
  dialogRefreshDevicesButton: byId("dialogRefreshDevicesButton"),
  recordInputSideText: byId("recordInputSideText"),
  recordInputDialogStatus: byId("recordInputDialogStatus")
};

bindEvents();
refreshDevices();
render();
registerServiceWorker();

function bindEvents() {
  document.querySelectorAll(".step-tab").forEach((button) => {
    button.addEventListener("click", () => setStep(button.dataset.step));
  });
  document.querySelectorAll("[data-step-shortcut]").forEach((button) => {
    button.addEventListener("click", () => setStep(button.dataset.stepShortcut));
  });

  document.querySelectorAll(".side-toggle").forEach((button) => {
    button.addEventListener("click", () => {
      const side = button.dataset.side;
      if (button.dataset.sideTarget === "detect") {
        state.detectSide = side;
      } else {
        state.reviewSide = side;
        state.selectedMarker = null;
      }
      render();
    });
  });

  document.querySelectorAll("[data-preset]").forEach((button) => {
    button.addEventListener("click", () => {
      const side = sideFor(state.detectSide);
      side.detectionSettings = { ...DETECTION_PRESETS[button.dataset.preset] };
      render();
    });
  });

  [dom.thresholdInput, dom.gapInput, dom.trackMinInput].forEach((input) => {
    input.addEventListener("input", () => {
      const settings = sideFor(state.detectSide).detectionSettings;
      settings.preset = "custom";
      settings.silenceThresholdDB = Number(dom.thresholdInput.value);
      settings.minimumGapSeconds = Number(dom.gapInput.value);
      settings.minimumTrackSeconds = Number(dom.trackMinInput.value);
      settings.minimumScore = settings.minimumScore ?? DETECTION_PRESETS.balanced.minimumScore;
      renderDetectionSettings();
    });
  });

  dom.refreshDevicesButton.addEventListener("click", () => refreshDevices({ requestPermission: true }));
  dom.recordRefreshDevicesButton.addEventListener("click", () => refreshDevices({ requestPermission: true }));
  dom.dialogRefreshDevicesButton.addEventListener("click", () => refreshDevices({ requestPermission: true }));
  inputDeviceSelects().forEach((select) => {
    select.addEventListener("change", () => syncInputDeviceSelection(select.value));
  });
  dom.startMonitorButton.addEventListener("click", startMonitoring);
  dom.stopMonitorButton.addEventListener("click", stopMonitoring);
  dom.analyzeLevelsButton.addEventListener("click", analyzeLoudestSection);
  dom.measureNoiseButton.addEventListener("click", measureSurfaceNoise);
  dom.recordSideAButton.addEventListener("click", () => startRecording("A"));
  dom.recordSideBButton.addEventListener("click", () => startRecording("B"));
  dom.stopRecordingButton.addEventListener("click", stopRecording);
  dom.cleanupPresetSelect.addEventListener("change", () => {
    applyCleanupPreset(dom.cleanupPresetSelect.value);
  });
  dom.importSideAInput.addEventListener("change", () => importSideFile("A", dom.importSideAInput.files[0]));
  dom.importSideBInput.addEventListener("change", () => importSideFile("B", dom.importSideBInput.files[0]));
  dom.detectButton.addEventListener("click", runDetectionForActiveSide);
  dom.applyTracklistButton.addEventListener("click", applyTracklistToActiveSide);
  dom.labelFileInput.addEventListener("change", applyLabelFileToActiveSide);

  dom.saveProjectButton.addEventListener("click", saveProjectFile);
  dom.loadProjectInput.addEventListener("change", loadProjectFile);

  [
    dom.albumTitleInput,
    dom.albumArtistInput,
    dom.yearInput,
    dom.genreInput,
    dom.discNumberInput,
    dom.discTotalInput
  ].forEach((input) => input.addEventListener("input", updateAlbumFromFields));
  dom.artworkInput.addEventListener("change", updateArtwork);

  dom.addMarkerButton.addEventListener("click", addMarker);
  dom.deleteMarkerButton.addEventListener("click", deleteSelectedMarker);
  dom.playSelectionButton.addEventListener("click", playSelectedTrack);
  dom.stopPlaybackButton.addEventListener("click", stopPlayback);

  dom.reviewTrackList.addEventListener("input", handleTrackInput);
  dom.albumTrackList.addEventListener("input", handleTrackInput);
  dom.exportButton.addEventListener("click", exportAlbumZip);
  [
    dom.cropLongSilenceInput,
    dom.cropSilenceThresholdInput,
    dom.cropSilenceMinimumInput,
    dom.cropSilencePaddingInput
  ].forEach((input) => input.addEventListener("input", updateSilenceCropSettings));

  dom.waveformCanvas.addEventListener("pointerdown", handleWaveformPointerDown);
  dom.waveformCanvas.addEventListener("pointermove", handleWaveformPointerMove);
  dom.waveformCanvas.addEventListener("pointerup", handleWaveformPointerUp);
  dom.waveformCanvas.addEventListener("pointercancel", handleWaveformPointerUp);
  window.addEventListener("resize", () => requestAnimationFrame(drawWaveform));
}

function createProject() {
  return {
    version: 3,
    id: uniqueId(),
    albumTitle: "",
    albumArtist: "",
    year: "",
    genre: "",
    discNumber: 1,
    discTotal: 1,
    artwork: null,
    levelCheck: null,
    noiseFloor: null,
    sides: {
      A: createSide("A"),
      B: createSide("B")
    }
  };
}

function createSide(label) {
  return {
    label,
    sourceName: "",
    sourceType: "empty",
    audioBuffer: null,
    originalAudioBuffer: null,
    durationSeconds: 0,
    sampleRate: 0,
    channelCount: 0,
    trimStart: 0,
    trimEnd: 0,
    boundaries: [],
    tracks: [],
    detectionSettings: defaultDetectionSettings(),
    candidateGaps: [],
    effectiveThresholdDB: null,
    tracklistAlignment: null,
    recordingGap: null,
    recordingStats: null,
    importAnalysis: null,
    importOptimization: null,
    envelope: null,
    peaks: []
  };
}

async function refreshDevices(options = {}) {
  try {
    const selectedDeviceId = currentInputDeviceId();
    if (options.requestPermission) {
      setStatus("Requesting audio input access");
      await requestAudioInputPermission();
    }
    const devices = await listAudioInputs();
    state.inputDevices = devices;
    inputDeviceSelects().forEach((select) => populateInputDeviceSelect(select, devices, selectedDeviceId));
    syncInputDeviceSelection(inputDeviceOptionExists(selectedDeviceId) ? selectedDeviceId : "");
    if (options.requestPermission) {
      setStatus(devices.length ? "Audio inputs refreshed" : "Using browser default input");
    }
    return true;
  } catch (error) {
    setStatus(error.message);
    renderRecordingInputStatus(error.message);
    return false;
  }
}

function inputDeviceSelects() {
  return [
    dom.inputDeviceSelect,
    dom.recordInputDeviceSelect,
    dom.dialogInputDeviceSelect
  ].filter(Boolean);
}

function populateInputDeviceSelect(select, devices, selectedDeviceId) {
  select.innerHTML = "";
  const defaultOption = document.createElement("option");
  defaultOption.value = "";
  defaultOption.textContent = "Default input";
  select.append(defaultOption);

  devices.forEach((device, index) => {
    const option = document.createElement("option");
    option.value = device.deviceId;
    option.textContent = device.label || `Input ${index + 1}`;
    select.append(option);
  });

  select.value = inputDeviceOptionExists(selectedDeviceId) ? selectedDeviceId : "";
}

function inputDeviceOptionExists(deviceId) {
  return !deviceId || state.inputDevices.some((device) => device.deviceId === deviceId);
}

function syncInputDeviceSelection(deviceId) {
  state.selectedInputDeviceId = inputDeviceOptionExists(deviceId) ? deviceId : "";
  inputDeviceSelects().forEach((select) => {
    if ([...select.options].some((option) => option.value === state.selectedInputDeviceId)) {
      select.value = state.selectedInputDeviceId;
    }
  });
  renderRecordingInputStatus();
}

function currentInputDeviceId() {
  return state.selectedInputDeviceId
    || dom.recordInputDeviceSelect?.value
    || dom.inputDeviceSelect?.value
    || "";
}

function currentInputDeviceLabel() {
  const deviceId = currentInputDeviceId();
  if (!deviceId) return "Default input";
  const index = state.inputDevices.findIndex((device) => device.deviceId === deviceId);
  const device = state.inputDevices[index];
  return device?.label || `Input ${index >= 0 ? index + 1 : ""}`.trim();
}

function renderRecordingInputStatus(errorMessage = "") {
  if (errorMessage) {
    dom.recordInputStatus.textContent = `Input access needed: ${errorMessage}`;
    dom.recordInputDialogStatus.textContent = "Allow audio input access, then choose the turntable or interface input.";
    return;
  }
  const label = currentInputDeviceLabel();
  const message = state.inputDevices.length
    ? `Selected input: ${label}. Confirm this source when starting a recording.`
    : "Selected input: Default input. Click Refresh and allow audio input access to choose a specific source.";
  dom.recordInputStatus.textContent = message;
  dom.recordInputDialogStatus.textContent = state.inputDevices.length
    ? `Recording will use: ${label}.`
    : "If your USB turntable is not listed, click Refresh and allow audio input access.";
}

async function promptForRecordingInput(sideLabel) {
  const refreshed = await refreshDevices({ requestPermission: true });
  if (!refreshed) return null;
  dom.recordInputSideText.textContent = `Side ${sideLabel}`;
  renderRecordingInputStatus();

  if (typeof dom.recordInputDialog.showModal !== "function") {
    const ok = window.confirm(`Record Side ${sideLabel} using ${currentInputDeviceLabel()}?`);
    if (!ok) {
      setStatus("Recording canceled. Choose the correct input and press Record again.");
      return null;
    }
    return currentInputDeviceId();
  }

  return new Promise((resolve) => {
    const handleClose = () => {
      if (dom.recordInputDialog.returnValue === "confirm") {
        syncInputDeviceSelection(dom.dialogInputDeviceSelect.value);
        resolve(currentInputDeviceId());
        return;
      }
      setStatus("Recording canceled. Choose the correct input and press Record again.");
      resolve(null);
    };
    dom.recordInputDialog.addEventListener("close", handleClose, { once: true });
    dom.recordInputDialog.returnValue = "";
    dom.recordInputDialog.showModal();
  });
}

async function startMonitoring() {
  if (state.monitor) return;
  try {
    setStatus("Monitoring input");
    state.monitorRolling = null;
    state.monitor = new InputMonitor({ onFrame: handleMonitorFrame });
    await state.monitor.start(currentInputDeviceId());
    renderMonitorControls();
    await refreshDevices();
  } catch (error) {
    state.monitor = null;
    renderMonitorControls();
    setStatus(error.message);
  }
}

async function stopMonitoring() {
  if (!state.monitor) return;
  await state.monitor.stop();
  state.monitor = null;
  state.monitorRolling = null;
  state.activeCapture = null;
  dom.analysisProgress.value = 0;
  renderMonitorControls();
  setStatus("Monitoring stopped");
}

async function analyzeLoudestSection() {
  await ensureMonitoring();
  if (!state.monitor) return;
  state.activeCapture = createTimedCapture("levels", LEVEL_ANALYSIS_SECONDS);
  dom.analysisProgress.value = 0;
  dom.analysisStatus.textContent = "Analyzing loudest section for 12 seconds...";
  setStatus("Analyzing loudest section");
}

async function measureSurfaceNoise() {
  await ensureMonitoring();
  if (!state.monitor) return;
  state.activeCapture = createTimedCapture("noise", NOISE_MEASUREMENT_SECONDS);
  dom.analysisProgress.value = 0;
  dom.analysisStatus.textContent = "Measuring surface noise for 5 seconds...";
  setStatus("Measuring surface noise");
}

async function ensureMonitoring() {
  if (!state.monitor) {
    await startMonitoring();
  }
}

function handleMonitorFrame(frame) {
  state.monitorRolling ||= createSampleCollector(
    frame.sampleRate,
    frame.channelCount,
    ROLLING_ANALYSIS_SECONDS
  );
  state.monitorRolling.addFrame(frame.channels);

  const frameStats = analyzeInputLevels(frame.channels, frame.sampleRate);
  const rollingStats = analyzeInputLevels(state.monitorRolling.toChannelData(), frame.sampleRate);
  const liveStats = {
    ...frameStats,
    short_term_average_dbfs: rollingStats.rms_dbfs
  };
  updateMetersFromStats(liveStats);
  renderLiveLevelStats(liveStats);

  if (state.activeCapture) {
    state.activeCapture.collector.addFrame(frame.channels);
    dom.analysisProgress.value = state.activeCapture.collector.frameCount / state.activeCapture.targetFrames;
    if (state.activeCapture.collector.frameCount >= state.activeCapture.targetFrames) {
      finishActiveCapture(frame.sampleRate);
    }
  }
}

function finishActiveCapture(sampleRate) {
  const capture = state.activeCapture;
  if (!capture) return;
  const channels = capture.collector.toChannelData();
  if (capture.type === "levels") {
    const stats = analyzeInputLevels(channels, sampleRate);
    state.levelStats = mergeQualityStats(stats, state.noiseStats || {});
    state.project.levelCheck = state.levelStats;
    dom.analysisStatus.textContent = "Level analysis complete.";
    setStatus("Level analysis complete");
  } else {
    state.noiseStats = measureNoiseFloor(channels, sampleRate);
    state.project.noiseFloor = state.noiseStats.noise_floor;
    if (state.levelStats) {
      state.levelStats = mergeQualityStats(state.levelStats, state.noiseStats);
      state.project.levelCheck = state.levelStats;
    }
    dom.analysisStatus.textContent = "Surface noise measurement complete.";
    setStatus("Surface noise measurement complete");
  }
  state.activeCapture = null;
  dom.analysisProgress.value = 1;
  renderQualityAnalysis();
}

function createTimedCapture(type, seconds) {
  const sampleRate = state.monitor?.sampleRate || 48000;
  const channelCount = state.monitor?.channelCount || 2;
  return {
    type,
    targetFrames: sampleRate * seconds,
    collector: createSampleCollector(sampleRate, channelCount)
  };
}

async function startRecording(sideLabel) {
  if (state.recorder) return;
  const deviceId = await promptForRecordingInput(sideLabel);
  if (deviceId == null) return;
  try {
    if (state.monitor) {
      await stopMonitoring();
    }
    setStatus(`Recording Side ${sideLabel}`);
    state.recordingSide = sideLabel;
    state.recordingRolling = null;
    state.recordingGapListener = createRecordingGapListener({
      noiseFloorDBFS: state.noiseStats?.noise_floor ?? state.project.noiseFloor
    });
    state.recordingGapSnapshot = null;
    state.recordingClipCount = 0;
    state.recorder = new BrowserRecorder({
      onFrame: handleRecordingFrame,
      onMeter: updateMeters,
      onTick: (seconds) => {
        dom.recordingClock.textContent = formatTime(seconds);
        updateStorageEstimate();
      }
    });
    await state.recorder.start(deviceId);
    updateStorageEstimate();
    renderRecordControls();
  } catch (error) {
    state.recorder = null;
    state.recordingSide = null;
    renderRecordControls();
    setStatus(error.message);
  }
}

async function stopRecording() {
  if (!state.recorder || !state.recordingSide) return;
  const sideLabel = state.recordingSide;
  try {
    setStatus(`Saving Side ${sideLabel}`);
    const audioBuffer = await state.recorder.stop();
    const gapSummary = finalizeRecordingGapListener(state.recordingGapListener, audioBuffer.duration);
    assignAudioToSide(
      sideLabel,
      audioBuffer,
      `Recorded Side ${sideLabel}.wav`,
      "liveRecording",
      { gapSummary }
    );
    await refreshDevices();
    setStatus(`Side ${sideLabel} recorded`);
  } catch (error) {
    setStatus(error.message);
  } finally {
    state.recorder = null;
    state.recordingSide = null;
    state.recordingRolling = null;
    state.recordingGapListener = null;
    state.recordingGapSnapshot = null;
    window.clearInterval(state.storageTimer);
    state.storageTimer = 0;
    renderRecordControls();
  }
}

function handleRecordingFrame(frame) {
  state.recordingRolling ||= createSampleCollector(
    frame.sampleRate,
    frame.channelCount,
    ROLLING_ANALYSIS_SECONDS
  );
  state.recordingRolling.addFrame(frame.channels);
  const frameStats = analyzeInputLevels(frame.channels, frame.sampleRate);
  const rollingStats = analyzeInputLevels(state.recordingRolling.toChannelData(), frame.sampleRate);
  state.recordingClipCount += frameStats.clipping_count;
  const liveStats = {
    ...frameStats,
    clipping_count: state.recordingClipCount,
    short_term_average_dbfs: rollingStats.rms_dbfs,
    noise_floor: state.noiseStats?.noise_floor ?? state.project.noiseFloor
  };
  if (state.recordingGapListener) {
    const frameSeconds = (frame.channels[0]?.length || 0) / frame.sampleRate;
    state.recordingGapSnapshot = updateRecordingGapListener(
      state.recordingGapListener,
      liveStats,
      frameSeconds
    );
    liveStats.gap_listener = state.recordingGapSnapshot;
  }
  renderRecordingDiagnostics(liveStats);
}

async function importSideFile(sideLabel, file) {
  if (!file) return;
  try {
    setStatus(`Decoding ${file.name}`);
    await nextFrame();
    const context = getDecodeContext();
    const data = await file.arrayBuffer();
    const audioBuffer = await context.decodeAudioData(data.slice(0));
    const importAnalysis = analyzeImportAudioBuffer(audioBuffer);
    const cleanupOptions = getImportCleanupOptions();
    const cleanupResult = cleanupOptions.applyCleanup
      ? applyImportCleanupToAudioBuffer(audioBuffer, cleanupOptions)
      : null;
    const workingBuffer = cleanupResult?.audioBuffer || audioBuffer;
    assignAudioToSide(sideLabel, workingBuffer, file.name, "importedFile", {
      originalAudioBuffer: audioBuffer,
      importAnalysis,
      importOptimization: cleanupResult?.metadata || {
        options: cleanupOptions,
        applied: [],
        click_repairs: 0,
        analysis_before: importAnalysis,
        analysis_after: importAnalysis
      }
    });
    renderImportOptimizationStatus(sideLabel);
    setStatus(cleanupResult?.metadata.applied.length
      ? `Imported and optimized ${file.name}`
      : `Imported ${file.name}`);
  } catch (error) {
    setStatus(`Could not decode ${file.name}: ${error.message}`);
  }
}

function applyCleanupPreset(preset) {
  const options = cleanupOptionsForPreset(preset);
  dom.applyImportCleanupInput.checked = options.applyCleanup;
  dom.removeDCOffsetInput.checked = options.removeDCOffset;
  dom.highPassRumbleInput.checked = options.highPassRumble;
  dom.balanceChannelsInput.checked = options.balanceChannels;
  dom.gentleDeClickInput.checked = options.gentleDeClick;
  dom.normalizeImportInput.checked = options.normalizePeaks;
  renderImportOptimizationStatus();
}

function getImportCleanupOptions() {
  return {
    ...defaultImportCleanupOptions(),
    preset: dom.cleanupPresetSelect.value,
    applyCleanup: dom.applyImportCleanupInput.checked,
    removeDCOffset: dom.removeDCOffsetInput.checked,
    highPassRumble: dom.highPassRumbleInput.checked,
    balanceChannels: dom.balanceChannelsInput.checked,
    gentleDeClick: dom.gentleDeClickInput.checked,
    normalizePeaks: dom.normalizeImportInput.checked
  };
}

function renderImportOptimizationStatus(sideLabel = null) {
  const side = sideLabel ? sideFor(sideLabel) : null;
  const optimization = side?.importOptimization;
  const analysis = side?.importAnalysis;
  if (!optimization) {
    dom.importOptimizationStatus.innerHTML = "<strong>Ready</strong><span>Presets are conservative and originals are preserved for Original Recordings export.</span>";
    return;
  }
  const applied = optimization.applied?.length
    ? optimization.applied.join(", ")
    : "No cleanup applied";
  const beforePeak = optimization.analysis_before?.peak_dbfs;
  const afterPeak = optimization.analysis_after?.peak_dbfs;
  const recommendations = analysis?.recommendations?.join("; ") || "No extra suggestions";
  dom.importOptimizationStatus.innerHTML = `<strong>Side ${sideLabel}: ${escapeHTML(applied)}</strong><span>Peak ${formatDB(beforePeak)} -> ${formatDB(afterPeak)}. Noise ${formatDB(analysis?.noise_floor_dbfs)} (${escapeHTML(analysis?.noise_floor_rating || "unknown")}). Clicks found: ${analysis?.click_pop_candidates || 0}; repaired: ${optimization.click_repairs || 0}. Suggested: ${escapeHTML(recommendations)}.</span>`;
}

function updateSilenceCropSettings() {
  state.lastSilenceCropSummary = null;
  renderSilenceCropStatus();
}

function getSilenceCropSettings() {
  const defaults = defaultSilenceCropSettings();
  return {
    enabled: dom.cropLongSilenceInput.checked,
    thresholdDBFS: readNumberInput(dom.cropSilenceThresholdInput, defaults.thresholdDBFS, -80, -20),
    minimumSilenceSeconds: readNumberInput(dom.cropSilenceMinimumInput, defaults.minimumSilenceSeconds, 2, 60),
    keepPaddingSeconds: readNumberInput(dom.cropSilencePaddingInput, defaults.keepPaddingSeconds, 0, 3)
  };
}

function renderSilenceCropStatus() {
  const settings = getSilenceCropSettings();
  if (!settings.enabled) {
    dom.silenceCropStatus.innerHTML = "<strong>Long silence crop off</strong><span>Original track timing is preserved during export.</span>";
    return;
  }

  const summary = state.lastSilenceCropSummary;
  const message = summary?.count
    ? `Last export removed ${formatTime(summary.removedSeconds)} across ${summary.count} quiet range${summary.count === 1 ? "" : "s"}.`
    : `Export will remove quiet runs longer than ${settings.minimumSilenceSeconds.toFixed(1)} s below ${formatDB(settings.thresholdDBFS)}, keeping ${settings.keepPaddingSeconds.toFixed(2)} s at each edge.`;
  dom.silenceCropStatus.innerHTML = `<strong>Long silence crop on</strong><span>${escapeHTML(message)}</span>`;
}

function readNumberInput(input, fallback, low, high) {
  const value = Number(input.value);
  if (!Number.isFinite(value)) return fallback;
  return clamp(value, low, high);
}

function assignAudioToSide(sideLabel, audioBuffer, sourceName, sourceType, options = {}) {
  const side = sideFor(sideLabel);
  const gapSummary = options.gapSummary || null;
  side.audioBuffer = audioBuffer;
  side.originalAudioBuffer = options.originalAudioBuffer || null;
  side.sourceName = sourceName;
  side.sourceType = sourceType;
  side.durationSeconds = audioBuffer.duration;
  side.sampleRate = audioBuffer.sampleRate;
  side.channelCount = audioBuffer.numberOfChannels;
  side.trimStart = gapSummary?.suggested_trim_start ?? 0;
  side.trimEnd = gapSummary?.suggested_trim_end ?? audioBuffer.duration;
  side.boundaries = [];
  side.tracks = [];
  side.candidateGaps = [];
  side.effectiveThresholdDB = null;
  side.tracklistAlignment = null;
  side.recordingGap = gapSummary;
  side.importAnalysis = options.importAnalysis || null;
  side.importOptimization = options.importOptimization || null;
  side.recordingStats = qualityStatsFromAudioBuffer(
    audioBuffer,
    state.noiseStats?.noise_floor ?? state.project.noiseFloor
  );
  if (side.recordingStats && gapSummary) {
    side.recordingStats.gap_listener = gapSummary;
  }
  analyzeSide(side);
  reconcileTracks(side);
  render();
}

function analyzeSide(side) {
  if (!side.audioBuffer) return;
  side.envelope = computeEnvelopeFromAudioBuffer(side.audioBuffer);
  side.peaks = computePeaksFromAudioBuffer(side.audioBuffer);
}

function runDetectionForActiveSide() {
  const side = sideFor(state.detectSide);
  if (!side.audioBuffer) {
    setStatus(`Add audio for Side ${state.detectSide} first`);
    return null;
  }
  if (!side.envelope) analyzeSide(side);
  const result = detectTracks(side.envelope, side.detectionSettings);
  side.boundaries = result.boundaries;
  side.candidateGaps = result.candidateGaps;
  side.trimStart = result.suggestedTrimStart;
  side.trimEnd = result.suggestedTrimEnd;
  side.effectiveThresholdDB = result.effectiveThresholdDB;
  side.tracklistAlignment = null;
  reconcileTracks(side);
  state.reviewSide = state.detectSide;
  setStatus(`Detected ${side.tracks.length} tracks on Side ${state.detectSide}`);
  render();
  return result;
}

function applyTracklistToActiveSide() {
  const side = sideFor(state.detectSide);
  if (!side.audioBuffer) {
    setStatus(`Add audio for Side ${state.detectSide} first`);
    return;
  }
  const parsed = parseTracklist(dom.tracklistInput.value);
  if (!parsed.entries.length) {
    setStatus("No track titles found");
    return;
  }

  if (parsed.albumTitle) state.project.albumTitle = parsed.albumTitle;
  if (parsed.albumArtist) state.project.albumArtist = parsed.albumArtist;
  if (parsed.year) state.project.year = parsed.year;

  const detection = side.candidateGaps.length
    ? {
        candidateGaps: side.candidateGaps,
        suggestedTrimStart: side.trimStart,
        suggestedTrimEnd: side.trimEnd || side.durationSeconds
      }
    : runDetectionForActiveSide();
  if (!detection) return;

  const alignment = alignTracklistDetailed(parsed.entries, detection);
  side.boundaries = alignment.boundaries;
  side.tracklistAlignment = alignment;
  reconcileTracks(side);
  parsed.entries.forEach((entry, index) => {
    if (side.tracks[index]) side.tracks[index].title = entry.title;
  });
  setStatus(`${alignment.summary} Applied ${parsed.entries.length} track titles.`);
  render();
}

async function applyLabelFileToActiveSide() {
  const side = sideFor(state.detectSide);
  const file = dom.labelFileInput.files[0];
  if (!file) return;
  if (!side.audioBuffer) {
    setStatus(`Add audio for Side ${state.detectSide} first`);
    return;
  }
  const text = await file.text();
  const labels = parseAudacityLabels(text);
  const applied = applyAudacityLabels(labels, side.durationSeconds);
  if (!applied) {
    setStatus("No Audacity labels found");
    return;
  }
  side.boundaries = applied.boundaries;
  side.trimStart = applied.trimStart;
  side.trimEnd = applied.trimEnd;
  reconcileTracks(side);
  applied.titles.forEach((title, index) => {
    if (side.tracks[index]) side.tracks[index].title = title;
  });
  setStatus(`Applied ${labels.length} labels`);
  render();
}

function updateAlbumFromFields() {
  state.project.albumTitle = dom.albumTitleInput.value;
  state.project.albumArtist = dom.albumArtistInput.value;
  state.project.year = dom.yearInput.value ? Number(dom.yearInput.value) : "";
  state.project.genre = dom.genreInput.value;
  state.project.discNumber = Math.max(1, Number(dom.discNumberInput.value) || 1);
  state.project.discTotal = Math.max(1, Number(dom.discTotalInput.value) || 1);
  renderTrackViews();
}

async function updateArtwork() {
  const file = dom.artworkInput.files[0];
  if (!file) return;
  state.project.artwork = {
    name: file.name,
    type: file.type || "application/octet-stream",
    dataUrl: await readFileAsDataURL(file),
    bytes: new Uint8Array(await file.arrayBuffer())
  };
  renderArtwork();
}

function addMarker() {
  const side = sideFor(state.reviewSide);
  const segments = getSegments(side);
  if (!segments.length) return;
  let longest = segments[0];
  for (const segment of segments) {
    if (segment.end - segment.start > longest.end - longest.start) longest = segment;
  }
  const time = (longest.start + longest.end) / 2;
  side.boundaries.push(time);
  side.boundaries.sort((a, b) => a - b);
  state.selectedMarker = {
    type: "boundary",
    index: side.boundaries.findIndex((boundary) => boundary === time)
  };
  reconcileTracks(side);
  render();
}

function deleteSelectedMarker() {
  const side = sideFor(state.reviewSide);
  if (state.selectedMarker?.type !== "boundary") return;
  side.boundaries.splice(state.selectedMarker.index, 1);
  state.selectedMarker = null;
  reconcileTracks(side);
  render();
}

async function playSelectedTrack() {
  const side = sideFor(state.reviewSide);
  if (!side.audioBuffer) return;
  const segments = getSegments(side);
  if (!segments.length) return;
  const index = state.selectedMarker?.type === "boundary"
    ? clamp(state.selectedMarker.index, 0, segments.length - 1)
    : 0;
  const segment = segments[index];
  stopPlayback();
  state.playbackContext = state.playbackContext || new AudioContext();
  const source = state.playbackContext.createBufferSource();
  source.buffer = side.audioBuffer;
  source.connect(state.playbackContext.destination);
  source.start(0, segment.start, segment.end - segment.start);
  state.playbackSource = source;
  source.onended = () => {
    if (state.playbackSource === source) state.playbackSource = null;
  };
}

function stopPlayback() {
  if (state.playbackSource) {
    try {
      state.playbackSource.stop();
    } catch {
      // Already stopped.
    }
    state.playbackSource = null;
  }
}

function handleTrackInput(event) {
  const input = event.target;
  if (!input.matches("[data-track-field]")) return;
  const side = sideFor(input.dataset.side);
  const track = side.tracks[Number(input.dataset.trackIndex)];
  if (!track) return;
  track[input.dataset.trackField] = input.value;
  renderReadoutLists();
}

function handleWaveformPointerDown(event) {
  const side = sideFor(state.reviewSide);
  if (!side.audioBuffer) return;
  const marker = markerAtEvent(event, side);
  if (marker) {
    state.selectedMarker = marker;
    state.draggingMarker = marker;
    dom.waveformCanvas.setPointerCapture(event.pointerId);
  } else {
    state.selectedMarker = null;
  }
  drawWaveform();
}

function handleWaveformPointerMove(event) {
  if (!state.draggingMarker) return;
  const side = sideFor(state.reviewSide);
  const rect = dom.waveformCanvas.getBoundingClientRect();
  const time = clamp(((event.clientX - rect.left) / rect.width) * side.durationSeconds, 0, side.durationSeconds);
  updateMarkerTime(side, state.draggingMarker, time);
  reconcileTracks(side);
  renderTrackViews();
  drawWaveform();
}

function handleWaveformPointerUp(event) {
  if (state.draggingMarker) {
    try {
      dom.waveformCanvas.releasePointerCapture(event.pointerId);
    } catch {
      // Pointer may already be released by the browser.
    }
  }
  state.draggingMarker = null;
}

async function exportAlbumZip() {
  const tracks = getExportTracks();
  if (!tracks.length) {
    setStatus("Add at least one side before exporting");
    return;
  }

  const albumName = sanitizeFileName(state.project.albumTitle, "Untitled Album");
  const artistName = sanitizeFileName(state.project.albumArtist, "Unknown Artist");
  const folder = `${artistName}/${albumName}`;
  const entries = [];
  const cropSettings = getSilenceCropSettings();
  state.lastSilenceCropSummary = null;
  const options = {
    normalize: dom.normalizeInput.checked,
    normalizeTargetDB: -1,
    fadeInMilliseconds: Number(dom.fadeInInput.value) || 0,
    fadeOutMilliseconds: Number(dom.fadeOutInput.value) || 0
  };
  const totalSteps = tracks.length + (dom.originalsInput.checked ? recordedSides().length : 0) + 3;
  let completed = 0;
  const cropSummary = { count: 0, removedSeconds: 0 };

  setExportProgress(0, "Preparing audio");
  await nextFrame();

  const playlist = [];
  for (const track of tracks) {
    const title = effectiveTrackTitle(track.info, track.number);
    const fileName = `${String(track.number).padStart(2, "0")} - ${sanitizeFileName(title)}.wav`;
    const skipRanges = cropSettings.enabled
      ? detectLongSilenceRanges(track.side.audioBuffer, cropSettings, track.segment.start, track.segment.end)
      : [];
    const trackCropSummary = summarizeSilenceCrop(skipRanges);
    cropSummary.count += trackCropSummary.count;
    cropSummary.removedSeconds += trackCropSummary.removedSeconds;
    const trackOptions = {
      ...options,
      skipRanges,
      gainLinear: dom.matchLoudnessInput.checked && !options.normalize
        ? masteringGainForTrack(track.side.audioBuffer, track.segment.start, track.segment.end)
        : 1
    };
    const wav = encodeSegmentToWav(track.side.audioBuffer, track.segment.start, track.segment.end, trackOptions);
    entries.push({ path: `${folder}/${fileName}`, data: wav });
    playlist.push(fileName);
    completed += 1;
    const cropText = trackCropSummary.removedSeconds > 0
      ? `, cropped ${formatTime(trackCropSummary.removedSeconds)}`
      : "";
    setExportProgress(completed / totalSteps, `Encoded ${fileName}${cropText}`);
    await nextFrame();
  }

  state.lastSilenceCropSummary = cropSummary;
  renderSilenceCropStatus();

  if (dom.playlistInput.checked) {
    entries.push({ path: `${folder}/${albumName}.m3u`, data: playlist.join("\n") + "\n" });
  }

  if (state.project.artwork?.bytes) {
    const extension = extensionForArtwork(state.project.artwork.name, state.project.artwork.type);
    entries.push({ path: `${folder}/Album Artwork.${extension}`, data: state.project.artwork.bytes });
  }

  if (dom.originalsInput.checked) {
    for (const side of recordedSides()) {
      const originalBuffer = side.originalAudioBuffer || side.audioBuffer;
      const wav = encodeAudioBufferToWav(originalBuffer, { fadeInMilliseconds: 0, fadeOutMilliseconds: 0 });
      entries.push({ path: `${folder}/Original Recordings/Side ${side.label}.wav`, data: wav });
      completed += 1;
      setExportProgress(completed / totalSteps, `Added Side ${side.label} original`);
      await nextFrame();
    }
  }

  entries.push({
    path: `${folder}/album-project.json`,
    data: JSON.stringify(serializeProject(), null, 2)
  });

  setExportProgress(0.96, "Packaging ZIP");
  await nextFrame();
  const zip = createZip(entries);
  downloadBlob(zip, `${albumName}.zip`);
  const cropText = cropSettings.enabled && cropSummary.removedSeconds > 0
    ? `; cropped ${formatTime(cropSummary.removedSeconds)} silence`
    : "";
  setExportProgress(1, `Exported ${tracks.length} tracks${cropText}`);
  setStatus(`Exported ${albumName}.zip${cropText}`);
}

function saveProjectFile() {
  const albumName = sanitizeFileName(state.project.albumTitle, "vinyl-project");
  const blob = new Blob([JSON.stringify(serializeProject(), null, 2)], {
    type: "application/json"
  });
  downloadBlob(blob, `${albumName}.vinylweb.json`);
}

async function loadProjectFile() {
  const file = dom.loadProjectInput.files[0];
  if (!file) return;
  try {
    const parsed = JSON.parse(await file.text());
    state.project = createProject();
    state.lastSilenceCropSummary = null;
    state.project.albumTitle = parsed.albumTitle || "";
    state.project.albumArtist = parsed.albumArtist || "";
    state.project.year = parsed.year || "";
    state.project.genre = parsed.genre || "";
    state.project.discNumber = parsed.discNumber || 1;
    state.project.discTotal = parsed.discTotal || 1;
    state.project.levelCheck = parsed.levelCheck || null;
    state.project.noiseFloor = typeof parsed.noiseFloor === "number" ? parsed.noiseFloor : null;
    state.levelStats = state.project.levelCheck;
    state.noiseStats = typeof state.project.noiseFloor === "number"
      ? { noise_floor: state.project.noiseFloor }
      : null;
    if (parsed.exportSettings) {
      const defaultCrop = defaultSilenceCropSettings();
      dom.normalizeInput.checked = Boolean(parsed.exportSettings.normalizePeaks);
      dom.matchLoudnessInput.checked = Boolean(parsed.exportSettings.matchTrackLoudness);
      dom.cropLongSilenceInput.checked = Boolean(parsed.exportSettings.cropLongSilence);
      dom.cropSilenceThresholdInput.value = parsed.exportSettings.cropSilenceThresholdDBFS ?? defaultCrop.thresholdDBFS;
      dom.cropSilenceMinimumInput.value = parsed.exportSettings.cropSilenceMinimumSeconds ?? defaultCrop.minimumSilenceSeconds;
      dom.cropSilencePaddingInput.value = parsed.exportSettings.cropSilencePaddingSeconds ?? defaultCrop.keepPaddingSeconds;
      state.lastSilenceCropSummary = parsed.exportSettings.lastSilenceCropExport || null;
      dom.playlistInput.checked = parsed.exportSettings.createM3UPlaylist !== false;
      dom.originalsInput.checked = parsed.exportSettings.copyOriginalRecordings !== false;
      dom.fadeInInput.value = parsed.exportSettings.fadeInMilliseconds ?? 0;
      dom.fadeOutInput.value = parsed.exportSettings.fadeOutMilliseconds ?? 15;
    }
    SIDE_LABELS.forEach((label) => {
      const saved = parsed.sides?.[label] || {};
      const side = state.project.sides[label];
      side.sourceName = saved.sourceName || "";
      side.sourceType = saved.sourceType || "empty";
      side.durationSeconds = saved.durationSeconds || 0;
      side.sampleRate = saved.sampleRate || 0;
      side.channelCount = saved.channelCount || 0;
      side.trimStart = saved.trimStart || 0;
      side.trimEnd = saved.trimEnd || 0;
      side.boundaries = Array.isArray(saved.boundaries) ? saved.boundaries : [];
      side.tracks = Array.isArray(saved.tracks) ? saved.tracks : [];
      side.detectionSettings = saved.detectionSettings || defaultDetectionSettings();
      side.tracklistAlignment = saved.tracklistAlignment || null;
      side.recordingGap = saved.recordingGap || saved.gap_listener || null;
      side.recordingStats = saved.recordingStats || saved.recording_statistics || null;
      side.importAnalysis = saved.importAnalysis || null;
      side.importOptimization = saved.importOptimization || null;
    });
    setStatus("Project metadata loaded");
    render();
  } catch (error) {
    setStatus(`Could not load project: ${error.message}`);
  } finally {
    dom.loadProjectInput.value = "";
  }
}

function serializeProject() {
  const cropSettings = getSilenceCropSettings();
  return {
    version: state.project.version,
    savedAt: new Date().toISOString(),
    albumTitle: state.project.albumTitle,
    albumArtist: state.project.albumArtist,
    year: state.project.year || null,
    genre: state.project.genre,
    discNumber: state.project.discNumber,
    discTotal: state.project.discTotal,
    hasArtwork: Boolean(state.project.artwork),
    levelCheck: state.project.levelCheck,
    noiseFloor: state.project.noiseFloor,
    exportSettings: {
      normalizePeaks: dom.normalizeInput.checked,
      matchTrackLoudness: dom.matchLoudnessInput.checked,
      cropLongSilence: cropSettings.enabled,
      cropSilenceThresholdDBFS: cropSettings.thresholdDBFS,
      cropSilenceMinimumSeconds: cropSettings.minimumSilenceSeconds,
      cropSilencePaddingSeconds: cropSettings.keepPaddingSeconds,
      lastSilenceCropExport: state.lastSilenceCropSummary,
      createM3UPlaylist: dom.playlistInput.checked,
      copyOriginalRecordings: dom.originalsInput.checked,
      fadeInMilliseconds: Number(dom.fadeInInput.value) || 0,
      fadeOutMilliseconds: Number(dom.fadeOutInput.value) || 0
    },
    sides: Object.fromEntries(
      SIDE_LABELS.map((label) => {
        const side = sideFor(label);
        return [
          label,
          {
            sourceName: side.sourceName,
            sourceType: side.sourceType,
            hasAudioInCurrentSession: Boolean(side.audioBuffer),
            hasOriginalAudioInCurrentSession: Boolean(side.originalAudioBuffer),
            durationSeconds: side.durationSeconds,
            sampleRate: side.sampleRate,
            channelCount: side.channelCount,
            trimStart: side.trimStart,
            trimEnd: side.trimEnd,
            boundaries: side.boundaries,
            tracks: side.tracks,
            detectionSettings: side.detectionSettings,
            tracklistAlignment: side.tracklistAlignment,
            recordingGap: side.recordingGap,
            importAnalysis: side.importAnalysis,
            importOptimization: side.importOptimization,
            recordingStats: side.recordingStats,
            recording_statistics: exportRecordingStatistics(side.recordingStats)
          }
        ];
      })
    )
  };
}

function render() {
  document.querySelectorAll(".step-tab").forEach((button) => {
    button.classList.toggle("is-active", button.dataset.step === state.activeStep);
  });
  document.querySelectorAll(".stage").forEach((stage) => {
    stage.classList.toggle("is-active", stage.id === `stage-${state.activeStep}`);
  });
  document.querySelectorAll(".side-toggle").forEach((button) => {
    const targetSide = button.dataset.sideTarget === "detect" ? state.detectSide : state.reviewSide;
    button.classList.toggle("is-active", button.dataset.side === targetSide);
  });

  renderSummaries();
  renderMonitorControls();
  renderQualityAnalysis();
  renderRecordControls();
  renderDetectionSettings();
  renderTracklistAlignmentStatus();
  renderAlbumFields();
  renderArtwork();
  renderTrackViews();
  renderSilenceCropStatus();
  renderRecordingInputStatus();
  requestAnimationFrame(drawWaveform);
}

function renderSummaries() {
  const html = SIDE_LABELS.map((label) => {
    const side = sideFor(label);
    const ready = Boolean(side.audioBuffer);
    const text = ready ? `Side ${label}: ${formatTime(side.durationSeconds)}` : `Side ${label}: empty`;
    return `<span class="side-pill ${ready ? "is-ready" : ""}">${text}</span>`;
  }).join("");
  dom.sideSummaryAdd.innerHTML = html;
  dom.sideSummaryRecord.innerHTML = html;
  dom.sideSummaryDetails.innerHTML = html;
  dom.sideSummaryExport.innerHTML = html;
  dom.sideAFileName.textContent = sideFor("A").sourceName || "Choose file";
  dom.sideBFileName.textContent = sideFor("B").sourceName || "Choose file";
}

function renderRecordControls() {
  const recording = Boolean(state.recorder);
  dom.recordSideAButton.disabled = recording;
  dom.recordSideBButton.disabled = recording;
  dom.stopRecordingButton.disabled = !recording;
  if (!recording) {
    dom.recordingClock.textContent = "00:00";
    renderRecordingGapStatus(null);
  }
}

function renderDetectionSettings() {
  const side = sideFor(state.detectSide);
  const settings = side.detectionSettings;
  dom.thresholdInput.value = settings.silenceThresholdDB;
  dom.gapInput.value = settings.minimumGapSeconds;
  dom.trackMinInput.value = settings.minimumTrackSeconds;
  dom.thresholdOutput.textContent = `${settings.silenceThresholdDB} dB`;
  dom.gapOutput.textContent = `${Number(settings.minimumGapSeconds).toFixed(1)} s`;
  dom.trackMinOutput.textContent = `${Math.round(settings.minimumTrackSeconds)} s`;
  document.querySelectorAll("[data-preset]").forEach((button) => {
    button.classList.toggle("is-active", button.dataset.preset === settings.preset);
  });
  const result = side.effectiveThresholdDB == null
    ? "No detection run yet."
    : `${side.tracks.length} tracks, threshold ${formatDB(side.effectiveThresholdDB)}.`;
  dom.detectResultText.textContent = result;
}

function renderTracklistAlignmentStatus() {
  const alignment = sideFor(state.detectSide).tracklistAlignment;
  if (!alignment) {
    dom.tracklistAlignmentStatus.innerHTML = "<strong>Runtime guidance</strong><span>Paste runtimes to check speed drift and confidence.</span>";
    return;
  }
  const low = alignment.alignments?.filter((item) => item.confidence === "low").length || 0;
  const medium = alignment.alignments?.filter((item) => item.confidence === "medium").length || 0;
  const drift = typeof alignment.scale === "number"
    ? ((1 / alignment.scale - 1) * 100)
    : null;
  const driftText = typeof drift === "number"
    ? `Speed/pitch drift estimate: ${drift >= 0 ? "+" : ""}${drift.toFixed(2)}%.`
    : "No runtime drift estimate.";
  const reviewText = low > 0
    ? `${low} low-confidence split${low === 1 ? "" : "s"} should be reviewed.`
    : medium > 0
      ? `${medium} medium-confidence split${medium === 1 ? "" : "s"} worth a quick listen.`
      : "All runtime-guided splits look strong.";
  dom.tracklistAlignmentStatus.innerHTML = `<strong>${escapeHTML(alignment.summary)}</strong><span>${escapeHTML(driftText)} ${escapeHTML(reviewText)}</span>`;
}

function renderAlbumFields() {
  if (document.activeElement !== dom.albumTitleInput) dom.albumTitleInput.value = state.project.albumTitle;
  if (document.activeElement !== dom.albumArtistInput) dom.albumArtistInput.value = state.project.albumArtist;
  if (document.activeElement !== dom.yearInput) dom.yearInput.value = state.project.year || "";
  if (document.activeElement !== dom.genreInput) dom.genreInput.value = state.project.genre;
  if (document.activeElement !== dom.discNumberInput) dom.discNumberInput.value = state.project.discNumber;
  if (document.activeElement !== dom.discTotalInput) dom.discTotalInput.value = state.project.discTotal;
}

function renderArtwork() {
  if (state.project.artwork?.dataUrl) {
    dom.artworkPreview.src = state.project.artwork.dataUrl;
    dom.artworkPreview.hidden = false;
    dom.artworkText.hidden = true;
  } else {
    dom.artworkPreview.hidden = true;
    dom.artworkText.hidden = false;
  }
}

function renderTrackViews() {
  renderEditableTrackList(dom.reviewTrackList, sideFor(state.reviewSide));
  renderReadoutTrackList(dom.detectTrackList, sideFor(state.detectSide), true);
  renderEditableAlbumTracks();
  renderReadoutTrackList(dom.exportTrackList, null, true, getExportTracks());
}

function renderReadoutLists() {
  renderReadoutTrackList(dom.detectTrackList, sideFor(state.detectSide), true);
  renderReadoutTrackList(dom.exportTrackList, null, true, getExportTracks());
}

function renderEditableTrackList(container, side) {
  container.innerHTML = "";
  const segments = getSegments(side);
  if (!segments.length) {
    container.append(emptyState("No tracks yet"));
    return;
  }
  reconcileTracks(side);
  segments.forEach((segment, index) => {
    container.append(trackRow(side, index, globalTrackNumber(side.label, index), segment));
  });
}

function renderEditableAlbumTracks() {
  dom.albumTrackList.innerHTML = "";
  const tracks = getExportTracks();
  if (!tracks.length) {
    dom.albumTrackList.append(emptyState("No tracks yet"));
    return;
  }
  tracks.forEach((track) => {
    dom.albumTrackList.append(trackRow(track.side, track.index, track.number, track.segment));
  });
}

function renderReadoutTrackList(container, side, compact = false, tracks = null) {
  container.innerHTML = "";
  const rows = tracks || getSideReadoutRows(side);
  if (!rows.length) {
    container.append(emptyState("No tracks yet"));
    return;
  }
  rows.forEach((row) => {
    const element = document.createElement("div");
    element.className = "readout-row";
    const title = effectiveTrackTitle(row.info, row.number);
    const confidence = row.splitConfidence
      ? `<span class="confidence-badge ${row.splitConfidence.confidence}">${row.splitConfidence.confidence}</span>`
      : "";
    element.innerHTML = compact
      ? `<span class="track-number">${String(row.number).padStart(2, "0")}</span><span class="track-duration">${formatTime(row.segment.end - row.segment.start)}</span><span>${escapeHTML(title)}</span>${confidence}`
      : `<span class="track-number">${String(row.number).padStart(2, "0")}</span><span class="track-duration">${formatTime(row.segment.end - row.segment.start)}</span><span>${escapeHTML(title)}</span><span>${confidence || escapeHTML(row.info.artist || "")}</span>`;
    if (row.splitConfidence?.note) {
      element.title = row.splitConfidence.note;
    }
    container.append(element);
  });
}

function trackRow(side, index, number, segment) {
  const template = byId("trackRowTemplate");
  const row = template.content.firstElementChild.cloneNode(true);
  const info = side.tracks[index] || { title: "", artist: "" };
  row.querySelector(".track-number").textContent = String(number).padStart(2, "0");
  row.querySelector(".track-duration").textContent = formatTime(segment.end - segment.start);
  const titleInput = row.querySelector(".track-title-input");
  const artistInput = row.querySelector(".track-artist-input");
  titleInput.value = info.title || "";
  artistInput.value = info.artist || "";
  titleInput.dataset.side = side.label;
  titleInput.dataset.trackIndex = index;
  titleInput.dataset.trackField = "title";
  artistInput.dataset.side = side.label;
  artistInput.dataset.trackIndex = index;
  artistInput.dataset.trackField = "artist";
  return row;
}

function drawWaveform() {
  if (state.activeStep !== "review") return;
  const canvas = dom.waveformCanvas;
  const side = sideFor(state.reviewSide);
  const rect = canvas.getBoundingClientRect();
  if (!rect.width || !rect.height) return;
  const dpr = window.devicePixelRatio || 1;
  canvas.width = Math.floor(rect.width * dpr);
  canvas.height = Math.floor(rect.height * dpr);
  const ctx = canvas.getContext("2d");
  ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
  const width = rect.width;
  const height = rect.height;
  ctx.clearRect(0, 0, width, height);
  ctx.fillStyle = "#fbfcfa";
  ctx.fillRect(0, 0, width, height);

  if (!side.audioBuffer || !side.peaks.length) {
    ctx.fillStyle = "#626d68";
    ctx.textAlign = "center";
    ctx.textBaseline = "middle";
    ctx.font = "15px system-ui, sans-serif";
    ctx.fillText("No waveform", width / 2, height / 2);
    return;
  }

  const center = height * 0.52;
  const amplitude = height * 0.42;
  ctx.strokeStyle = "#d8ded8";
  ctx.lineWidth = 1;
  ctx.beginPath();
  ctx.moveTo(0, center);
  ctx.lineTo(width, center);
  ctx.stroke();

  ctx.fillStyle = "#27342f";
  for (let x = 0; x < width; x += 1) {
    const index = Math.floor((x / width) * side.peaks.length);
    const peak = side.peaks[index] || { min: 0, max: 0 };
    const y1 = center - peak.max * amplitude;
    const y2 = center - peak.min * amplitude;
    ctx.fillRect(x, y1, 1, Math.max(1, y2 - y1));
  }

  const duration = side.durationSeconds || 1;
  drawMarker(ctx, side.trimStart, duration, width, height, "#2f7f4f", "Start", state.selectedMarker?.type === "trimStart");
  side.boundaries.forEach((time, index) => {
    drawMarker(
      ctx,
      time,
      duration,
      width,
      height,
      "#c49326",
      String(index + 1),
      state.selectedMarker?.type === "boundary" && state.selectedMarker.index === index
    );
  });
  drawMarker(ctx, side.trimEnd || duration, duration, width, height, "#c43c32", "End", state.selectedMarker?.type === "trimEnd");
}

function drawMarker(ctx, time, duration, width, height, color, label, selected) {
  const x = clamp((time / duration) * width, 0, width);
  ctx.strokeStyle = color;
  ctx.lineWidth = selected ? 3 : 2;
  ctx.beginPath();
  ctx.moveTo(x, 0);
  ctx.lineTo(x, height);
  ctx.stroke();
  ctx.fillStyle = selected ? color : "#ffffff";
  ctx.strokeStyle = color;
  ctx.beginPath();
  ctx.arc(x, 20, 9, 0, Math.PI * 2);
  ctx.fill();
  ctx.stroke();
  ctx.fillStyle = selected ? "#ffffff" : color;
  ctx.font = "700 10px system-ui, sans-serif";
  ctx.textAlign = "center";
  ctx.textBaseline = "middle";
  ctx.fillText(label, x, 20);
}

function markerAtEvent(event, side) {
  const rect = dom.waveformCanvas.getBoundingClientRect();
  const x = event.clientX - rect.left;
  const duration = side.durationSeconds || 1;
  const markerX = (time) => (time / duration) * rect.width;
  const candidates = [
    { type: "trimStart", index: -1, time: side.trimStart },
    ...side.boundaries.map((time, index) => ({ type: "boundary", index, time })),
    { type: "trimEnd", index: -1, time: side.trimEnd || duration }
  ];
  return candidates.find((candidate) => Math.abs(markerX(candidate.time) - x) <= 12) || null;
}

function updateMarkerTime(side, marker, time) {
  const minimumGap = 0.25;
  const end = side.trimEnd || side.durationSeconds;
  if (marker.type === "trimStart") {
    const next = side.boundaries[0] ?? end;
    side.trimStart = clamp(time, 0, Math.max(0, next - minimumGap));
    return;
  }
  if (marker.type === "trimEnd") {
    const previous = side.boundaries[side.boundaries.length - 1] ?? side.trimStart;
    side.trimEnd = clamp(time, Math.min(side.durationSeconds, previous + minimumGap), side.durationSeconds);
    return;
  }
  side.boundaries[marker.index] = clamp(time, side.trimStart + minimumGap, end - minimumGap);
  side.boundaries.sort((a, b) => a - b);
  marker.index = side.boundaries.findIndex((boundary) => Math.abs(boundary - time) < 0.01);
  if (marker.index < 0) {
    marker.index = side.boundaries.findIndex((boundary) => boundary >= time);
  }
}

function getDecodeContext() {
  state.decodeContext = state.decodeContext || new AudioContext();
  return state.decodeContext;
}

function updateMeters(values) {
  const left = values[0] ?? -120;
  const right = values[1] ?? left;
  dom.meterLeft.style.width = `${meterPercent(left)}%`;
  dom.meterRight.style.width = `${meterPercent(right)}%`;
  dom.meterLeftText.textContent = formatDB(left);
  dom.meterRightText.textContent = formatDB(right);
}

function updateMetersFromStats(stats) {
  updateMeters([stats.peak_l_dbfs, stats.peak_r_dbfs]);
}

function renderLiveLevelStats(stats) {
  dom.levelPeakReadout.textContent = `${formatDB(stats.peak_l_dbfs)} / ${formatDB(stats.peak_r_dbfs)}`;
  dom.levelRmsReadout.textContent = `${formatDB(stats.rms_dbfs)}`;
  dom.levelShortTermReadout.textContent = `${formatDB(stats.short_term_average_dbfs)}`;
  dom.levelClipReadout.textContent = String(stats.clipping_count || 0);
}

function renderMonitorControls() {
  const active = Boolean(state.monitor);
  dom.startMonitorButton.disabled = active;
  dom.stopMonitorButton.disabled = !active;
  dom.analyzeLevelsButton.disabled = Boolean(state.activeCapture);
  dom.measureNoiseButton.disabled = Boolean(state.activeCapture);
}

function renderQualityAnalysis() {
  const stats = state.levelStats || state.project.levelCheck;
  const noise = state.noiseStats || (
    typeof state.project.noiseFloor === "number"
      ? { noise_floor: state.project.noiseFloor }
      : null
  );
  const combined = stats ? mergeQualityStats(stats, noise || {}) : null;
  const score = combined?.score || calculateRecordingScore(noise || {});
  setScoreClass(dom.overallQualityScore, score.overall);
  dom.overallQualityScore.textContent = combined ? `${score.overall} / 100` : "-- / 100";

  dom.analysisPeak.textContent = combined ? formatDB(combined.peak_dbfs) : "Not measured";
  dom.analysisRms.textContent = combined ? formatDB(combined.rms_dbfs) : "Not measured";
  dom.analysisDynamicRange.textContent = combined ? `${combined.dynamic_range.toFixed(1)} dB` : "Not measured";
  dom.analysisClips.textContent = combined ? String(combined.clipping_count || 0) : "Not measured";
  setLevelClass(dom.analysisPeak, combined?.peak_dbfs);
  setLevelClass(dom.analysisClips, combined && (combined.clipping_count || 0) > 0 ? 0 : -12);

  dom.qualityBreakdown.innerHTML = "";
  [
    ["Input Level", score.input_level],
    ["Noise Floor", score.noise_floor],
    ["Stereo Balance", score.stereo_balance],
    ["Clipping", score.clipping]
  ].forEach(([label, value]) => {
    const row = document.createElement("div");
    row.innerHTML = `<span>${label}</span><strong>${escapeHTML(value)}</strong>`;
    dom.qualityBreakdown.append(row);
  });

  renderNoiseFloor(noise);
  renderProblems(combined || noise || {});
  renderRecommendations(combined || noise || {});
}

function renderNoiseFloor(noise) {
  dom.noiseFloorCard.classList.remove("is-good", "is-warn", "is-bad");
  if (!noise || typeof noise.noise_floor !== "number") {
    dom.noiseFloorCard.innerHTML = "<strong>Not measured</strong><span>Measure 5 seconds with the stylus on the record or between tracks.</span>";
    return;
  }
  const rating = noise.noise_floor_rating || calculateRecordingScore({ noise_floor: noise.noise_floor }).noise_floor;
  dom.noiseFloorCard.classList.add(noise.noise_floor < -45 ? "is-good" : noise.noise_floor < -35 ? "is-warn" : "is-bad");
  dom.noiseFloorCard.innerHTML = `<strong>${formatDB(noise.noise_floor)} · ${escapeHTML(rating)}</strong><span>Preferred vinyl target is below -45 dBFS.</span>`;
}

function renderProblems(stats) {
  const problems = [];
  if ((stats.clipping_count || 0) > 0 || (stats.peak_dbfs ?? -120) >= 0) {
    problems.push("Clipping detected.");
  } else if ((stats.peak_dbfs ?? -120) > -3) {
    problems.push("Peaks are above -3 dBFS.");
  }
  if (stats.hum_detected) problems.push("Excessive 60 Hz hum detected.");
  if (stats.stereo_status === "mono") problems.push("Input appears mono or dual-mono.");
  if (stats.stereo_status === "imbalance" || stats.stereo_status === "severe_imbalance") problems.push("Channel imbalance detected.");
  if (stats.stereo_status === "disconnected") problems.push("One RCA channel appears disconnected.");
  if (stats.dc_offset_detected) problems.push("DC offset detected.");
  if (stats.excessive_hiss) problems.push("Excessive high-frequency hiss detected.");
  if (typeof stats.noise_floor === "number" && stats.noise_floor > -35) problems.push("Surface noise is poor.");

  dom.problemList.innerHTML = "";
  if (!problems.length) {
    dom.problemList.append(readoutCard("No problems detected yet."));
    return;
  }
  problems.forEach((problem) => dom.problemList.append(readoutCard(problem)));
}

function renderRecommendations(stats) {
  dom.recommendationList.innerHTML = "";
  generateRecordingRecommendations(stats).forEach((recommendation) => {
    dom.recommendationList.append(readoutCard(recommendation));
  });
}

function renderRecordingDiagnostics(stats) {
  dom.recordingPeakReadout.textContent = `${formatDB(stats.peak_l_dbfs)} / ${formatDB(stats.peak_r_dbfs)}`;
  dom.recordingRmsReadout.textContent = formatDB(stats.short_term_average_dbfs);
  dom.recordingClipCount.textContent = String(stats.clipping_count || 0);
  dom.recordingNoiseFloor.textContent = typeof stats.noise_floor === "number" ? formatDB(stats.noise_floor) : "Not measured";
  const score = calculateRecordingScore(stats);
  dom.recordingQualityScore.textContent = `${score.overall} / 100`;
  dom.recordingProblemStatus.textContent = generateProblemSummary(stats);
  renderRecordingGapStatus(stats.gap_listener || state.recordingGapSnapshot);
}

function renderRecordingGapStatus(gap) {
  if (!gap) {
    dom.recordingGapStatus.textContent = "Waiting";
    dom.recordingTrimSuggestion.textContent = "Not set";
    return;
  }
  dom.recordingGapStatus.textContent = gap.status;
  const trimStart = gap.suggestedTrimStart ?? 0;
  const trimEnd = gap.suggestedTrimEnd;
  dom.recordingTrimSuggestion.textContent = trimEnd == null
    ? `Start ${formatTime(trimStart)}`
    : `${formatTime(trimStart)} - ${formatTime(trimEnd)}`;
}

async function updateStorageEstimate() {
  if (!navigator.storage?.estimate) {
    dom.recordingStorage.textContent = "Not reported";
    return;
  }
  const estimate = await navigator.storage.estimate();
  if (!estimate.quota) {
    dom.recordingStorage.textContent = "Not reported";
    return;
  }
  const remaining = Math.max(0, estimate.quota - (estimate.usage || 0));
  dom.recordingStorage.textContent = formatBytes(remaining);
}

function createSampleCollector(sampleRate, channelCount, maxSeconds = null) {
  const chunks = Array.from({ length: channelCount }, () => []);
  const maxFrames = maxSeconds ? Math.floor(sampleRate * maxSeconds) : Infinity;
  return {
    sampleRate,
    channelCount,
    frameCount: 0,
    chunks,
    addFrame(channels) {
      channels.forEach((channel, index) => {
        if (!chunks[index]) chunks[index] = [];
        chunks[index].push(new Float32Array(channel));
      });
      this.frameCount += channels[0]?.length || 0;
      while (this.frameCount > maxFrames) {
        const first = chunks[0][0];
        const removed = first?.length || 0;
        chunks.forEach((channelChunks) => channelChunks.shift());
        this.frameCount -= removed;
      }
    },
    toChannelData() {
      return chunks.map((channelChunks) => {
        const data = new Float32Array(this.frameCount);
        let offset = 0;
        for (const chunk of channelChunks) {
          data.set(chunk.subarray(0, Math.min(chunk.length, data.length - offset)), offset);
          offset += chunk.length;
          if (offset >= data.length) break;
        }
        return data;
      });
    }
  };
}

function setScoreClass(element, score) {
  element.classList.remove("is-good", "is-warn", "is-bad");
  element.classList.add(score >= 85 ? "is-good" : score >= 70 ? "is-warn" : "is-bad");
}

function setLevelClass(element, level) {
  element.classList.remove("is-good", "is-warn", "is-bad");
  if (typeof level !== "number") return;
  element.classList.add(level >= -12 && level <= -6 ? "is-good" : level > -3 || level < -18 ? "is-bad" : "is-warn");
}

function readoutCard(text) {
  const element = document.createElement("div");
  element.textContent = text;
  return element;
}

function generateProblemSummary(stats) {
  if ((stats.clipping_count || 0) > 0) return "Clipping";
  if (stats.hum_detected) return "Hum detected";
  if (stats.stereo_status === "disconnected") return "Channel disconnected";
  if (stats.stereo_status === "imbalance" || stats.stereo_status === "severe_imbalance") return "Imbalance";
  if (stats.dc_offset_detected) return "DC offset";
  return "Recording cleanly";
}

function formatBytes(bytes) {
  if (!Number.isFinite(bytes)) return "Not reported";
  const units = ["B", "KB", "MB", "GB", "TB"];
  let value = bytes;
  let unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit += 1;
  }
  return `${value >= 10 ? value.toFixed(0) : value.toFixed(1)} ${units[unit]}`;
}

function setStep(step) {
  state.activeStep = step;
  render();
}

function setStatus(message) {
  dom.statusLine.textContent = message;
}

function setExportProgress(value, message) {
  dom.exportProgress.value = clamp(value, 0, 1);
  dom.exportStatus.textContent = message;
}

function sideFor(label) {
  return state.project.sides[label];
}

function recordedSides() {
  return SIDE_LABELS.map(sideFor).filter((side) => side.audioBuffer);
}

function getSegments(side) {
  if (!side?.audioBuffer) return [];
  const duration = side.durationSeconds || side.audioBuffer.duration;
  const end = side.trimEnd > 0 ? Math.min(side.trimEnd, duration) : duration;
  const points = [clamp(side.trimStart || 0, 0, duration)];
  for (const boundary of side.boundaries) {
    if (boundary > points[0] && boundary < end) points.push(boundary);
  }
  points.push(end);
  points.sort((a, b) => a - b);
  const segments = [];
  for (let index = 0; index < points.length - 1; index += 1) {
    if (points[index + 1] > points[index]) {
      segments.push({ start: points[index], end: points[index + 1] });
    }
  }
  return segments;
}

function reconcileTracks(side) {
  if (!side.audioBuffer) return;
  const needed = getSegments(side).length;
  while (side.tracks.length < needed) {
    side.tracks.push({ title: "", artist: "" });
  }
  if (side.tracks.length > needed) {
    side.tracks.splice(needed);
  }
}

function getSideReadoutRows(side) {
  if (!side) return [];
  reconcileTracks(side);
  return getSegments(side).map((segment, index) => ({
    side,
    index,
    number: globalTrackNumber(side.label, index),
    segment,
    info: side.tracks[index] || { title: "", artist: "" },
    splitConfidence: index > 0 ? side.tracklistAlignment?.alignments?.[index - 1] : null
  }));
}

function getExportTracks() {
  const tracks = [];
  let number = 1;
  for (const label of SIDE_LABELS) {
    const side = sideFor(label);
    reconcileTracks(side);
    getSegments(side).forEach((segment, index) => {
      tracks.push({
        side,
        sideLabel: label,
        index,
        number,
        segment,
        info: side.tracks[index] || { title: "", artist: "" }
      });
      number += 1;
    });
  }
  return tracks;
}

function globalTrackNumber(sideLabel, indexOnSide) {
  let number = 1;
  for (const label of SIDE_LABELS) {
    if (label === sideLabel) return number + indexOnSide;
    number += getSegments(sideFor(label)).length;
  }
  return indexOnSide + 1;
}

function effectiveTrackTitle(info, number) {
  const title = (info?.title || "").trim();
  return title || `Track ${String(number).padStart(2, "0")}`;
}

function exportRecordingStatistics(stats) {
  if (!stats) return null;
  return {
    peak_dbfs: stats.peak_dbfs,
    rms_dbfs: stats.rms_dbfs,
    dynamic_range: stats.dynamic_range,
    noise_floor: stats.noise_floor,
    clipping_count: stats.clipping_count,
    hum_detected: stats.hum_detected,
    stereo_balance: stats.stereo_balance,
    gap_listener: stats.gap_listener || null
  };
}

function masteringGainForTrack(audioBuffer, startSeconds, endSeconds) {
  const rmsDBFS = segmentRmsDBFS(audioBuffer, startSeconds, endSeconds);
  if (!Number.isFinite(rmsDBFS)) return 1;
  const targetDBFS = -20;
  const gainDB = clamp(targetDBFS - rmsDBFS, -4, 6);
  return Math.pow(10, gainDB / 20);
}

function segmentRmsDBFS(audioBuffer, startSeconds, endSeconds) {
  const startFrame = clamp(Math.floor(startSeconds * audioBuffer.sampleRate), 0, audioBuffer.length);
  const endFrame = clamp(Math.ceil(endSeconds * audioBuffer.sampleRate), startFrame, audioBuffer.length);
  if (endFrame <= startFrame) return -120;
  let sum = 0;
  let count = 0;
  for (let channel = 0; channel < audioBuffer.numberOfChannels; channel += 1) {
    const data = audioBuffer.getChannelData(channel);
    for (let frame = startFrame; frame < endFrame; frame += 1) {
      sum += data[frame] * data[frame];
      count += 1;
    }
  }
  return dbFromPeak(Math.sqrt(sum / Math.max(count, 1)));
}

function extensionForArtwork(name, type) {
  const extension = String(name || "").split(".").pop()?.toLowerCase();
  if (["jpg", "jpeg", "png", "webp"].includes(extension)) {
    return extension === "jpeg" ? "jpg" : extension;
  }
  if (type === "image/png") return "png";
  if (type === "image/webp") return "webp";
  return "jpg";
}

function emptyState(text) {
  const element = document.createElement("div");
  element.className = "empty-state";
  element.textContent = text;
  return element;
}

function escapeHTML(value) {
  return String(value ?? "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;");
}

function byId(id) {
  return document.getElementById(id);
}

function registerServiceWorker() {
  if ("serviceWorker" in navigator) {
    navigator.serviceWorker.register("./sw.js").catch(() => {});
  }
}
