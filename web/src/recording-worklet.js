class VinylRecorderProcessor extends AudioWorkletProcessor {
  process(inputs, outputs) {
    const input = inputs[0];
    const output = outputs[0];
    if (output) {
      for (const channel of output) {
        channel.fill(0);
      }
    }
    if (!input?.[0]?.length) return true;

    const left = new Float32Array(input[0]);
    const right = input[1]?.length
      ? new Float32Array(input[1])
      : new Float32Array(left);
    const { peaksDBFS, clippingCount } = frameStats([left, right]);
    this.port.postMessage({
      type: "frame",
      channels: [left.buffer, right.buffer],
      peaksDBFS,
      clippingCount
    }, [left.buffer, right.buffer]);
    return true;
  }
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

function dbFromPeak(peak) {
  if (!Number.isFinite(peak) || peak <= 0) {
    return -120;
  }
  return Math.max(-120, 20 * Math.log10(peak));
}

registerProcessor("vinyl-recorder-processor", VinylRecorderProcessor);
