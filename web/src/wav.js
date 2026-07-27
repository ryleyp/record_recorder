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

function createInfoChunk(metadata) {
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

function createId3Tag(metadata) {
  const frames = [];
  appendTextFrame(frames, "TIT2", metadata.title);
  appendTextFrame(frames, "TPE1", metadata.artist || metadata.albumArtist);
  appendTextFrame(frames, "TALB", metadata.albumTitle);
  appendTextFrame(frames, "TPE2", metadata.albumArtist || metadata.artist);
  appendTextFrame(frames, "TYER", metadata.year);
  appendTextFrame(frames, "TCON", metadata.genre);
  appendTextFrame(frames, "TRCK", formatNumberPair(metadata.trackNumber, metadata.trackTotal));
  appendTextFrame(frames, "TPOS", formatNumberPair(metadata.discNumber, metadata.discTotal));

  const artwork = metadata.artwork || {};
  const artworkBytes = bytesFrom(artwork.bytes);
  if (artworkBytes?.length) {
    frames.push(createApicFrame(artworkBytes, artwork.type));
  }

  if (!frames.length) return new Uint8Array(0);

  const padding = 256;
  const frameBytes = concatBytes(frames);
  const tag = new Uint8Array(10 + frameBytes.length + padding);
  tag[0] = 0x49;
  tag[1] = 0x44;
  tag[2] = 0x33;
  tag[3] = 0x03;
  tag[4] = 0x00;
  tag[5] = 0x00;
  tag.set(synchsafe(frameBytes.length + padding), 6);
  tag.set(frameBytes, 10);
  return tag;
}

function appendTextFrame(frames, id, value) {
  const text = cleanText(value);
  if (!text) return;
  const payload = concatBytes([
    new Uint8Array([0x01, 0xff, 0xfe]),
    utf16LittleEndianBytes(text)
  ]);
  frames.push(createId3Frame(id, payload));
}

function createApicFrame(artworkBytes, type) {
  const mime = cleanArtworkMimeType(type);
  const mimeBytes = asciiBytes(mime);
  const payload = concatBytes([
    new Uint8Array([0x00]),
    mimeBytes,
    new Uint8Array([0x00, 0x03, 0x00]),
    artworkBytes
  ]);
  return createId3Frame("APIC", payload);
}

function createId3Frame(id, payload) {
  const frame = new Uint8Array(10 + payload.length);
  const view = new DataView(frame.buffer);
  writeString(view, 0, id);
  view.setUint32(4, payload.length, false);
  view.setUint16(8, 0, false);
  frame.set(payload, 10);
  return frame;
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

function formatNumberPair(number, total) {
  const parsedNumber = Number(number);
  if (!Number.isFinite(parsedNumber) || parsedNumber <= 0) return "";
  const parsedTotal = Number(total);
  return Number.isFinite(parsedTotal) && parsedTotal > 0
    ? `${Math.round(parsedNumber)}/${Math.round(parsedTotal)}`
    : `${Math.round(parsedNumber)}`;
}

function cleanText(value) {
  return String(value ?? "").trim();
}

function utf16LittleEndianBytes(text) {
  const bytes = new Uint8Array(text.length * 2);
  const view = new DataView(bytes.buffer);
  for (let index = 0; index < text.length; index += 1) {
    view.setUint16(index * 2, text.charCodeAt(index), true);
  }
  return bytes;
}

function cleanArtworkMimeType(type) {
  const mime = cleanText(type).toLowerCase();
  if (mime === "image/png" || mime === "image/jpeg" || mime === "image/webp") {
    return mime;
  }
  return "image/jpeg";
}

function asciiBytes(text) {
  const bytes = new Uint8Array(text.length);
  for (let index = 0; index < text.length; index += 1) {
    bytes[index] = text.charCodeAt(index) & 0xff;
  }
  return bytes;
}

function synchsafe(value) {
  return new Uint8Array([
    (value >> 21) & 0x7f,
    (value >> 14) & 0x7f,
    (value >> 7) & 0x7f,
    value & 0x7f
  ]);
}

function bytesFrom(value) {
  if (!value) return null;
  if (value instanceof Uint8Array) return value;
  if (value instanceof ArrayBuffer) return new Uint8Array(value);
  if (ArrayBuffer.isView(value)) {
    return new Uint8Array(value.buffer, value.byteOffset, value.byteLength);
  }
  return null;
}

function concatBytes(parts) {
  const total = parts.reduce((sum, part) => sum + part.length, 0);
  const bytes = new Uint8Array(total);
  let offset = 0;
  for (const part of parts) {
    bytes.set(part, offset);
    offset += part.length;
  }
  return bytes;
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
