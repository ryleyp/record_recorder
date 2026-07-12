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
  const view = new DataView(wav.buffer, wav.byteOffset, wav.byteLength);
  return view.getUint32(40, true) / (channelCount * 2);
}
