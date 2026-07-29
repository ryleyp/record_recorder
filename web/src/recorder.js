import { dbFromPeak } from "./utils.js";

const BUFFER_SIZE = 1024;
const STORE_FLUSH_SECONDS = 1;
const RECORDING_DB_NAME = "vinyl-album-recorder-recordings";
const RECORDING_DB_VERSION = 1;
const RECORDING_STORE = "chunks";

function createAudioContext() {
  const AudioContextConstructor = window.AudioContext || window.webkitAudioContext;
  if (!AudioContextConstructor) {
    throw new Error("Audio recording requires a browser with Web Audio support.");
  }
  try {
    return new AudioContextConstructor({ latencyHint: "interactive" });
  } catch {
    return new AudioContextConstructor();
  }
}

function audioInputConstraints(deviceId = "", options = {}) {
  const audio = {
    channelCount: options.requireStereo ? { exact: 2 } : { ideal: 2 },
    sampleRate: { ideal: 48000 },
    echoCancellation: false,
    noiseSuppression: false,
    autoGainControl: false
  };
  if (deviceId) {
    audio.deviceId = { exact: deviceId };
  }
  return audio;
}

async function getAudioInputStream(deviceId = "") {
  try {
    return await navigator.mediaDevices.getUserMedia({
      audio: audioInputConstraints(deviceId, { requireStereo: true }),
      video: false
    });
  } catch (error) {
    if (!isStereoConstraintError(error)) throw error;
    return navigator.mediaDevices.getUserMedia({
      audio: audioInputConstraints(deviceId),
      video: false
    });
  }
}

function isStereoConstraintError(error) {
  return error?.name === "OverconstrainedError"
    || error?.name === "ConstraintNotSatisfiedError"
    || error?.constraint === "channelCount";
}

function streamChannelCount(stream) {
  const count = stream?.getAudioTracks?.()[0]?.getSettings?.().channelCount;
  return Number.isFinite(count) && count > 0 ? Math.min(2, count) : 2;
}

function streamSettings(stream) {
  return stream?.getAudioTracks?.()[0]?.getSettings?.() || {};
}

function frameChannelsFromInput(input) {
  const inputChannelCount = Math.max(1, Math.min(2, input.numberOfChannels || 1));
  const first = new Float32Array(input.getChannelData(0));
  if (inputChannelCount === 1) {
    return [first, new Float32Array(first)];
  }
  return [first, new Float32Array(input.getChannelData(1))];
}

function frameStats(channels) {
  let clippingCount = 0;
  const peaksDBFS = channels.map((channel) => {
    let peak = 0;
    for (let index = 0; index < channel.length; index += 1) {
      const sample = channel[index];
      const abs = Math.abs(sample);
      if (abs > peak) peak = abs;
      if (abs >= 0.999) clippingCount += 1;
    }
    return dbFromPeak(peak);
  });
  return { peaksDBFS, clippingCount };
}

function recorderSessionId() {
  return `recording-${Date.now()}-${Math.random().toString(16).slice(2)}`;
}

export function recordingSupportInfo() {
  return {
    audioWorklet: Boolean(globalThis.AudioWorkletNode),
    indexedDB: Boolean(globalThis.indexedDB),
    wakeLock: Boolean(globalThis.navigator?.wakeLock?.request)
  };
}

export class BrowserRecorder {
  constructor({ onFrame, onMeter, onTick } = {}) {
    this.onFrame = onFrame || (() => {});
    this.onMeter = onMeter || (() => {});
    this.onTick = onTick || (() => {});
    this.stream = null;
    this.context = null;
    this.source = null;
    this.processor = null;
    this.mute = null;
    this.storage = null;
    this.pendingChunks = [];
    this.pendingFrameCount = 0;
    this.storageQueue = Promise.resolve();
    this.channelCount = 0;
    this.sampleRate = 0;
    this.startedAt = 0;
    this.timer = 0;
    this.captureEngine = "Not started";
    this.storageMode = "memory";
    this.inputSettings = {};
  }

