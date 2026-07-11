import Foundation

/// One line of a pasted tracklist.
struct TracklistEntry: Equatable {
    var title: String
    /// Runtime in seconds, when the pasted list included one.
    var duration: Double?
}

/// Everything extracted from a pasted tracklist.
struct ParsedTracklist: Equatable {
    var entries: [TracklistEntry] = []
    var albumTitle: String?
    var albumArtist: String?
    var year: Int?

    var hasAllRuntimes: Bool {
        !entries.isEmpty && entries.allSatisfy { $0.duration != nil }
    }
}

/// Parses tracklists the user pastes from liner notes, Discogs, Wikipedia,
/// or anywhere else. Tolerated line shapes include:
///
///     1. Song Title 3:45          01 - Song Title (3:45)
///     Song Title\t3:45            A2. Song Title – 3:45
///     Song Title                  Track Title [2:30]
///
/// plus optional header lines:
///
///     Artist: The Rolling Stones
///     Album: Sticky Fingers
///     Year: 1971
enum TracklistParser {

    static func parse(_ text: String) -> ParsedTracklist {
        var result = ParsedTracklist()

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }

            // Header lines.
            if let value = headerValue(line, keys: ["artist", "album artist"]) {
                result.albumArtist = value
                continue
            }
            if let value = headerValue(line, keys: ["album", "album title", "title"]) {
                result.albumTitle = value
                continue
            }
            if let value = headerValue(line, keys: ["year"]), let year = Int(value) {
                result.year = year
                continue
            }

            var working = line

            // Trailing runtime: "3:45", "(3:45)", "[12:03]", "- 3:45", possibly h:mm:ss.
            var duration: Double?
            if let match = working.range(
                of: #"[\s\-–—\(\[]*(\d{1,2}:)?\d{1,2}:\d{2}[\)\]]?\s*$"#,
                options: .regularExpression) {
                let token = String(working[match])
                    .trimmingCharacters(in: CharacterSet(charactersIn: " -–—()[]\t"))
                if let seconds = seconds(fromTimestamp: token) {
                    duration = seconds
                    working = String(working[..<match.lowerBound])
                }
            }

            // Leading track designator: "1.", "01 -", "12)", "A2.", "B1 -".
            if let match = working.range(
                of: #"^[AaBb]?\d{1,3}[\.\):\-]?\s+|^[AaBb]?\d{1,3}\s*[\-–—\.]\s*"#,
                options: .regularExpression) {
                working = String(working[match.upperBound...])
            }

            let title = working.trimmingCharacters(in: CharacterSet(charactersIn: " -–—\t"))
            guard !title.isEmpty else { continue }
            result.entries.append(TracklistEntry(title: title, duration: duration))
        }
        return result
    }

    static func seconds(fromTimestamp token: String) -> Double? {
        let parts = token.split(separator: ":").map(String.init)
        guard parts.count == 2 || parts.count == 3,
              parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else {
            return nil
        }
        let numbers = parts.compactMap(Double.init)
        guard numbers.count == parts.count else { return nil }
        if numbers.count == 2 {
            guard numbers[1] < 60 else { return nil }
            return numbers[0] * 60 + numbers[1]
        }
        guard numbers[1] < 60, numbers[2] < 60 else { return nil }
        return numbers[0] * 3600 + numbers[1] * 60 + numbers[2]
    }

    private static func headerValue(_ line: String, keys: [String]) -> String? {
        for key in keys {
            if line.lowercased().hasPrefix(key + ":") {
                let value = line.dropFirst(key.count + 1)
                    .trimmingCharacters(in: .whitespaces)
                return value.isEmpty ? nil : value
            }
        }
        return nil
    }
}

/// Places track boundaries using a pasted tracklist: expected cut positions
/// come from the runtimes, then each cut snaps to the best-scoring detected
/// gap nearby. Runtimes on sleeves are approximate and turntable speed drifts,
/// so expected positions are scaled to the measured side length and given a
/// generous search window.
enum TracklistAligner {

    /// Returns `entries.count - 1` boundary times within (trimStart, trimEnd).
    static func align(
        entries: [TracklistEntry],
        detection: DetectionResult
    ) -> [Double] {
        let count = entries.count
        guard count >= 2 else { return [] }
        let start = detection.suggestedTrimStart
        let end = detection.suggestedTrimEnd
        guard end > start else { return [] }

        if entries.allSatisfy({ $0.duration != nil }) {
            return alignWithRuntimes(entries: entries, detection: detection)
        }

        // No runtimes: take the best-scoring candidate gaps, and if the record
        // didn't offer enough, fill the remainder by evenly subdividing the
        // longest resulting segments (the user adjusts in Review).
        var cuts = detection.candidateGaps
            .sorted { $0.score > $1.score }
            .prefix(count - 1)
            .map(\.cutTime)
            .sorted()
        while cuts.count < count - 1 {
            var points = ([start] + cuts + [end]).sorted()
            var longestIndex = 0
            var longestLength = 0.0
            for i in 0..<(points.count - 1) where points[i + 1] - points[i] > longestLength {
                longestLength = points[i + 1] - points[i]
                longestIndex = i
            }
            let middle = (points[longestIndex] + points[longestIndex + 1]) / 2
            cuts.append(middle)
            cuts.sort()
        }
        return cuts
    }

    private static func alignWithRuntimes(
        entries: [TracklistEntry],
        detection: DetectionResult
    ) -> [Double] {
        let start = detection.suggestedTrimStart
        let end = detection.suggestedTrimEnd
        let musicLength = end - start
        let totalRuntime = entries.compactMap(\.duration).reduce(0, +)
        guard totalRuntime > 0 else { return [] }

        // Sleeve runtimes vs. actual playback usually agree within a few
        // percent; clamp the correction so nonsense input can't fold the
        // timeline.
        let scale = min(max(musicLength / totalRuntime, 0.85), 1.15)
        let window = max(6.0, musicLength * 0.03)

        var boundaries: [Double] = []
        var cumulative = 0.0
        var usedCuts: Set<Int> = []

        for entry in entries.dropLast() {
            cumulative += entry.duration ?? 0
            let expected = start + cumulative * scale

            // Best gap near the expected position: high detection score,
            // small distance.
            var bestIndex: Int?
            var bestFitness = -Double.infinity
            for (index, gap) in detection.candidateGaps.enumerated() where !usedCuts.contains(index) {
                let distance = abs(gap.cutTime - expected)
                guard distance <= window else { continue }
                let fitness = gap.score - (distance / window) * 0.5
                if fitness > bestFitness {
                    bestFitness = fitness
                    bestIndex = index
                }
            }
            if let index = bestIndex {
                usedCuts.insert(index)
                boundaries.append(detection.candidateGaps[index].cutTime)
            } else {
                // No gap nearby (continuous audio or crossfade): place the cut
                // at the expected position for the user to fine-tune.
                boundaries.append(min(max(expected, start + 1), end - 1))
            }
        }
        return boundaries.sorted()
    }
}
