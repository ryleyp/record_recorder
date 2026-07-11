import Foundation
import AVFoundation

/// How a batch of chosen files should become project audio.
enum ImportMode: String, CaseIterable, Identifiable {
    /// One file holds a whole record side; run track detection on it.
    case wholeSide
    /// Every file is already one track; skip detection.
    case trackPerFile

    var id: String { rawValue }
    var title: String {
        switch self {
        case .wholeSide: return "One file = a whole side"
        case .trackPerFile: return "Each file = one track"
        }
    }
    var explanation: String {
        switch self {
        case .wholeSide:
            return "The file is a continuous recording of a record side. The app will detect the gaps between songs."
        case .trackPerFile:
            return "The files are already separate songs. No silence detection — each file becomes one track, in the order shown."
        }
    }
}

/// A file the user has staged in the import sheet, with its probe results.
struct StagedImportFile: Identifiable, Equatable {
    let id = UUID()
    var url: URL
    var info: AudioSourceInfo?
    var warnings: [String] = []
    var error: String?
    var title: String = ""
}

struct ImportRequest {
    var files: [StagedImportFile]
    var side: SideLabel
    var mode: ImportMode
    var copyIntoProject: Bool
    /// Contents of an Audacity label .txt to apply (wholeSide mode).
    var labelText: String?
    /// wholeSide with exactly two files: file 1 → Side A, file 2 → Side B.
    var splitAcrossSides: Bool = false
}

extension AppState {

    // MARK: Import execution

