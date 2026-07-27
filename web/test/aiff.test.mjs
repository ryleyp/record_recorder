import test from "node:test";
import assert from "node:assert/strict";
import { encodeSegmentToAiff } from "../src/aiff.js";

test("encodeSegmentToAiff omits skipped silence ranges", () => {
  const sampleRate = 100;
  const channel = new Float32Array(sampleRate * 10);
  channel.fill(0.2);
  const audioBuffer = fakeAudioBuffer([channel], sampleRate);

  const aiff = encodeSegmentToAiff(audioBuffer, 0, 10, {
    fadeInMilliseconds: 0,
    fadeOutMilliseconds: 0,
    skipRanges: [{ start: 2, end: 7 }]
  });

  assert.equal(frameCountFromAiff(aiff), sampleRate * 5);
});

test("encodeSegmentToAiff writes Apple Music-ready ID3 metadata", () => {
  const sampleRate = 100;
  const channel = new Float32Array(sampleRate);
  channel.fill(0.2);
  const audioBuffer = fakeAudioBuffer([channel], sampleRate);

  const aiff = encodeSegmentToAiff(audioBuffer, 0, 1, {
    fadeInMilliseconds: 0,
    fadeOutMilliseconds: 0,
    metadata: {
      title: "Dreamer",
      artist: "Laufey",
      albumTitle: "Bewitched - The Goddess Edition",
      albumArtist: "Laufey",
      year: 2024,
      genre: "Jazz Pop",
      trackNumber: 1,
      trackTotal: 9,
      discNumber: 1,
      discTotal: 1,
      artwork: {
        type: "image/jpeg",
        bytes: new Uint8Array([0xff, 0xd8, 0xff, 0xd9])
      }
    }
  });

  const chunks = aiffChunks(aiff);
  assert.deepEqual(chunks.map((chunk) => chunk.id), ["COMM", "ID3 ", "SSND"]);
  assert.equal(frameCountFromAiff(aiff), sampleRate);

  const id3 = parseId3Tag(chunks.find((chunk) => chunk.id === "ID3 ").payload);
  assert.equal(id3.textFrames.TIT2, "Dreamer");
  assert.equal(id3.textFrames.TPE1, "Laufey");
  assert.equal(id3.textFrames.TALB, "Bewitched - The Goddess Edition");
  assert.equal(id3.textFrames.TPE2, "Laufey");
  assert.equal(id3.textFrames.TYER, "2024");
  assert.equal(id3.textFrames.TDRC, "2024");
  assert.equal(id3.textFrames.TCON, "Jazz Pop");
  assert.equal(id3.textFrames.TRCK, "1/9");
  assert.equal(id3.textFrames.TPOS, "1/1");
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

function frameCountFromAiff(aiff) {
  const comm = aiffChunks(aiff).find((chunk) => chunk.id === "COMM");
  const view = new DataView(comm.payload.buffer, comm.payload.byteOffset, comm.payload.byteLength);
  return view.getUint32(2, false);
}

function aiffChunks(aiff) {
  const view = new DataView(aiff.buffer, aiff.byteOffset, aiff.byteLength);
  assert.equal(readAscii(aiff, 0, 4), "FORM");
  assert.equal(readAscii(aiff, 8, 4), "AIFF");
  const chunks = [];
  let offset = 12;
  while (offset + 8 <= aiff.byteLength) {
    const id = readAscii(aiff, offset, 4);
    const size = view.getUint32(offset + 4, false);
    const payloadStart = offset + 8;
    const payloadEnd = payloadStart + size;
    chunks.push({ id, payload: aiff.subarray(payloadStart, payloadEnd) });
    offset = payloadEnd + (size % 2);
  }
  return chunks;
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
