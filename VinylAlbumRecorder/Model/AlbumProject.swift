import Foundation

enum SideLabel: String, Codable, CaseIterable, Identifiable {
    case a = "A"
    case b = "B"

    var id: String { rawValue }
    var title: String { "Side \(rawValue)" }
    var recordingFileName: String { "Side \(rawValue).caf" }
    var exportedWAVName: String { "Side \(rawValue).wav" }
}

/// Where a side's audio came from.
enum SideSourceType: String, Codable {
    /// Recorded live from the USB audio input.
    case liveRecording
    /// One imported file holding the whole side (detection applies).
    case importedFile
    /// Multiple imported files, each one already a single track.
    case importedFolder
}

/// Technical description of an audio source file, shown to the user and used
/// for quality warnings and re-encode decisions.
struct AudioSourceInfo: Codable, Equatable {
    var formatName = ""          // "MP3", "WAV", "FLAC", …
    var fileExtension = ""
    var sampleRate: Double = 0
    var channelCount = 0
    var bitDepth: Int?           // PCM formats only
    var bitrateKbps: Int?        // compressed formats only (estimated)
    var durationSeconds: Double = 0
    var isLossless = false

    var isMP3: Bool { formatName == "MP3" }

    var summary: String {
        var parts = [formatName]
        if sampleRate > 0 { parts.append(String(format: "%.1f kHz", sampleRate / 1000)) }
        parts.append(channelCount >= 2 ? "Stereo" : "Mono")
        if let bitDepth { parts.append("\(bitDepth)-bit") }
        if let bitrateKbps { parts.append("~\(bitrateKbps) kbps") }
        if durationSeconds > 0 { parts.append(TimeFormat.mmss(durationSeconds)) }
        return parts.joined(separator: " · ")
    }
}

/// One imported file that is already a complete track (importedFolder mode).
struct ImportedTrackFile: Codable, Identifiable, Equatable {
    var id = UUID()
    /// File name inside the package's Recordings/ folder (copy mode).
    var fileName: String?
    /// Absolute path of the original (reference mode).
    var referencedPath: String?
    /// Bookmark so a moved/renamed referenced file can still be found.
    var bookmark: Data?
    var title = ""
    var info: AudioSourceInfo?

    func url(in packageURL: URL) -> URL? {
        if let fileName {
            return ProjectStore.recordingsDirectory(in: packageURL)
                .appendingPathComponent(fileName)
        }
        return ImportedTrackFile.resolveReference(path: referencedPath, bookmark: bookmark)
    }

    static func resolveReference(path: String?, bookmark: Data?) -> URL? {
        if let bookmark {
            var stale = false
            if let url = try? URL(
                resolvingBookmarkData: bookmark, options: [.withoutUI],
                relativeTo: nil, bookmarkDataIsStale: &stale),
                FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }
        if let path {
            let url = URL(fileURLWithPath: path)
            if FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }
        return nil
    }
}

/// One track's user-editable metadata. The audio range it covers is derived
/// from the side's boundaries (or its imported file), not stored here.
struct TrackInfo: Codable, Identifiable, Equatable {
    var id = UUID()
    var title: String = ""
    var artist: String = ""
}

/// One recorded or imported side of the record.
struct RecordSide: Codable, Identifiable, Equatable {
    var id = UUID()
    var side: SideLabel
    var hasRecording = false
    var sourceType: SideSourceType = .liveRecording
    /// Audio file name inside Recordings/ (live recordings and copied imports).
    var audioFileName: String?
    /// Reference-mode single imported file.
    var referencedPath: String?
    var referencedBookmark: Data?
    /// Technical info about the imported source (nil for live recordings).
    var sourceInfo: AudioSourceInfo?
    /// Quality/compatibility warnings produced at import time.
    var importWarnings: [String] = []
    /// importedFolder mode: the per-track files, in playback order.
    var trackFiles: [ImportedTrackFile] = []

    var sampleRate: Double?
    var channelCount: Int?
    var durationSeconds: Double?
    /// Cut points between tracks, seconds from the start of the file.
    var boundaries: [Double] = []
    var trimStart: Double = 0
    /// 0 = "not set" (use the full duration).
    var trimEnd: Double = 0
    /// Per-track metadata; kept aligned with `segmentCount`.
    var tracks: [TrackInfo] = []
    var detectionSettings = DetectionSettings.default

    init(side: SideLabel) {
        self.side = side
    }