  async start(deviceId = "") {
    if (!navigator.mediaDevices?.getUserMedia) {
      throw new Error("Audio recording requires a browser with microphone input support.");
    }

    this.stream = await getAudioInputStream(deviceId);
    this.context = createAudioContext();
    this.sampleRate = this.context.sampleRate;
    this.source = this.context.createMediaStreamSource(this.stream);
    this.channelCount = 2;
    this.inputSettings = streamSettings(this.stream);
    this.pendingChunks = Array.from({ length: this.channelCount }, () => []);
    this.storage = await createRecordingChunkStore(recorderSessionId());
    this.storageMode = this.storage.mode;
    this.mute = this.context.createGain();
    this.mute.gain.value = 0;

    if (!(await this.startAudioWorklet())) {
      this.startScriptProcessor();
    }

    this.mute.connect(this.context.destination);
    this.startedAt = performance.now();
    this.timer = window.setInterval(() => {
      this.onTick((performance.now() - this.startedAt) / 1000);
    }, 250);
  }

  async startAudioWorklet() {
    if (!this.context.audioWorklet || !globalThis.AudioWorkletNode) {
      return false;
    }
    try {
      await this.context.audioWorklet.addModule(new URL("./recording-worklet.js", import.meta.url));
      this.processor = new AudioWorkletNode(this.context, "vinyl-recorder-processor", {
        numberOfInputs: 1,
        numberOfOutputs: 1,
        outputChannelCount: [2]
      });
      this.processor.port.onmessage = (event) => {
        if (event.data?.type !== "frame") return;
        const channels = event.data.channels.map((buffer) => new Float32Array(buffer));
        this.handleFrame(channels, {
          clippingCount: event.data.clippingCount || 0,
          peaksDBFS: event.data.peaksDBFS || null
        });
      };
      this.source.connect(this.processor);
      this.processor.connect(this.mute);
      this.captureEngine = "AudioWorklet";
      return true;
    } catch {
      this.processor = null;
      return false;
    }
  }

  startScriptProcessor() {
    this.processor = this.context.createScriptProcessor(BUFFER_SIZE, streamChannelCount(this.stream), this.channelCount);
    this.processor.onaudioprocess = (event) => {
      this.handleFrame(frameChannelsFromInput(event.inputBuffer));
    };
    this.source.connect(this.processor);
    this.processor.connect(this.mute);
    this.captureEngine = "ScriptProcessor fallback";
  }

  handleFrame(channels, metadata = {}) {
    this.queueFrameForStorage(channels);
    const stats = metadata.peaksDBFS
      ? {
          peaksDBFS: metadata.peaksDBFS,
          clippingCount: metadata.clippingCount || 0
        }
      : frameStats(channels);
    this.onMeter(stats.peaksDBFS);
    this.onFrame({
      channels,
      sampleRate: this.sampleRate,
      channelCount: this.channelCount,
      clippingCount: stats.clippingCount,
      captureEngine: this.captureEngine,
      storageMode: this.storageMode
    });
  }

  queueFrameForStorage(channels) {
    channels.forEach((channel, index) => {
      this.pendingChunks[index].push(new Float32Array(channel));
    });
    this.pendingFrameCount += channels[0]?.length || 0;
    if (this.pendingFrameCount >= this.sampleRate * STORE_FLUSH_SECONDS) {
      this.flushPendingChunks();
    }
  }

  flushPendingChunks() {
    if (!this.pendingFrameCount) return;
    const chunks = this.pendingChunks.map((channelChunks) => channelChunks.splice(0));
    const frameCount = this.pendingFrameCount;
    this.pendingFrameCount = 0;
    this.storageQueue = this.storageQueue.then(() => this.storage.append(chunks, frameCount));
  }

