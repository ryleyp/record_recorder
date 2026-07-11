import Foundation
import AVFoundation
@testable import VinylAlbumRecorder

/// Generates synthetic "record side" audio for the automated tests: songs are
/// sine mixtures, gaps are silence or vinyl-style surface noise.
enum TestAudioFactory {

    static let sampleRate: Double = 44_100

    // MARK: Signal building blocks

    static func sine(frequency: Double, duration: Double, amplitude: Float) -> [Float] {
        let frames = Int(duration * sampleRate)
        return (0..<frames).map { i in
            amplitude * Float(sin(2 * .pi * frequency * Double(i) / sampleRate))
        }
    }

    /// A "song": a few sine partials so the level moves a bit.
    static func song(duration: Double, amplitude: Float = 0.4) -> [Float] {
        let frames = Int(duration * sampleRate)
        var result = [Float](repeating: 0, count: frames)
        for (index, frequency) in [220.0, 331.0, 442.0].enumerated() {
            let partialAmp = amplitude / Float(index + 2)
            for i in 0..<frames {
                result[i] += partialAmp * Float(sin(2 * .pi * frequency * Double(i) / sampleRate))
            }
        }
        return result
    }

    static func silence(duration: Double) -> [Float] {
        [Float](repeating: 0, count: Int(duration * sampleRate))
    }

    /// Vinyl-style surface noise: low-level white noise (seeded, reproducible).
    static func surfaceNoise(duration: Double, amplitudeDB: Float = -45) -> [Float] {
        let amplitude = powf(10, amplitudeDB / 20)
        var generator = SeededGenerator(seed: 42)
        return (0..<Int(duration * sampleRate)).map { _ in
            amplitude * (Float.random(in: -1...1, using: &generator))
        }
    }

    /// A song containing a deliberately quiet musical passage in the middle
    /// (about -30 dBFS) that must NOT be detected as a track break.
    static func songWithQuietPassage(duration: Double) -> [Float] {
        let third = duration / 3
        var samples = song(duration: third, amplitude: 0.4)
        samples += song(duration: third, amplitude: 0.03) // ≈ -30 dBFS peaks
        samples += song(duration: third, amplitude: 0.4)
        return samples
    }

    // MARK: Canonical test sides

    /// Three clear songs separated by true silence.
    static func threeSongsWithSilence(songDuration: Double = 40, gapDuration: Double = 2.5) -> [Float] {
        silence(duration: 1.5)
            + song(duration: songDuration)
            + silence(duration: gapDuration)
            + song(duration: songDuration)
            + silence(duration: gapDuration)
            + song(duration: songDuration)
            + silence(duration: 2.0)
    }

    /// Three songs whose gaps contain surface noise instead of silence, plus a
    /// very short false gap (0.4 s) inside the second song.
    static func noisyRealisticSide(songDuration: Double = 40) -> [Float] {
        var side = surfaceNoise(duration: 1.5)
        side += song(duration: songDuration)
        side += surfaceNoise(duration: 2.0)
        // Second song with a short dropout that must not split it.
        side += song(duration: songDuration / 2)
        side += surfaceNoise(duration: 0.4)
        side += song(duration: songDuration / 2)
        side += surfaceNoise(duration: 2.0)
        side += song(duration: songDuration)
        side += surfaceNoise(duration: 2.0)
        return side
    }

    // MARK: Envelope / file helpers

    static func envelope(of samples: [Float]) -> LoudnessEnvelope {
        LoudnessEnvelope.compute(samples: samples, sampleRate: sampleRate)
    }

    /// Writes mono or stereo samples to a 16-bit PCM file (CAF or WAV by extension).
    static func writeAudioFile(
        to url: URL, left: [Float], right: [Float]? = nil
    ) throws {
        let channels: AVAudioChannelCount = right == nil ? 1 : 2
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
            channels: channels, interleaved: false) else {
            throw NSError(domain: "TestAudioFactory", code: 1)
        }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let file = try AVAudioFile(
            forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let chunk = 65_536
        var offset = 0
        while offset < left.count {
            let count = min(chunk, left.count - offset)
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: format, frameCapacity: AVAudioFrameCount(count)) else { break }
            buffer.frameLength = AVAudioFrameCount(count)
            let leftPtr = buffer.floatChannelData![0]
            for i in 0..<count { leftPtr[i] = left[offset + i] }
            if let right, channels == 2 {
                let rightPtr = buffer.floatChannelData![1]
                for i in 0..<count { rightPtr[i] = right[offset + i] }
            }
            try file.write(from: buffer)
            offset += count
        }
    }

    static func temporaryDirectory(_ name: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("VinylAlbumRecorderTests", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

/// Deterministic RNG so noise-based tests are reproducible.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
}