    // MARK: Codable (manual decode so v1 project files still open)

    private enum CodingKeys: String, CodingKey {
        case id, side, hasRecording, sourceType, audioFileName, referencedPath
        case referencedBookmark, sourceInfo, importWarnings, trackFiles
        case sampleRate, channelCount, durationSeconds, boundaries
        case trimStart, trimEnd, tracks, detectionSettings
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        side = try c.decode(SideLabel.self, forKey: .side)
        hasRecording = try c.decodeIfPresent(Bool.self, forKey: .hasRecording) ?? false
        sourceType = try c.decodeIfPresent(SideSourceType.self, forKey: .sourceType) ?? .liveRecording
        audioFileName = try c.decodeIfPresent(String.self, forKey: .audioFileName)
        referencedPath = try c.decodeIfPresent(String.self, forKey: .referencedPath)
        referencedBookmark = try c.decodeIfPresent(Data.self, forKey: .referencedBookmark)
        sourceInfo = try c.decodeIfPresent(AudioSourceInfo.self, forKey: .sourceInfo)
        importWarnings = try c.decodeIfPresent([String].self, forKey: .importWarnings) ?? []
        trackFiles = try c.decodeIfPresent([ImportedTrackFile].self, forKey: .trackFiles) ?? []
        sampleRate = try c.decodeIfPresent(Double.self, forKey: .sampleRate)
        channelCount = try c.decodeIfPresent(Int.self, forKey: .channelCount)
        durationSeconds = try c.decodeIfPresent(Double.self, forKey: .durationSeconds)
        boundaries = try c.decodeIfPresent([Double].self, forKey: .boundaries) ?? []
        trimStart = try c.decodeIfPresent(Double.self, forKey: .trimStart) ?? 0
        trimEnd = try c.decodeIfPresent(Double.self, forKey: .trimEnd) ?? 0
        tracks = try c.decodeIfPresent([TrackInfo].self, forKey: .tracks) ?? []
        detectionSettings = try c.decodeIfPresent(
            DetectionSettings.self, forKey: .detectionSettings) ?? .default
    }

    // MARK: Audio resolution

    /// The playable/analyzable audio file for a single-file side.
    /// (importedFolder sides use `trackFiles[i].url(in:)` instead.)
    func audioURL(in packageURL: URL) -> URL? {
        guard hasRecording, sourceType != .importedFolder else { return nil }
        if let audioFileName {
            return ProjectStore.recordingsDirectory(in: packageURL)
                .appendingPathComponent(audioFileName)
        }
        if referencedPath != nil || referencedBookmark != nil {
            return ImportedTrackFile.resolveReference(
                path: referencedPath, bookmark: referencedBookmark)
        }
        // v1 projects stored no file name; the convention was "Side X.caf".
        return ProjectStore.recordingsDirectory(in: packageURL)
            .appendingPathComponent(side.recordingFileName)
    }

    /// True when the side's audio can't be found (moved/deleted source).
    func audioIsMissing(in packageURL: URL) -> Bool {
        guard hasRecording else { return false }
        if sourceType == .importedFolder {
            return trackFiles.contains { $0.url(in: packageURL) == nil } || trackFiles.isEmpty
        }
        guard let url = audioURL(in: packageURL) else { return true }
        return !FileManager.default.fileExists(atPath: url.path)
    }

    // MARK: Segments

    var effectiveEnd: Double {
        let duration = durationSeconds ?? 0
        return trimEnd > 0 ? min(trimEnd, duration) : duration
    }

    var segmentCount: Int {
        guard hasRecording else { return 0 }
        return sourceType == .importedFolder ? trackFiles.count : boundaries.count + 1
    }

    /// Time ranges of each track on this side. For importedFolder sides the
    /// ranges are a synthetic cumulative timeline of the file durations
    /// (used for duration display and playlists).
    var segments: [ClosedRange<Double>] {
        guard hasRecording else { return [] }
        if sourceType == .importedFolder {
            var result: [ClosedRange<Double>] = []
            var cursor = 0.0
            for file in trackFiles {
                let duration = max(file.info?.durationSeconds ?? 0, 0)
                result.append(cursor...(cursor + duration))
                cursor += duration
            }
            return result
        }
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
        let needed = segmentCount
        if tracks.count < needed {
            tracks.append(contentsOf: (tracks.count..<needed).map { _ in TrackInfo() })
        } else if tracks.count > needed {
            tracks.removeLast(tracks.count - needed)
        }
        // Seed titles from imported file titles where the user hasn't typed one.
        if sourceType == .importedFolder {
            for index in tracks.indices where tracks[index].title.isEmpty {
                tracks[index].title = trackFiles[index].title
            }
        }
    }

