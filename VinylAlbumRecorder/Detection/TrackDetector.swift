import Foundation

/// Loudness envelope of a recording: one RMS value (in dBFS) per hop.
struct LoudnessEnvelope: Equatable {
    /// Seconds between consecutive values.
    let hopSeconds: Double
    /// RMS level per hop, in dBFS (≤ 0, silence ≈ -120).
    let valuesDB: [Float]

    var duration: Double { Double(valuesDB.count) * hopSeconds }

    func time(atIndex index: Int) -> Double { Double(index) * hopSeconds }

    /// Builds an envelope from mono float samples. Stereo callers should mix
    /// or pass the louder channel; the analyzer mixes L+R before calling this.
    static func compute(samples: [Float], sampleRate: Double, hopSeconds: Double = 0.05) -> LoudnessEnvelope {
        let hopFrames = max(1, Int(sampleRate * hopSeconds))
        var values: [Float] = []
        values.reserveCapacity(samples.count / hopFrames + 1)
        var index = 0
        while index < samples.count {
            let end = min(index + hopFrames, samples.count)
            var sum: Double = 0
            for i in index..<end {
                let s = Double(samples[i])
                sum += s * s
            }
            let mean = sum / Double(end - index)
            let rms = Float(mean.squareRoot())
            values.append(rms <= 0 ? -120 : max(-120, 20 * log10f(rms)))
            index = end
        }
        return LoudnessEnvelope(hopSeconds: hopSeconds, valuesDB: values)
    }
}

/// One candidate gap between songs, with its score breakdown (useful for
/// debugging and for showing the user why a split was made).
struct DetectedGap: Equatable {
    var startTime: Double
    var endTime: Double
    /// Suggested cut point (the quietest moment inside the gap).
    var cutTime: Double
    var meanLevelDB: Double
    var score: Double

    var duration: Double { endTime - startTime }
}

struct DetectionResult: Equatable {
    /// Accepted cut points, in seconds, sorted ascending.
    var boundaries: [Double]
    /// All scored candidate gaps (accepted or not), for inspection.
    var candidateGaps: [DetectedGap]
    /// Where the music actually starts (end of lead-in silence), if any.
    var suggestedTrimStart: Double
    /// Where the music actually ends (start of run-out silence), if any.
    var suggestedTrimEnd: Double
    /// The adaptive threshold that was actually used, for display.
    var effectiveThresholdDB: Double
}

/// Splits a recorded record side into tracks by scoring quiet gaps.
///
/// Records rarely contain digital silence between songs — there is stylus
/// surface noise — so the detector adapts its threshold to the measured noise
/// floor and scores each candidate gap on duration, depth relative to the
/// surrounding music, and the energy jump where the next song starts.
enum TrackDetector {

