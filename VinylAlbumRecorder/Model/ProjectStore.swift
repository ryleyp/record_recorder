import Foundation

enum ProjectStoreError: LocalizedError {
    case notAProject(String)
    case corruptProject(String)
    case saveFailed(String)

    var errorDescription: String? {
        switch self {
        case .notAProject(let path):
            return "\(path) is not a Vinyl Album Recorder project (expected a .\(AlbumProject.packageExtension) folder containing \(AlbumProject.projectFileName))."
        case .corruptProject(let message):
            return "The project file could not be read: \(message)"
        case .saveFailed(let message):
            return "The project could not be saved: \(message)"
        }
    }
}

/// Health of a project's audio files, surfaced when reopening a project.
struct ProjectAudioStatus {
    var missingSides: [SideLabel] = []
    /// A recording was in progress when the app last quit (crash or force quit).
    var interruptedSide: SideLabel?
}

/// Reads and writes the `.vinylproj` package: project.json, the CAF
/// recordings, artwork, and the crash-recovery marker.
enum ProjectStore {

    static let recoveryMarkerName = "recording-in-progress.json"

    private struct RecoveryMarker: Codable {
        var side: SideLabel
        var startedAt: Date
    }

    // MARK: Paths

    static func projectJSONURL(in packageURL: URL) -> URL {
        packageURL.appendingPathComponent(AlbumProject.projectFileName)
    }

    static func recordingsDirectory(in packageURL: URL) -> URL {
        packageURL.appendingPathComponent(AlbumProject.recordingsDirectoryName, isDirectory: true)
    }

    static func recordingURL(for side: SideLabel, in packageURL: URL) -> URL {
        recordingsDirectory(in: packageURL).appendingPathComponent(side.recordingFileName)
    }

    static func artworkURL(in packageURL: URL) -> URL {
        packageURL.appendingPathComponent(AlbumProject.artworkFileName)
    }

    // MARK: Create / open / save

    static func create(at packageURL: URL) throws -> AlbumProject {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: packageURL, withIntermediateDirectories: true)
            try fm.createDirectory(at: recordingsDirectory(in: packageURL), withIntermediateDirectories: true)
        } catch {
            throw ProjectStoreError.saveFailed(error.localizedDescription)
        }
        var project = AlbumProject()
        // Seed the album title from the package name the user chose.
        project.albumTitle = packageURL.deletingPathExtension().lastPathComponent
        try save(project, to: packageURL)
        return project
    }

    static func open(at packageURL: URL) throws -> AlbumProject {
        let jsonURL = projectJSONURL(in: packageURL)
        guard FileManager.default.fileExists(atPath: jsonURL.path) else {
            throw ProjectStoreError.notAProject(packageURL.path)
        }
        do {
            let data = try Data(contentsOf: jsonURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(AlbumProject.self, from: data)
        } catch {
            throw ProjectStoreError.corruptProject(error.localizedDescription)
        }
    }

    static func save(_ project: AlbumProject, to packageURL: URL) throws {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(project)
            try data.write(to: projectJSONURL(in: packageURL), options: .atomic)
        } catch {
            throw ProjectStoreError.saveFailed(error.localizedDescription)
        }
    }

    // MARK: Audio health / crash recovery

    /// Checks that every recorded side's audio file is still on disk, and
    /// whether a recording was interrupted by a crash.
    static func audioStatus(of project: AlbumProject, at packageURL: URL) -> ProjectAudioStatus {
        var status = ProjectAudioStatus()
        let fm = FileManager.default
        for side in project.sides where side.hasRecording {
            if side.audioIsMissing(in: packageURL) {
                status.missingSides.append(side.side)
            }
        }
        let markerURL = packageURL.appendingPathComponent(recoveryMarkerName)
        if let data = try? Data(contentsOf: markerURL),
           let marker = try? JSONDecoder().decode(RecoveryMarker.self, from: data) {
            // Only meaningful if the partial file actually exists.
            let partial = recordingURL(for: marker.side, in: packageURL)
            if fm.fileExists(atPath: partial.path) {
                status.interruptedSide = marker.side
            } else {
                try? fm.removeItem(at: markerURL)
            }
        }
        return status
    }

    /// Written when recording starts; removed on a clean stop. If the app
    /// crashes mid-recording, the marker plus the partially written CAF (which
    /// stays readable to its last frame) let the user keep the audio.
    static func writeRecoveryMarker(side: SideLabel, in packageURL: URL) {
        let marker = RecoveryMarker(side: side, startedAt: Date())
        if let data = try? JSONEncoder().encode(marker) {
            try? data.write(to: packageURL.appendingPathComponent(recoveryMarkerName), options: .atomic)
        }
    }

    static func clearRecoveryMarker(in packageURL: URL) {
        try? FileManager.default.removeItem(
            at: packageURL.appendingPathComponent(recoveryMarkerName))
    }
}
