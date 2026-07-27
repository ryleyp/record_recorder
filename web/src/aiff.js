import { createId3Tag } from "./audioMetadata.js";
import { subtractSkipRanges } from "./silenceCrop.js";
import { clamp } from "./utils.js";

export function encodeAudioBufferToAiff(audioBuffer, options = {}) {
  return encodeSegmentToAiff(audioBuffer, 0, audioBuffer.duration, options);
}

export function encodeSegmentToAiff(audioBuffer, startSeconds, endSeconds, options = {}) {
  const sampleRate = audioBuffer.sampleRate;
  const channelCount = audioBuffer.numberOfChannels;
  const keepRanges = subtractSkipRanges(startSeconds, endSeconds, options.skipRanges || []);
  const frameRanges = keepRanges
    .map((range) => {
      const startFrame = clamp(Math.floor(range.start * sampleRate), 0, audioBuffer.length);
      const endFrame = clamp(Math.ceil(range.end * sampleRate), startFrame, audioBuffer.length);
      return { startFrame, endFrame };
    })
    .filter((range) => range.endFrame > range.startFrame);
  const frameCount = frameRanges.reduce((sum, range) => sum + range.endFrame - range.startFrame, 0);
  const bytesPerSample = 2;
  const dataSize = frameCount * channelCount * bytesPerSample;
  const commPayload = createCommPayload(channelCount, frameCount, sampleRate);
  const id3Payload = createId3Tag(options.metadata || {});
  const ssndPayloadSize = 8 + dataSize;
  const formSize = 4
    + chunkByteLength(commPayload.length)
    + (id3Payload.length ? chunkByteLength(id3Payload.length) : 0)
    + chunkByteLength(ssndPayloadSize);
  const buffer = new ArrayBuffer(8 + formSize);
  const view = new DataView(buffer);

  writeString(view, 0, "FORM");
  view.setUint32(4, formSize, false);
  writeString(view, 8, "AIFF");
  let offset = 12;
  offset = writeChunk(view, offset, "COMM", commPayload);
  if (id3Payload.length) {
    offset = writeChunk(view, offset, "ID3 ", id3Payload);
  }

  writeString(view, offset, "SSND");
  view.setUint32(offset + 4, ssndPayloadSize, false);
  view.setUint32(offset + 8, 0, false);
  view.setUint32(offset + 12, 0, false);
  offset += 16;

  const channelData = [];
  for (let channel = 0; channel < channelCount; channel += 1) {
    channelData.push(audioBuffer.getChannelData(channel));
  }

  const gain = options.normalize
    ? normalizationGain(channelData, frameRanges, options.normalizeTargetDB ?? -1)
    : (options.gainLinear ?? 1);
  const fadeInFrames = Math.min(
    frameCount,
    Math.round(((options.fadeInMilliseconds ?? 0) / 1000) * sampleRate)
  );
  const fadeOutFrames = Math.min(
    frameCount,
    Math.round(((options.fadeOutMilliseconds ?? 15) / 1000) * sampleRate)
  );

  let outputFrame = 0;
  for (const range of frameRanges) {
    for (let sourceFrame = range.startFrame; sourceFrame < range.endFrame; sourceFrame += 1) {
      let fadeGain = 1;
      if (fadeInFrames > 0 && outputFrame < fadeInFrames) {
        fadeGain = Math.min(fadeGain, outputFrame / fadeInFrames);
      }
      if (fadeOutFrames > 0 && outputFrame >= frameCount - fadeOutFrames) {
        fadeGain = Math.min(fadeGain, (frameCount - outputFrame - 1) / fadeOutFrames);
      }
      for (let channel = 0; channel < channelCount; channel += 1) {
        const sample = clamp(channelData[channel][sourceFrame] * gain * fadeGain, -1, 1);
        view.setInt16(offset, sample < 0 ? sample * 0x8000 : sample * 0x7fff, false);
        offset += 2;
      }
      outputFrame += 1;
    }
  }

  return new Uint8Array(buffer);
}

function createCommPayload(channelCount, frameCount, sampleRate) {
  const payload = new Uint8Array(18);
  const view = new DataView(payload.buffer);
  view.setUint16(0, channelCount, false);
  view.setUint32(2, frameCount, false);
  view.setUint16(6, 16, false);
  writeExtended80(view, 8, sampleRate);
  return payload;
}

function normalizationGain(channelData, frameRanges, targetDB) {
  let peak = 0;
  for (const channel of channelData) {
    for (const range of frameRanges) {
      for (let frame = range.startFrame; frame < range.endFrame; frame += 1) {
        const value = Math.abs(channel[frame]);
        if (value > peak) peak = value;
      }
    }
  }
  if (peak <= 0) return 1;
  const target = Math.pow(10, targetDB / 20);
  return Math.min(target / peak, Math.pow(10, 18 / 20));
}

function chunkByteLength(payloadLength) {
  return 8 + payloadLength + (payloadLength % 2);
}

function writeChunk(view, offset, id, payload) {
  writeString(view, offset, id);
  view.setUint32(offset + 4, payload.length, false);
  new Uint8Array(view.buffer).set(payload, offset + 8);
  return offset + chunkByteLength(payload.length);
}

function writeExtended80(view, offset, value) {
  if (!Number.isFinite(value) || value <= 0) {
    for (let index = 0; index < 10; index += 1) {
      view.setUint8(offset + index, 0);
    }
    return;
  }

  const exponent = Math.floor(Math.log2(value));
  const biasedExponent = exponent + 16383;
  const normalized = value / Math.pow(2, exponent);
  const scaled = normalized * 0x80000000;
  const highMantissa = Math.floor(scaled);
  const lowMantissa = Math.floor((scaled - highMantissa) * 0x100000000);

  view.setUint16(offset, biasedExponent, false);
  view.setUint32(offset + 2, highMantissa >>> 0, false);
  view.setUint32(offset + 6, lowMantissa >>> 0, false);
}

function writeString(view, offset, text) {
  for (let index = 0; index < text.length; index += 1) {
    view.setUint8(offset + index, text.charCodeAt(index));
  }
}
