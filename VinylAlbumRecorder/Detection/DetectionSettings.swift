import Foundation

enum DetectionPreset: String, Codable, CaseIterable, Identifiable {
    case conservative
    case balanced
    case aggressive

    var id: String { rawValue }

    var title: String {
        switch self {
        case .conservative: return "Conservative"
        case .balanced: return "Balanced"
        case .aggressive: return "Aggressive"
        }
    }

    var explanation: String {
        switch self {
        case .conservative:
            return "Only splits at long, clearly silent gaps. Best when songs have quiet passages that must not be split."
        case .balanced:
            return "Good default for most records."
        case .aggressive:
            return "Splits at shorter, less obvious gaps. Best for records with short or noisy gaps between songs."
        }
    }

    var settings: DetectionSettings {
        switch self {
        case .conservative:
            return DetectionSettings(
                preset: .conservative, silenceThresholdDB: -45,
                minimumGapSeconds: 2.5, minimumTrackSeconds: 45, minimumScore: 0.62)
        case .balanced:
            return DetectionSettings(
                preset: .balanced, silenceThresholdDB: -40,
                minimumGapSeconds: 1.5, minimumTrackSeconds: 30, minimumScore: 0.48)
        case .aggressive:
            return DetectionSettings(
                preset: .aggressive, silenceThresholdDB: -35,
                minimumGapSeconds: 1.0, minimumTrackSeconds: 25, minimumScore: 0.34)
        }
    }
}

struct DetectionSettings: Codable, Equatable {
    var preset: DetectionPreset = .balanced
    /// Envelope level below which audio counts as a candidate gap.
    var silenceThresholdDB: Double = -40
    /// A quiet stretch must last at least this long to be considered a break.
    var minimumGapSeconds: Double = 1.5
    /// Tracks shorter than this get merged into a neighbor.
    var minimumTrackSeconds: Double = 30
    /// Gap acceptance score cutoff (0…1).
    var minimumScore: Double = 0.48

    static let `default` = DetectionSettings()
}
