#!/usr/bin/env swift
//
// Generates the sample test audio described in the project spec into
// SampleAudio/. Run from the repository root:
//
//     swift Scripts/generate_sample_audio.swift
//
// Produces:
//   SampleAudio/three-songs-clear-silence.wav   — 3 songs, true silence gaps
//   SampleAudio/quiet-passage-no-split.wav      — quiet middle that must NOT split
//   SampleAudio/surface-noise-gaps.wav          — vinyl-style noise in the gaps
//   SampleAudio/false-short-gap.wav             — 0.4 s dropout inside a song
//   SampleAudio/unequal-stereo-levels.wav       — right channel much quieter
//
// These are short (song lengths are compressed) so they stay small; drop them
// into a project's Recordings folder or use them to sanity-check detection.

import AVFoundation

let sampleRate = 44_100.0

func sine(_ frequency: Double, _ duration: Double, _ amplitude: Float) -> [Float] {
    (0..<Int(duration * sampleRate)).map { i in
        amplitude * Float(sin(2 * .pi * frequency * Double(i) / sampleRate))
    }
}

func song(_ duration: Double, amplitude: Float = 0.4) -> [Float] {
    let frames = Int(duration * sampleRate)
    var result = [Float](repeating: 0, count: frames)
    for (index, frequency) in [220.0, 331.0, 442.0].enumerated() {
        let partial = amplitude / Float(index + 2)
        for i in 0..<frames {
            result[i] += partial * Float(sin(2 * .pi * frequency * Double(i) / sampleRate))
        }
    }
    return result
}

func silence(_ duration: Double) -> [Float] {
    [Float](repeating: 0, count: Int(duration * sampleRate))
}

var noiseState: UInt64 = 42
func surfaceNoise(_ duration: Double, amplitudeDB: Float = -45) -> [Float] {
    let amplitude = powf(10, amplitudeDB / 20)
    return (0..<Int(duration * sampleRate)).map { _ in
        noiseState = noiseState &* 6364136223846793005 &+ 1442695040888963407
        let unit = Float(noiseState >> 40) / Float(1 << 24) * 2 - 1
        return amplitude * unit
    }
}

func write(_ name: String, left: [Float], right: [Float]? = nil) throws {
    let channels: AVAudioChannelCount = right == nil ? 1 : 2
    let url = URL(fileURLWithPath: "SampleAudio/\(name)")
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? FileManager.default.removeItem(at: url)
    let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: sampleRate,
        AVNumberOfChannelsKey: channels,
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsBigEndianKey: false,
    ]
    let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
        channels: channels, interleaved: false)!
    let file = try AVAudioFile(
        forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(left.count))!
    buffer.frameLength = AVAudioFrameCount(left.count)
    for i in 0..<left.count { buffer.floatChannelData![0][i] = left[i] }
    if let right { for i in 0..<right.count { buffer.floatChannelData![1][i] = right[i] } }
    try file.write(from: buffer)
    print("wrote SampleAudio/\(name) (\(String(format: "%.1f", Double(left.count) / sampleRate)) s)")
}

// 1. Three songs with clear silence.
try write(
    "three-songs-clear-silence.wav",
    left: silence(1.5) + song(12) + silence(2.5) + song(12) + silence(2.5) + song(12) + silence(2))

// 2. Quiet musical passage that must not split.
try write(
    "quiet-passage-no-split.wav",
    left: silence(1) + song(12) + song(12, amplitude: 0.03) + song(12) + silence(1))

// 3. Surface noise during the gaps.
try write(
    "surface-noise-gaps.wav",
    left: surfaceNoise(1.5) + song(12) + surfaceNoise(2) + song(12) + surfaceNoise(2)
        + song(12) + surfaceNoise(2))

// 4. A very short false gap.
try write(
    "false-short-gap.wav",
    left: song(12) + silence(0.4) + song(12))

// 5. Different left and right channel levels.
var left = song(12, amplitude: 0.6) + silence(2.5) + song(12, amplitude: 0.6)
var right = song(12, amplitude: 0.15) + silence(2.5) + song(12, amplitude: 0.15)
try write("unequal-stereo-levels.wav", left: left, right: right)

print("Done.")
