import {
  cleanText,
  createId3Tag,
  formatNumberPair
} from "./audioMetadata.js";
import { clamp } from "./utils.js";
import { subtractSkipRanges } from "./silenceCrop.js";

export function encodeAudioBufferToWav(audioBuffer, options = {}) {
  return encodeSegmentToWav(audioBuffer, 0, audioBuffer.duration, options);
}

export function encodeSegmentToWav(audioBuffer, startSeconds, endSeconds, options = {}) {
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
  const blockAlign = channelCount * bytesPerSample;
  const dataSize = frameCount * blockAlign;
  const metadataChunks = createMetadataChunks(options.metadata);
  const fmtPayload = createFmtPayload(channelCount, sampleRate, blockAlign);
  const riffSize = 4
    + chunkByteLength(fmtPayload)
    + metadataChunks.reduce((sum, chunk) => sum + chunkByteLength(chunk.payload), 0)
    + 8
    + dataSize;
  const buffer = new ArrayBuffer(8 + riffSize);
  const view = new DataView(buffer);

  writeString(view, 0, "RIFF");
  view.setUint32(4, riffSize, true);
  writeString(view, 8, "WAVE");
  let offset = 12;
  offset = writeChunk(view, offset, "fmt ", fmtPayload);
  for (const chunk of metadataChunks) {
    offset = writeChunk(view, offset, chunk.id, chunk.payload);
  }
  writeString(view, offset, "data");
  view.setUint32(offset + 4, dataSize, true);
  offset += 8;

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
        view.setInt16(offset, sample < 0 ? sample * 0x8000 : sample * 0x7fff, true);
        offset += 2;
      }
      outputFrame += 1;
    }
  }

  return new Uint8Array(buffer);
}

function createFmtPayload(channelCount, sampleRate, blockAlign) {
  const payload = new Uint8Array(16);
  const view = new DataView(payload.buffer);
  view.setUint16(0, 1, true);
  view.setUint16(2, channelCount, true);
  view.setUint32(4, sampleRate, true);
  view.setUint32(8, sampleRate * blockAlign, true);
  view.setUint16(12, blockAlign, true);
  view.setUint16(14, 16, true);
  return payload;
}

function createMetadataChunks(metadata = null) {
  if (!metadata) return [];
  const chunks = [];
  const infoChunk = createInfoChunk(metadata);
  if (infoChunk.length) chunks.push({ id: "LIST", payload: infoChunk });
  const id3Chunk = createId3Tag(metadata);
  if (id3Chunk.length) chunks.push({ id: "id3 ", payload: id3Chunk });
  return chunks;
}

export function createInfoChunk(metadata) {
  const fields = [
    ["INAM", metadata.title],
    ["IART", metadata.artist || metadata.albumArtist],
    ["IPRD", metadata.albumTitle],
    ["IGNR", metadata.genre],
    ["ICRD", metadata.year],
    ["ITRK", formatNumberPair(metadata.trackNumber, metadata.trackTotal)]
  ].filter(([, value]) => cleanText(value));

  if (!fields.length) return new Uint8Array(0);

  const textEncoder = new TextEncoder();
  const subchunks = fields.map(([id, value]) => {
    const text = textEncoder.encode(`${cleanText(value)}\0`);
    return { id, payload: text };
  });
  const size = 4 + subchunks.reduce((sum, chunk) => sum + chunkByteLength(chunk.payload), 0);
  const payload = new Uint8Array(size);
  const view = new DataView(payload.buffer);
  writeString(view, 0, "INFO");
  let offset = 4;
  for (const chunk of subchunks) {
    offset = writeChunk(view, offset, chunk.id, chunk.payload);
  }
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

function chunkByteLength(payload) {
  return 8 + payload.length + (payload.length % 2);
}

function writeChunk(view, offset, id, payload) {
  writeString(view, offset, id);
  view.setUint32(offset + 4, payload.length, true);
  new Uint8Array(view.buffer).set(payload, offset + 8);
  return offset + chunkByteLength(payload);
}

function writeString(view, offset, text) {
  for (let index = 0; index < text.length; index += 1) {
    view.setUint8(offset + index, text.charCodeAt(index));
  }
}
