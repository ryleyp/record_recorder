import { dbFromPeak } from "./utils.js";

const BUFFER_SIZE = 1024;

function createAudioContext() {
  const AudioContextConstructor = window.AudioContext || window.webkitAudioContext;
  if (!AudioContextConstructor) {
    throw new Error("Audio recording requires a browser with Web Audio support.");
  }
  return new AudioContextConstructor();
}

function audioInputConstraints(deviceId = "", options = {}) {
  const audio = {
    channelCount: options.requireStereo ? { exact: 2 } : { ideal: 2 },
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

function frameChannelsFromInput(input) {
  const inputChannelCount = Math.max(1, Math.min(2, input.numberOfChannels || 1));
  const first = new Float32Array(input.getChannelData(0));
  if (inputChannelCount === 1) {
    return [first, new Float32Array(first)];
  }
  return [first, new Float32Array(input.getChannelData(1))];
}

function channelPeaksDBFS(channels) {
  return channels.map((channel) => {
    let peak = 0;
    for (let index = 0; index < channel.length; index += 1) {
      const abs = Math.abs(channel[index]);
      if (abs > peak) peak = abs;
    }
    return dbFromPeak(peak);
  });
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
    this.channelChunks = [];
    this.channelCount = 0;
    this.sampleRate = 0;
    this.startedAt = 0;
    this.timer = 0;
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
    this.channelChunks = Array.from({ length: this.channelCount }, () => []);
    this.processor = this.context.createScriptProcessor(BUFFER_SIZE, streamChannelCount(this.stream), this.channelCount);
    this.mute = this.context.createGain();
    this.mute.gain.value = 0;

    this.processor.onaudioprocess = (event) => {
      const input = event.inputBuffer;
      const channels = frameChannelsFromInput(input);
      for (let channel = 0; channel < this.channelCount; channel += 1) {
        this.channelChunks[channel].push(channels[channel]);
      }
      this.onMeter(channelPeaksDBFS(channels));
      this.onFrame({
        channels,
        sampleRate: this.sampleRate,
        channelCount: this.channelCount
      });
    };

    this.source.connect(this.processor);
    this.processor.connect(this.mute);
    this.mute.connect(this.context.destination);
    this.startedAt = performance.now();
    this.timer = window.setInterval(() => {
      this.onTick((performance.now() - this.startedAt) / 1000);
    }, 250);
  }

  async stop() {
    window.clearInterval(this.timer);
    if (this.processor) {
      this.processor.disconnect();
      this.processor.onaudioprocess = null;
    }
    if (this.source) this.source.disconnect();
    if (this.mute) this.mute.disconnect();

    const frameCount = this.channelChunks[0]?.reduce((sum, chunk) => sum + chunk.length, 0) || 0;
    const audioBuffer = this.context.createBuffer(this.channelCount, frameCount, this.sampleRate);
    for (let channel = 0; channel < this.channelCount; channel += 1) {
      const destination = audioBuffer.getChannelData(channel);
      let offset = 0;
      for (const chunk of this.channelChunks[channel]) {
        destination.set(chunk, offset);
        offset += chunk.length;
      }
    }

    this.stream?.getTracks().forEach((track) => track.stop());
    await this.context?.close();
    this.stream = null;
    this.context = null;
    this.source = null;
    this.processor = null;
    this.mute = null;
    this.channelChunks = [];
    this.channelCount = 0;
    this.sampleRate = 0;
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
    this.processor = this.context.createScriptProcessor(BUFFER_SIZE, streamChannelCount(this.stream), this.channelCount);
    this.mute = this.context.createGain();
    this.mute.gain.value = 0;

    this.processor.onaudioprocess = (event) => {
      const channels = frameChannelsFromInput(event.inputBuffer);
      this.onFrame({
        channels,
        sampleRate: this.sampleRate,
        channelCount: this.channelCount
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
