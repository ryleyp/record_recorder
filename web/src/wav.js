import { clamp } from "./utils.js";

export function encodeAudioBufferToWav(audioBuffer, options = {}) {
  return encodeSegmentToWav(audioBuffer, 0, audioBuffer.duration, options);
}

export function encodeSegmentToWav(audioBuffer, startSeconds, endSeconds, options = {}) {
  const sampleRate = audioBuffer.sampleRate;
  const channelCount = audioBuffer.numberOfChannels;
  const startFrame = clamp(Math.floor(startSeconds * sampleRate), 0, audioBuffer.length);
  const endFrame = clamp(Math.ceil(endSeconds * sampleRate), startFrame, audioBuffer.length);
  const frameCount = Math.max(0, endFrame - startFrame);
  const bytesPerSample = 2;
  const blockAlign = channelCount * bytesPerSample;
  const dataSize = frameCount * blockAlign;
  const buffer = new ArrayBuffer(44 + dataSize);
  const view = new DataView(buffer);

  writeString(view, 0, "RIFF");
  view.setUint32(4, 36 + dataSize, true);
  writeString(view, 8, "WAVE");
  writeString(view, 12, "fmt ");
  view.setUint32(16, 16, true);
  view.setUint16(20, 1, true);
  view.setUint16(22, channelCount, true);
  view.setUint32(24, sampleRate, true);
  view.setUint32(28, sampleRate * blockAlign, true);
  view.setUint16(32, blockAlign, true);
  view.setUint16(34, 16, true);
  writeString(view, 36, "data");
  view.setUint32(40, dataSize, true);

  const channelData = [];
  for (let channel = 0; channel < channelCount; channel += 1) {
    channelData.push(audioBuffer.getChannelData(channel));
  }

  const gain = options.normalize
    ? normalizationGain(channelData, startFrame, endFrame, options.normalizeTargetDB ?? -1)
    : (options.gainLinear ?? 1);
  const fadeInFrames = Math.min(
    frameCount,
    Math.round(((options.fadeInMilliseconds ?? 0) / 1000) * sampleRate)
  );
  const fadeOutFrames = Math.min(
    frameCount,
    Math.round(((options.fadeOutMilliseconds ?? 15) / 1000) * sampleRate)
  );

  let offset = 44;
  for (let frame = 0; frame < frameCount; frame += 1) {
    let fadeGain = 1;
    if (fadeInFrames > 0 && frame < fadeInFrames) {
      fadeGain = Math.min(fadeGain, frame / fadeInFrames);
    }
    if (fadeOutFrames > 0 && frame >= frameCount - fadeOutFrames) {
      fadeGain = Math.min(fadeGain, (frameCount - frame - 1) / fadeOutFrames);
    }
    for (let channel = 0; channel < channelCount; channel += 1) {
      const sample = clamp(channelData[channel][startFrame + frame] * gain * fadeGain, -1, 1);
      view.setInt16(offset, sample < 0 ? sample * 0x8000 : sample * 0x7fff, true);
      offset += 2;
    }
  }

  return new Uint8Array(buffer);
}

function normalizationGain(channelData, startFrame, endFrame, targetDB) {
  let peak = 0;
  for (const channel of channelData) {
    for (let frame = startFrame; frame < endFrame; frame += 1) {
      const value = Math.abs(channel[frame]);
      if (value > peak) peak = value;
    }
  }
  if (peak <= 0) return 1;
  const target = Math.pow(10, targetDB / 20);
  return Math.min(target / peak, Math.pow(10, 18 / 20));
}

function writeString(view, offset, text) {
  for (let index = 0; index < text.length; index += 1) {
    view.setUint8(offset + index, text.charCodeAt(index));
  }
}
