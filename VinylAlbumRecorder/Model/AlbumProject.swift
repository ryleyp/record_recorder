import Foundation

enum SideLabel: String, Codable, CaseIterable, Identifiable {
    case a = "A"
    case b = "B"

    var id: String { rawValue }
    var title: String { "Side \(rawValue)" }
    var recordingFileName: String { "Side \(rawValue).caf" }
    var exportedWAVName: String { "Side \(rawValue).wav" }
}

/// One track's user-editable metadata. The audio range it covers is derived
/// from the side's boundaries, not stored here.
struct TrackInfo: Codable, Identifiable, Equatable {
    var id = UUID()
    var title: String = ""
    var artist: String = ""
}

/// One recorded side of the record.
struct RecordSide: Codable, Identifiable, Equatable {
    var id = UUID()
    var side: SideLabel
    /// Present once the side has been recorded (file lives in the project
    /// package under Recordings/).
    var hasRecording = false
    var sampleRate: Double?
    var channelCount: Int?
    var durationSeconds: Double?
    /// Cut points between tracks, seconds from the start of the file.
    var boundaries: [Double] = []
    /// Music start (everything before is discarded on export).
    var trimStart: Double = 0
    /// Music end (everything after is discarded on export). 0 = "not set",
    /// meaning the full duration is used.
    var trimEnd: Double = 0
    /// Per-track metadata; kept aligned with `segmentCount`.
    var tracks: [TrackInfo] = []
    var detectionSettings = DetectionSettings.default

    init(side: SideLabel) {
        self.side = side
    }

    var effectiveEnd: Double {
        let duration = durationSeconds ?? 0
        return trimEnd > 0 ? min(trimEnd, duration) : duration
    }

    var segmentCount: Int {
        hasRecording ? boundaries.count + 1 : 0
    }

    /// Time ranges of each track on this side, honoring trims and boundaries.
    var segments: [ClosedRange<Double>] {
        guard hasRecording else { return [] }
        let cuts = ([trimStart] + boundaries.sorted() + [effectiveEnd])
        var result: [ClosedRange<Double>] = []
        for i in 0..<(cuts.count - 1) where cuts[i + 1] > cuts[i] {
            result.append(cuts[i]...cuts[i + 1])
        }
        return result
    }

    /// Grows/shrinks `tracks` to match the segment count without losing
    /// titles the user already typed.
    mutating func reconcileTrackList() {
        let needed = segments.count
        if tracks.count < needed {
            tracks.append(contentsOf: (tracks.count..<needed).map { _ in TrackInfo() })
        } else if tracks.count > needed {
            tracks.removeLast(tracks.count - needed)
        }
    }
}

struct ExportSettings: Codable, Equatable {
    enum Bitrate: Int, Codable, CaseIterable, Identifiable {
        case kbps192 = 192
        case kbps256 = 256
        case kbps320 = 320
        var id: Int { rawValue }
        var title: String { "\(rawValue) kbps" }
    }

    var bitrate: Bitrate = .kbps320
    /// Off by default: keep the natural vinyl character.
    var normalizePeaks = false
    /// Gentle target when normalization is enabled.
    var normalizeTargetDB: Double = -1.0
    var fadeInMilliseconds: Double = 0
    /// A tiny fade-out avoids clicks at cut points without being audible.
    var fadeOutMilliseconds: Double = 15
    var createM3UPlaylist = true
    var copyOriginalRecordings = true
}

/// The saved album project. Serialized as project.json inside a
/// "<name>.vinylproj" package folder that also holds the recordings and
/// artwork:
///
///     MyAlbum.vinylproj/
///       project.json
///       Artwork.jpg            (optional)
///       Recordings/Side A.caf
///       Recordings/Side B.caf
struct AlbumProject: Codable, Equatable {
    static let formatVersion = 1
    static let packageExtension = "vinylproj"
    static let projectFileName = "project.json"
    static let artworkFileName = "Artwork.jpg"
    static let recordingsDirectoryName = "Recordings"

    var version = AlbumProject.formatVersion
    var id = UUID()
    var albumTitle = ""
    var albumArtist = ""
    var year: Int?
    var genre = ""
    var discNumber = 1
    var discTotal = 1
    var hasArtwork = false
    var sides: [RecordSide] = [RecordSide(side: .a), RecordSide(side: .b)]
    var exportSettings = ExportSettings()
    /// Last chosen export destination (path string; may be stale).
    var lastOutputFolderPath: String?

    var displayTitle: String {
        albumTitle.isEmpty ? "Untitled Album" : albumTitle
    }

    var displayArtist: String {
        albumArtist.isEmpty ? "Unknown Artist" : albumArtist
    }

    func side(_ label: SideLabel) -> RecordSide {
        sides.first { $0.side == label } ?? RecordSide(side: label)
    }

    mutating func updateSide(_ label: SideLabel, _ mutate: (inout RecordSide) -> Void) {
        guard let index = sides.firstIndex(where: { $0.side == label }) else { return }
        mutate(&sides[index])
    }

    /// All tracks across both sides in export order, with their global track
    /// numbers. Numbering continues from Side A into Side B.
    var exportOrder: [(side: SideLabel, indexOnSide: Int, number: Int, info: TrackInfo)] {
        var result: [(SideLabel, Int, Int, TrackInfo)] = []
        var number = 1
        for side in sides where side.hasRecording {
            for (index, info) in side.tracks.enumerated() {
                result.append((side.side, index, number, info))
                number += 1
            }
        }
        return result.map { (side: $0.0, indexOnSide: $0.1, number: $0.2, info: $0.3) }
    }

    var totalTrackCount: Int {
        sides.filter(\.hasRecording).reduce(0) { $0 + $1.tracks.count }
    }

    /// Effective title for a track, falling back to "Track NN".
    static func effectiveTitle(_ info: TrackInfo, number: Int) -> String {
        let trimmed = info.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? String(format: "Track %02d", number) : trimmed
    }
}
