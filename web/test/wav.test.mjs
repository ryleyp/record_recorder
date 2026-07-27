import test from "node:test";
import assert from "node:assert/strict";
import { encodeSegmentToWav } from "../src/wav.js";

test("encodeSegmentToWav omits skipped silence ranges", () => {
  const sampleRate = 100;
  const channel = new Float32Array(sampleRate * 10);
  channel.fill(0.2);
  const audioBuffer = fakeAudioBuffer([channel], sampleRate);

  const wav = encodeSegmentToWav(audioBuffer, 0, 10, {
    fadeInMilliseconds: 0,
    fadeOutMilliseconds: 0,
    skipRanges: [{ start: 2, end: 7 }]
  });

  assert.equal(frameCountFromWav(wav, audioBuffer.numberOfChannels), sampleRate * 5);
});

test("encodeSegmentToWav writes library metadata chunks", () => {
  const sampleRate = 100;
  const channel = new Float32Array(sampleRate);
  channel.fill(0.2);
  const audioBuffer = fakeAudioBuffer([channel], sampleRate);

  const wav = encodeSegmentToWav(audioBuffer, 0, 1, {
    fadeInMilliseconds: 0,
    fadeOutMilliseconds: 0,
    metadata: {
      title: "First Song",
      artist: "Track Artist",
      albumTitle: "Clean Album",
      albumArtist: "Album Artist",
      year: 1972,
      genre: "Soul",
      trackNumber: 1,
      trackTotal: 9,
      discNumber: 1,
      discTotal: 2,
      artwork: {
        type: "image/jpeg",
        bytes: new Uint8Array([0xff, 0xd8, 0xff, 0xd9])
      }
    }
  });

  const chunks = riffChunks(wav);
  assert.deepEqual(chunks.map((chunk) => chunk.id), ["fmt ", "LIST", "id3 ", "data"]);

  const info = parseInfoChunk(chunks.find((chunk) => chunk.id === "LIST").payload);
  assert.equal(info.INAM, "First Song");
  assert.equal(info.IART, "Track Artist");
  assert.equal(info.IPRD, "Clean Album");
  assert.equal(info.ITRK, "1/9");

  const id3 = parseId3Tag(chunks.find((chunk) => chunk.id === "id3 ").payload);
  assert.equal(id3.textFrames.TIT2, "First Song");
  assert.equal(id3.textFrames.TPE1, "Track Artist");
  assert.equal(id3.textFrames.TALB, "Clean Album");
  assert.equal(id3.textFrames.TPE2, "Album Artist");
  assert.equal(id3.textFrames.TYER, "1972");
  assert.equal(id3.textFrames.TCON, "Soul");
  assert.equal(id3.textFrames.TRCK, "1/9");
  assert.equal(id3.textFrames.TPOS, "1/2");
  assert.equal(id3.hasArtwork, true);
});

function fakeAudioBuffer(channels, sampleRate) {
  return {
    sampleRate,
    numberOfChannels: channels.length,
    length: channels[0].length,
    duration: channels[0].length / sampleRate,
    getChannelData(index) {
      return channels[index];
    }
  };
}

function frameCountFromWav(wav, channelCount) {
  const data = riffChunks(wav).find((chunk) => chunk.id === "data");
  return data.payload.length / (channelCount * 2);
}

function riffChunks(wav) {
  const view = new DataView(wav.buffer, wav.byteOffset, wav.byteLength);
  assert.equal(readAscii(wav, 0, 4), "RIFF");
  assert.equal(readAscii(wav, 8, 4), "WAVE");
  const chunks = [];
  let offset = 12;
  while (offset + 8 <= wav.byteLength) {
    const id = readAscii(wav, offset, 4);
    const size = view.getUint32(offset + 4, true);
    const payloadStart = offset + 8;
    const payloadEnd = payloadStart + size;
    chunks.push({ id, payload: wav.subarray(payloadStart, payloadEnd) });
    offset = payloadEnd + (size % 2);
  }
  return chunks;
}

function parseInfoChunk(payload) {
  assert.equal(readAscii(payload, 0, 4), "INFO");
  const view = new DataView(payload.buffer, payload.byteOffset, payload.byteLength);
  const fields = {};
  let offset = 4;
  while (offset + 8 <= payload.byteLength) {
    const id = readAscii(payload, offset, 4);
    const size = view.getUint32(offset + 4, true);
    const value = new TextDecoder().decode(payload.subarray(offset + 8, offset + 8 + size))
      .replace(/\0+$/, "");
    fields[id] = value;
    offset += 8 + size + (size % 2);
  }
  return fields;
}

function parseId3Tag(payload) {
  assert.equal(readAscii(payload, 0, 3), "ID3");
  assert.equal(payload[3], 0x03);
  const size = (payload[6] << 21) | (payload[7] << 14) | (payload[8] << 7) | payload[9];
  const textFrames = {};
  let hasArtwork = false;
  let offset = 10;
  const end = Math.min(payload.byteLength, 10 + size);
  while (offset + 10 <= end) {
    const id = readAscii(payload, offset, 4);
    if (id === "\0\0\0\0") break;
    const frameSize = (payload[offset + 4] << 24)
      | (payload[offset + 5] << 16)
      | (payload[offset + 6] << 8)
      | payload[offset + 7];
    const framePayload = payload.subarray(offset + 10, offset + 10 + frameSize);
    if (id === "APIC") {
      hasArtwork = true;
    } else if (id.startsWith("T")) {
      textFrames[id] = decodeTextFrame(framePayload);
    }
    offset += 10 + frameSize;
  }
  return { textFrames, hasArtwork };
}

function decodeTextFrame(payload) {
  if (payload[0] === 0x01) {
    const body = payload[1] === 0xff && payload[2] === 0xfe
      ? payload.subarray(3)
      : payload.subarray(1);
    return new TextDecoder("utf-16le").decode(body).replace(/\0+$/, "");
  }
  return new TextDecoder("latin1").decode(payload.subarray(1)).replace(/\0+$/, "");
}

function readAscii(bytes, offset, length) {
  let text = "";
  for (let index = 0; index < length; index += 1) {
    text += String.fromCharCode(bytes[offset + index]);
  }
  return text;
}