    /// Reorders an importedFolder side's tracks (file + metadata together).
    mutating func moveTrackFile(from source: Int, to destination: Int) {
        guard sourceType == .importedFolder,
              trackFiles.indices.contains(source),
              trackFiles.indices.contains(destination) else { return }
        let file = trackFiles.remove(at: source)
        trackFiles.insert(file, at: destination)
        if tracks.indices.contains(source) && tracks.indices.contains(destination) {
            let info = tracks.remove(at: source)
            tracks.insert(info, at: destination)
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
    var normalizeTargetDB: Double = -1.0
    var fadeInMilliseconds: Double = 0
    var fadeOutMilliseconds: Double = 15
    var createM3UPlaylist = true
    var copyOriginalRecordings = true
    /// When an imported track is already an MP3, copy its audio frames and
    /// just rewrite the tags instead of decoding + re-encoding (which loses
    /// quality). Applies to importedFolder tracks only — splitting a
    /// full-side MP3 inherently requires re-encoding.
    var keepOriginalEncoding = true

    init() {}

    private enum CodingKeys: String, CodingKey {
        case bitrate, normalizePeaks, normalizeTargetDB, fadeInMilliseconds
        case fadeOutMilliseconds, createM3UPlaylist, copyOriginalRecordings
        case keepOriginalEncoding
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bitrate = try c.decodeIfPresent(Bitrate.self, forKey: .bitrate) ?? .kbps320
        normalizePeaks = try c.decodeIfPresent(Bool.self, forKey: .normalizePeaks) ?? false
        normalizeTargetDB = try c.decodeIfPresent(Double.self, forKey: .normalizeTargetDB) ?? -1.0
        fadeInMilliseconds = try c.decodeIfPresent(Double.self, forKey: .fadeInMilliseconds) ?? 0
        fadeOutMilliseconds = try c.decodeIfPresent(Double.self, forKey: .fadeOutMilliseconds) ?? 15
        createM3UPlaylist = try c.decodeIfPresent(Bool.self, forKey: .createM3UPlaylist) ?? true
        copyOriginalRecordings = try c.decodeIfPresent(Bool.self, forKey: .copyOriginalRecordings) ?? true
        keepOriginalEncoding = try c.decodeIfPresent(Bool.self, forKey: .keepOriginalEncoding) ?? true
    }
}

/// The saved album project. Serialized as project.json inside a
/// "<name>.vinylproj" package folder that also holds the recordings and
/// artwork:
///
///     MyAlbum.vinylproj/
///       project.json
///       Artwork.jpg            (optional)
///       Recordings/Side A.caf  (live recordings and copied imports)
struct AlbumProject: Codable, Equatable {
    static let formatVersion = 2
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
    var lastOutputFolderPath: String?

    init() {}

    private enum CodingKeys: String, CodingKey {
        case version, id, albumTitle, albumArtist, year, genre, discNumber
        case discTotal, hasArtwork, sides, exportSettings, lastOutputFolderPath
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        albumTitle = try c.decodeIfPresent(String.self, forKey: .albumTitle) ?? ""
        albumArtist = try c.decodeIfPresent(String.self, forKey: .albumArtist) ?? ""
        year = try c.decodeIfPresent(Int.self, forKey: .year)
        genre = try c.decodeIfPresent(String.self, forKey: .genre) ?? ""
        discNumber = try c.decodeIfPresent(Int.self, forKey: .discNumber) ?? 1
        discTotal = try c.decodeIfPresent(Int.self, forKey: .discTotal) ?? 1
        hasArtwork = try c.decodeIfPresent(Bool.self, forKey: .hasArtwork) ?? false
        sides = try c.decodeIfPresent([RecordSide].self, forKey: .sides)
            ?? [RecordSide(side: .a), RecordSide(side: .b)]
        exportSettings = try c.decodeIfPresent(ExportSettings.self, forKey: .exportSettings)
            ?? ExportSettings()
        lastOutputFolderPath = try c.decodeIfPresent(String.self, forKey: .lastOutputFolderPath)
    }

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

    static func effectiveTitle(_ info: TrackInfo, number: Int) -> String {
        let trimmed = info.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? String(format: "Track %02d", number) : trimmed
    }
}