    static func detect(envelope: LoudnessEnvelope, settings: DetectionSettings) -> DetectionResult {
        let values = envelope.valuesDB.map(Double.init)
        let hop = envelope.hopSeconds
        let duration = envelope.duration
        guard values.count > 4 else {
            return DetectionResult(
                boundaries: [], candidateGaps: [],
                suggestedTrimStart: 0, suggestedTrimEnd: duration,
                effectiveThresholdDB: settings.silenceThresholdDB)
        }

        let sorted = values.sorted()
        let noiseFloor = percentile(sorted, 0.05)
        let musicLevel = percentile(sorted, 0.85)

        struct Run { var start: Int; var end: Int } // half-open [start, end)

        // Finds quiet runs below `threshold` and splits off edge runs as
        // trim suggestions rather than track boundaries.
        func quietRuns(below threshold: Double) -> (runs: [Run], trimStart: Double, trimEnd: Double) {
            var runs: [Run] = []
            var runStart: Int?
            for (index, level) in values.enumerated() {
                if level < threshold {
                    if runStart == nil { runStart = index }
                } else if let start = runStart {
                    runs.append(Run(start: start, end: index))
                    runStart = nil
                }
            }
            if let start = runStart {
                runs.append(Run(start: start, end: values.count))
            }
            var trimStart = 0.0
            var trimEnd = duration
            if let first = runs.first, first.start == 0, Double(first.end - first.start) * hop >= 0.5 {
                trimStart = Double(first.end) * hop
                runs.removeFirst()
            }
            if let last = runs.last, last.end == values.count, Double(last.end - last.start) * hop >= 0.5 {
                trimEnd = Double(last.start) * hop
                runs.removeLast()
            }
            return (runs, trimStart, trimEnd)
        }

        // Primary pass uses the configured threshold (kept out of music
        // territory). If the record's gaps never get that quiet — worn vinyl
        // surface noise can sit at -35 dBFS — retry once with a threshold
        // adapted to the measured noise floor. The adaptive raise is a
        // fallback only: applying it unconditionally would split quiet
        // musical passages, which must never happen.
        var threshold = min(settings.silenceThresholdDB, musicLevel - 12, -20)
        var (runs, trimStart, trimEnd) = quietRuns(below: threshold)
        let hasUsableGap = runs.contains {
            Double($0.end - $0.start) * hop >= settings.minimumGapSeconds * 0.5
        }
        if !hasUsableGap {
            let adaptive = min(max(settings.silenceThresholdDB, noiseFloor + 8), musicLevel - 12, -20)
            if adaptive > threshold + 0.5 {
                threshold = adaptive
                (runs, trimStart, trimEnd) = quietRuns(below: threshold)
            }
        }

        // Quiet stretches longer than this are quiet passages or fades, not
        // gaps between songs — real inter-song gaps last a few seconds.
        let maximumGapSeconds = 15.0

        // Score interior gaps.
        let contextSeconds = 5.0
        let contextHops = max(1, Int(contextSeconds / hop))
        var gaps: [DetectedGap] = []
        for run in runs {
            let gapLength = Double(run.end - run.start) * hop
            // Consider anything at least half the minimum; scoring rejects weak ones.
            guard gapLength >= settings.minimumGapSeconds * 0.5,
                  gapLength <= maximumGapSeconds else { continue }

            let gapValues = Array(values[run.start..<run.end])
            // Depth uses the quietest half of the gap so clicks/pops inside a
            // real gap don't disqualify it.
            let quietHalf = gapValues.sorted().prefix(max(1, gapValues.count / 2))
            let gapLevel = quietHalf.reduce(0, +) / Double(quietHalf.count)

            let beforeRange = max(0, run.start - contextHops)..<run.start
            let afterRange = run.end..<min(values.count, run.end + contextHops)
            let beforeLevel = beforeRange.isEmpty ? musicLevel : mean(values[beforeRange])
            let afterLevel = afterRange.isEmpty ? musicLevel : mean(values[afterRange])
            let surroundLevel = (beforeLevel + afterLevel) / 2

            // 1) Longer gaps are more trustworthy (full credit at 2× minimum).
            let durationScore = min(gapLength / settings.minimumGapSeconds, 2) / 2
            // 2) How far the gap drops below the surrounding music.
            let depthScore = clamp((surroundLevel - gapLevel) / 25, 0, 1)
            // 3) A sharp energy rise right after the gap marks a song start.
            let edgeWindow = run.end..<min(values.count, run.end + max(1, Int(1.5 / hop)))
            let edgeLevel = edgeWindow.isEmpty ? afterLevel : mean(values[edgeWindow])
            let edgeScore = clamp((edgeLevel - gapLevel) / 30, 0, 1)

            let score = 0.40 * durationScore + 0.35 * depthScore + 0.25 * edgeScore

            // Cut at the quietest hop in the gap.
            var quietestIndex = run.start
            var quietestLevel = Double.infinity
            for i in run.start..<run.end where values[i] < quietestLevel {
                quietestLevel = values[i]
                quietestIndex = i
            }

            gaps.append(DetectedGap(
                startTime: Double(run.start) * hop,
                endTime: Double(run.end) * hop,
                cutTime: (Double(quietestIndex) + 0.5) * hop,
                meanLevelDB: gapLevel,
                score: score))
        }

        // Accept gaps that are long and convincing enough.
        var accepted = gaps.filter {
            $0.duration >= settings.minimumGapSeconds && $0.score >= settings.minimumScore
        }
        accepted.sort { $0.cutTime < $1.cutTime }

        // Enforce the minimum track length by dropping the weakest boundary
        // adjoining any too-short segment, until all segments are long enough.
        while !accepted.isEmpty {
            var cutPoints = [trimStart] + accepted.map(\.cutTime) + [trimEnd]
            cutPoints.sort()
            var shortSegmentIndex: Int?
            for i in 0..<(cutPoints.count - 1) where cutPoints[i + 1] - cutPoints[i] < settings.minimumTrackSeconds {
                shortSegmentIndex = i
                break
            }
            guard let segment = shortSegmentIndex else { break }
            // Boundaries adjoining segment i are accepted[segment-1] and accepted[segment].
            let leftBoundary = segment - 1
            let rightBoundary = segment
            let removeIndex: Int
            if leftBoundary < 0 {
                removeIndex = rightBoundary
            } else if rightBoundary >= accepted.count {
                removeIndex = leftBoundary
            } else {
                removeIndex = accepted[leftBoundary].score <= accepted[rightBoundary].score
                    ? leftBoundary : rightBoundary
            }
            guard removeIndex >= 0 && removeIndex < accepted.count else { break }
            accepted.remove(at: removeIndex)
        }

        return DetectionResult(
            boundaries: accepted.map(\.cutTime),
            candidateGaps: gaps,
            suggestedTrimStart: trimStart,
            suggestedTrimEnd: trimEnd,
            effectiveThresholdDB: threshold)
    }

    // MARK: helpers

    private static func percentile(_ sortedValues: [Double], _ fraction: Double) -> Double {
        guard !sortedValues.isEmpty else { return -120 }
        let index = Int(Double(sortedValues.count - 1) * fraction)
        return sortedValues[index]
    }

    private static func mean<C: Collection>(_ values: C) -> Double where C.Element == Double {
        guard !values.isEmpty else { return -120 }
        return values.reduce(0, +) / Double(values.count)
    }

    private static func clamp(_ value: Double, _ low: Double, _ high: Double) -> Double {
        min(max(value, low), high)
    }
}