  async stop() {
    window.clearInterval(this.timer);
    if (this.processor) {
      if (this.processor.port) this.processor.port.onmessage = null;
      if (this.processor.onaudioprocess) this.processor.onaudioprocess = null;
      this.processor.disconnect();
    }
    if (this.source) this.source.disconnect();
    if (this.mute) this.mute.disconnect();

    this.flushPendingChunks();
    await this.storageQueue;
    const storedChunks = await this.storage.readAll();
    const frameCount = storedChunks.reduce((sum, chunk) => sum + chunk.frameCount, 0);
    const audioBuffer = this.context.createBuffer(this.channelCount, frameCount, this.sampleRate);
    for (let channel = 0; channel < this.channelCount; channel += 1) {
      const destination = audioBuffer.getChannelData(channel);
      let offset = 0;
      for (const chunk of storedChunks) {
        destination.set(chunk.channels[channel], offset);
        offset += chunk.frameCount;
      }
    }

    this.stream?.getTracks().forEach((track) => track.stop());
    await this.context?.close();
    await this.storage?.clear();
    this.stream = null;
    this.context = null;
    this.source = null;
    this.processor = null;
    this.mute = null;
    this.storage = null;
    this.pendingChunks = [];
    this.pendingFrameCount = 0;
    this.channelCount = 0;
    this.sampleRate = 0;
    this.inputSettings = {};
    this.onMeter([-120, -120]);
    return audioBuffer;
  }
}

export class InputMonitor {
  constructor({ onFrame } = {}) {
    this.onFrame = onFrame || (() => {});
    this.stream = null;
    this.context = null;
    this.source = null;
    this.processor = null;
    this.mute = null;
    this.channelCount = 0;
    this.sampleRate = 0;
    this.inputSettings = {};
    this.active = false;
  }

  async start(deviceId = "") {
    if (!navigator.mediaDevices?.getUserMedia) {
      throw new Error("Input monitoring requires a browser with microphone input support.");
    }

    this.stream = await getAudioInputStream(deviceId);
    this.context = createAudioContext();
    this.sampleRate = this.context.sampleRate;
    this.source = this.context.createMediaStreamSource(this.stream);
    this.channelCount = 2;
    this.inputSettings = streamSettings(this.stream);
    this.processor = this.context.createScriptProcessor(BUFFER_SIZE, streamChannelCount(this.stream), this.channelCount);
    this.mute = this.context.createGain();
    this.mute.gain.value = 0;

    this.processor.onaudioprocess = (event) => {
      const channels = frameChannelsFromInput(event.inputBuffer);
      this.onFrame({
        channels,
        sampleRate: this.sampleRate,
        channelCount: this.channelCount,
        inputSettings: this.inputSettings
      });
    };

    this.source.connect(this.processor);
    this.processor.connect(this.mute);
    this.mute.connect(this.context.destination);
    this.active = true;
  }

  async stop() {
    if (this.processor) {
      this.processor.disconnect();
      this.processor.onaudioprocess = null;
    }
    if (this.source) this.source.disconnect();
    if (this.mute) this.mute.disconnect();
    this.stream?.getTracks().forEach((track) => track.stop());
    await this.context?.close();
    this.stream = null;
    this.context = null;
    this.source = null;
    this.processor = null;
    this.mute = null;
    this.channelCount = 0;
    this.sampleRate = 0;
    this.inputSettings = {};
    this.active = false;
  }
}

export async function listAudioInputs() {
  if (!navigator.mediaDevices?.enumerateDevices) {
    return [];
  }
  const devices = await navigator.mediaDevices.enumerateDevices();
  return devices.filter((device) => device.kind === "audioinput");
}

export async function requestAudioInputPermission() {
  if (!navigator.mediaDevices?.getUserMedia) {
    throw new Error("Audio input selection requires a browser with microphone input support.");
  }
  const stream = await navigator.mediaDevices.getUserMedia({
    audio: audioInputConstraints(),
    video: false
  });
  stream.getTracks().forEach((track) => track.stop());
}

