import { dbFromPeak } from "./utils.js";

const BUFFER_SIZE = 1024;

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

    const audio = {
      channelCount: { ideal: 2 },
      echoCancellation: false,
      noiseSuppression: false,
      autoGainControl: false
    };
    if (deviceId) {
      audio.deviceId = { exact: deviceId };
    }

    this.stream = await navigator.mediaDevices.getUserMedia({ audio, video: false });
    this.context = new AudioContext();
    this.sampleRate = this.context.sampleRate;
    this.source = this.context.createMediaStreamSource(this.stream);
    this.channelCount = Math.min(2, this.source.channelCount || 2);
    this.channelChunks = Array.from({ length: this.channelCount }, () => []);
    this.processor = this.context.createScriptProcessor(BUFFER_SIZE, this.channelCount, this.channelCount);
    this.mute = this.context.createGain();
    this.mute.gain.value = 0;

    this.processor.onaudioprocess = (event) => {
      const input = event.inputBuffer;
      const peaks = [];
      for (let channel = 0; channel < this.channelCount; channel += 1) {
        const sourceData = input.getChannelData(Math.min(channel, input.numberOfChannels - 1));
        const copy = new Float32Array(sourceData.length);
        let peak = 0;
        for (let index = 0; index < sourceData.length; index += 1) {
          const value = sourceData[index];
          copy[index] = value;
          const abs = Math.abs(value);
          if (abs > peak) peak = abs;
        }
        this.channelChunks[channel].push(copy);
        peaks.push(dbFromPeak(peak));
      }
      if (peaks.length === 1) peaks.push(peaks[0]);
      this.onMeter(peaks);
      this.onFrame({
        channels: this.channelChunks.map((chunks) => chunks[chunks.length - 1]),
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
    const audio = {
      channelCount: { ideal: 2 },
      echoCancellation: false,
      noiseSuppression: false,
      autoGainControl: false
    };
    if (deviceId) {
      audio.deviceId = { exact: deviceId };
    }

    this.stream = await navigator.mediaDevices.getUserMedia({ audio, video: false });
    this.context = new AudioContext();
    this.sampleRate = this.context.sampleRate;
    this.source = this.context.createMediaStreamSource(this.stream);
    this.channelCount = Math.min(2, this.source.channelCount || 2);
    this.processor = this.context.createScriptProcessor(BUFFER_SIZE, this.channelCount, this.channelCount);
    this.mute = this.context.createGain();
    this.mute.gain.value = 0;

    this.processor.onaudioprocess = (event) => {
      const input = event.inputBuffer;
      const channels = [];
      for (let channel = 0; channel < this.channelCount; channel += 1) {
        const sourceData = input.getChannelData(Math.min(channel, input.numberOfChannels - 1));
        channels.push(new Float32Array(sourceData));
      }
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