    /// Runs the import off the main thread, with progress and drive-removal
    /// safety, then routes the user to the right next stage.
    func performImport(_ request: ImportRequest) {
        guard let packageURL else { return }
        importProgress = 0
        importError = nil

        let files = request.files.filter { $0.error == nil }
        guard !files.isEmpty else {
            importError = "None of the selected files can be imported."
            importProgress = nil
            return
        }

        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                switch request.mode {
                case .wholeSide:
                    if request.splitAcrossSides && files.count >= 2 {
                        try await self?.importWholeSide(
                            file: files[0], side: .a, copy: request.copyIntoProject,
                            labelText: request.labelText, packageURL: packageURL,
                            progressBase: 0, progressSpan: 0.5)
                        try await self?.importWholeSide(
                            file: files[1], side: .b, copy: request.copyIntoProject,
                            labelText: nil, packageURL: packageURL,
                            progressBase: 0.5, progressSpan: 0.5)
                    } else {
                        try await self?.importWholeSide(
                            file: files[0], side: request.side, copy: request.copyIntoProject,
                            labelText: request.labelText, packageURL: packageURL,
                            progressBase: 0, progressSpan: 1)
                    }
                case .trackPerFile:
                    try await self?.importTrackList(
                        files: files, side: request.side,
                        copy: request.copyIntoProject, packageURL: packageURL)
                }
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.importProgress = nil
                    self.saveProjectNow()
                    self.stage = request.mode == .wholeSide ? .detect : .metadata
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.importProgress = nil
                    self?.importError = error.localizedDescription
                }
            }
        }
    }

    private func importWholeSide(
        file staged: StagedImportFile, side: SideLabel, copy: Bool,
        labelText: String?, packageURL: URL,
        progressBase: Double, progressSpan: Double
    ) async throws {
        await MainActor.run { self.importStatus = "Importing \(staged.url.lastPathComponent)…" }
        let (info, warnings) = try AudioImporter.probe(url: staged.url)

        var audioFileName: String?
        var referencedPath: String?
        var bookmark: Data?
        if copy {
            audioFileName = try AudioImporter.copyIntoProject(
                source: staged.url, packageURL: packageURL,
                preferredName: "Side \(side.rawValue) - \(staged.url.deletingPathExtension().lastPathComponent)")
        } else {
            referencedPath = staged.url.path
            bookmark = AudioImporter.bookmark(for: staged.url)
        }

        var applied: AudacityLabels.Applied?
        if let labelText {
            applied = AudacityLabels.apply(
                labels: AudacityLabels.parse(labelText),
                duration: info.durationSeconds)
        }

        await MainActor.run {
            self.importProgress = progressBase + progressSpan * 0.9
            self.updateSide(side) { record in
                record.hasRecording = true
                record.sourceType = .importedFile
                record.audioFileName = audioFileName
                record.referencedPath = referencedPath
                record.referencedBookmark = bookmark
                record.sourceInfo = info
                record.importWarnings = warnings
                record.sampleRate = info.sampleRate
                record.channelCount = info.channelCount
                record.durationSeconds = info.durationSeconds
                record.trackFiles = []
                record.tracks = []
                if let applied {
                    record.boundaries = applied.boundaries
                    record.trimStart = applied.trimStart
                    record.trimEnd = applied.trimEnd
                    record.reconcileTrackList()
                    for (index, title) in applied.titles.enumerated()
                    where index < record.tracks.count {
                        record.tracks[index].title = title
                    }
                } else {
                    record.boundaries = []
                    record.trimStart = 0
                    record.trimEnd = 0
                }
            }
            self.analyses[side] = nil
            self.lastDetection[side] = nil
        }
    }

    private func importTrackList(
        files: [StagedImportFile], side: SideLabel, copy: Bool, packageURL: URL
    ) async throws {
        var trackFiles: [ImportedTrackFile] = []
        var allWarnings: [String] = []
        var totalDuration = 0.0

        for (index, staged) in files.enumerated() {
            await MainActor.run {
                self.importStatus = "Importing \(staged.url.lastPathComponent)…"
                self.importProgress = Double(index) / Double(files.count)
            }
            guard VolumeWatcher.volumeIsMounted(for: staged.url) else {
                throw ImportError.sourceVanished(staged.url.lastPathComponent)
            }
            let (info, warnings) = try AudioImporter.probe(url: staged.url)
            var trackFile = ImportedTrackFile()
            trackFile.title = staged.title.isEmpty
                ? AudioImporter.embeddedTitle(of: staged.url)
                : staged.title
            trackFile.info = info
            if copy {
                trackFile.fileName = try AudioImporter.copyIntoProject(
                    source: staged.url, packageURL: packageURL,
                    preferredName: String(
                        format: "Side %@ Track %02d - %@",
                        side.rawValue, index + 1,
                        staged.url.deletingPathExtension().lastPathComponent))
            } else {
                trackFile.referencedPath = staged.url.path
                trackFile.bookmark = AudioImporter.bookmark(for: staged.url)
            }
            trackFiles.append(trackFile)
            allWarnings.append(contentsOf: warnings.map { "\(staged.url.lastPathComponent): \($0)" })
            totalDuration += info.durationSeconds
        }

        let finalTrackFiles = trackFiles
        let finalWarnings = allWarnings
        let finalDuration = totalDuration
        await MainActor.run {
            self.updateSide(side) { record in
                record.hasRecording = true
                record.sourceType = .importedFolder
                record.audioFileName = nil
                record.referencedPath = nil
                record.referencedBookmark = nil
                record.sourceInfo = finalTrackFiles.first?.info
                record.importWarnings = finalWarnings
                record.trackFiles = finalTrackFiles
                record.durationSeconds = finalDuration
                record.sampleRate = finalTrackFiles.first?.info?.sampleRate
                record.channelCount = finalTrackFiles.first?.info?.channelCount
                record.boundaries = []
                record.trimStart = 0
                record.trimEnd = 0
                record.tracks = []
                record.reconcileTrackList()
            }
            self.analyses[side] = nil
        }
    }

    // MARK: Tracklist-guided splitting

    /// Applies a pasted tracklist to the active side: album fields, track
    /// titles, and — when the side is a continuous recording — boundaries
    /// aligned to the detected gaps using the listed runtimes.
    func applyTracklist(_ text: String, to side: SideLabel) {
        let parsed = TracklistParser.parse(text)
        guard !parsed.entries.isEmpty else {
            errorMessage = "No tracks were found in the pasted text. One line per track, e.g. “1. Song Title 3:45”."
            return
        }

        if let album = parsed.albumTitle { project?.albumTitle = album }
        if let artist = parsed.albumArtist { project?.albumArtist = artist }
        if let year = parsed.year { project?.year = year }

        guard var current = project?.side(side), current.hasRecording else {
            errorMessage = "Record or import \(side.title) before applying a tracklist."
            return
        }

        if current.sourceType == .importedFolder {
            // Files are already tracks — just apply the names in order.
            applyTitles(parsed.entries.map(\.title), to: side)
            return
        }

        guard let analysis = analyses[side] else {
            errorMessage = "The recording is still being analyzed — try again in a moment."
            return
        }
        // Fresh detection to get scored candidate gaps for alignment.
        let detection = TrackDetector.detect(
            envelope: analysis.envelope,
            settings: current.detectionSettings)
        lastDetection[side] = detection

        let boundaries = TracklistAligner.align(entries: parsed.entries, detection: detection)
        updateSide(side) { record in
            record.boundaries = boundaries
            record.trimStart = detection.suggestedTrimStart
            record.trimEnd = detection.suggestedTrimEnd
            record.reconcileTrackList()
        }
        applyTitles(parsed.entries.map(\.title), to: side)
        _ = current // silence "never mutated" if optimizer complains
    }

    private func applyTitles(_ titles: [String], to side: SideLabel) {
        updateSide(side) { record in
            for (index, title) in titles.enumerated() where index < record.tracks.count {
                record.tracks[index].title = title
            }
        }
    }
}