async function createRecordingChunkStore(sessionId) {
  if (!globalThis.indexedDB) {
    return new MemoryRecordingChunkStore(sessionId);
  }
  try {
    const db = await openRecordingDatabase();
    return new IndexedRecordingChunkStore(db, sessionId);
  } catch {
    return new MemoryRecordingChunkStore(sessionId);
  }
}

function openRecordingDatabase() {
  return new Promise((resolve, reject) => {
    const request = indexedDB.open(RECORDING_DB_NAME, RECORDING_DB_VERSION);
    request.onupgradeneeded = () => {
      const db = request.result;
      if (!db.objectStoreNames.contains(RECORDING_STORE)) {
        const store = db.createObjectStore(RECORDING_STORE, { keyPath: "id" });
        store.createIndex("sessionId", "sessionId", { unique: false });
      }
    };
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error);
  });
}

class IndexedRecordingChunkStore {
  constructor(db, sessionId) {
    this.db = db;
    this.sessionId = sessionId;
    this.index = 0;
    this.mode = "IndexedDB chunks";
  }

  async append(chunks, frameCount) {
    const record = {
      id: `${this.sessionId}:${String(this.index).padStart(8, "0")}`,
      sessionId: this.sessionId,
      index: this.index,
      frameCount,
      channels: chunks.map((channelChunks) => concatFloat32(channelChunks, frameCount))
    };
    this.index += 1;
    await idbPut(this.db, record);
  }

  async readAll() {
    const records = await idbGetSession(this.db, this.sessionId);
    return records.sort((a, b) => a.index - b.index);
  }

  async clear() {
    const records = await idbGetSession(this.db, this.sessionId);
    await Promise.all(records.map((record) => idbDelete(this.db, record.id)));
    this.db.close();
  }
}

class MemoryRecordingChunkStore {
  constructor(sessionId) {
    this.sessionId = sessionId;
    this.index = 0;
    this.records = [];
    this.mode = "Memory chunks";
  }

  async append(chunks, frameCount) {
    this.records.push({
      id: `${this.sessionId}:${String(this.index).padStart(8, "0")}`,
      sessionId: this.sessionId,
      index: this.index,
      frameCount,
      channels: chunks.map((channelChunks) => concatFloat32(channelChunks, frameCount))
    });
    this.index += 1;
  }

  async readAll() {
    return [...this.records];
  }

  async clear() {
    this.records = [];
  }
}

function idbPut(db, record) {
  return new Promise((resolve, reject) => {
    const transaction = db.transaction(RECORDING_STORE, "readwrite");
    transaction.objectStore(RECORDING_STORE).put(record);
    transaction.oncomplete = () => resolve();
    transaction.onerror = () => reject(transaction.error);
    transaction.onabort = () => reject(transaction.error);
  });
}

function idbGetSession(db, sessionId) {
  return new Promise((resolve, reject) => {
    const transaction = db.transaction(RECORDING_STORE, "readonly");
    const request = transaction.objectStore(RECORDING_STORE).index("sessionId").getAll(sessionId);
    request.onsuccess = () => resolve(request.result || []);
    request.onerror = () => reject(request.error);
  });
}

function idbDelete(db, id) {
  return new Promise((resolve, reject) => {
    const transaction = db.transaction(RECORDING_STORE, "readwrite");
    transaction.objectStore(RECORDING_STORE).delete(id);
    transaction.oncomplete = () => resolve();
    transaction.onerror = () => reject(transaction.error);
    transaction.onabort = () => reject(transaction.error);
  });
}

function concatFloat32(chunks, frameCount) {
  const data = new Float32Array(frameCount);
  let offset = 0;
  for (const chunk of chunks) {
    data.set(chunk.subarray(0, Math.min(chunk.length, data.length - offset)), offset);
    offset += chunk.length;
    if (offset >= data.length) break;
  }
  return data;
}
