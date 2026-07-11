import Foundation
import AVFoundation
import Accelerate

/// Waveform + loudness analysis of one recorded side, produced once after
/// recording and reused for both display and track detection.
struct SideAnalysis {
    /// Per-bucket min/max sample values for waveform drawing (mixed to mono).
    struct PeakBucket {
        var minValue: Float
        var maxValue: Float
    }

    var duration: Double
    var sampleRate: Double
    var channelCount: Int
    /// Fixed-resolution peak buckets (one per `bucketSeconds`).
    var peaks: [PeakBucket]
    var bucketSeconds: Double
    /// RMS loudness envelope used by the track detector.
    var envelope: LoudnessEnvelope
}

enum SideAnalyzerError: LocalizedError {
    case unreadable(String)

    var errorDescription: String? {
        switch self {
        case .unreadable(let message):
            return "The recording could not be analyzed: \(message)"
        }
    }
}

enum SideAnalyzer {

    /// Reads the audio file in chunks off the calling thread and produces the
    /// waveform peaks and loudness envelope. `progress` is called with 0…1.
    static func analyze(
        url: URL,
        bucketSeconds: Double = 0.025,
        hopSeconds: Double = 0.05,
        progress: (@Sendable (Double) -> Void)? = nil
    ) throws -> SideAnalysis {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw SideAnalyzerError.unreadable(error.localizedDescription)
        }
        let format = file.processingFormat
        let sampleRate = format.sampleRate
        let channelCount = Int(format.channelCount)
        let totalFrames = file.length
        guard totalFrames > 0, sampleRate > 0 else {
            throw SideAnalyzerError.unreadable("The file contains no audio.")
        }

        let bucketFrames = max(1, Int(sampleRate * bucketSeconds))
        let hopFrames = max(1, Int(sampleRate * hopSeconds))

        var peaks: [SideAnalysis.PeakBucket] = []
        peaks.reserveCapacity(Int(totalFrames) / bucketFrames + 1)
        var envelopeDB: [Float] = []
        envelopeDB.reserveCapacity(Int(totalFrames) / hopFrames + 1)

        // Carry partial bucket/hop state across read chunks.
        var bucketMin: Float = .greatestFiniteMagnitude
        var bucketMax: Float = -.greatestFiniteMagnitude
        var bucketFill = 0
        var hopSumSquares: Double = 0
        var hopFill = 0

        let chunkFrames: AVAudioFrameCount = 262_144
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames) else {
            throw SideAnalyzerError.unreadable("Could not allocate an analysis buffer.")
        }
        var mono = [Float](repeating: 0, count: Int(chunkFrames))

        var framesRead: AVAudioFramePosition = 0
        while framesRead < totalFrames {
            buffer.frameLength = 0
            do {
                try file.read(into: buffer)
            } catch {
                // A truncated tail (e.g. from a crash mid-write) is not fatal:
                // analyze what was recovered.
                break
            }
            let frameCount = Int(buffer.frameLength)
            if frameCount == 0 { break }
            framesRead += AVAudioFramePosition(frameCount)

            guard let channelData = buffer.floatChannelData else { break }
            // Mix down to mono for analysis.
            if channelCount == 1 {
                mono.replaceSubrange(0..<frameCount, with: UnsafeBufferPointer(start: channelData[0], count: frameCount))
            } else {
                var half: Float = 0.5
                vDSP_vasm(channelData[0], 1, channelData[1], 1, &half, &mono, 1, vDSP_Length(frameCount))
            }

            for i in 0..<frameCount {
                let sample = mono[i]
                bucketMin = min(bucketMin, sample)
                bucketMax = max(bucketMax, sample)
                bucketFill += 1
                if bucketFill == bucketFrames {
                    peaks.append(.init(minValue: bucketMin, maxValue: bucketMax))
                    bucketMin = .greatestFiniteMagnitude
                    bucketMax = -.greatestFiniteMagnitude
                    bucketFill = 0
                }
                let s = Double(sample)
                hopSumSquares += s * s
                hopFill += 1
                if hopFill == hopFrames {
                    let rms = (hopSumSquares / Double(hopFill)).squareRoot()
                    envelopeDB.append(rms <= 0 ? -120 : max(-120, Float(20 * log10(rms))))
                    hopSumSquares = 0
                    hopFill = 0
                }
            }
            progress?(Double(framesRead) / Double(totalFrames))
        }

        if bucketFill > 0 {
            peaks.append(.init(minValue: min(bucketMin, 0), maxValue: max(bucketMax, 0)))
        }
        if hopFill > 0 {
            let rms = (hopSumSquares / Double(hopFill)).squareRoot()
            envelopeDB.append(rms <= 0 ? -120 : max(-120, Float(20 * log10(rms))))
        }

        return SideAnalysis(
            duration: Double(framesRead) / sampleRate,
            sampleRate: sampleRate,
            channelCount: channelCount,
            peaks: peaks,
            bucketSeconds: bucketSeconds,
            envelope: LoudnessEnvelope(hopSeconds: hopSeconds, valuesDB: envelopeDB))
    }
}
