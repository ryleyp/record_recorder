import Foundation
import AVFoundation

enum ImportError: LocalizedError {
    case unsupportedFormat(String)
    case unreadable(String, String)
    case sourceVanished(String)
    case copyFailed(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let name):
            return "\(name) is not a supported audio format. Supported: MP3, WAV, AIFF, M4A, AAC, FLAC, and CAF."
        case .unreadable(let name, let reason):
            return "\(name) could not be read — it may be corrupted or in an unsupported encoding. (\(reason))"
        case .sourceVanished(let name):
            return "The source for \(name) disappeared during import — if it was on a USB drive or SD card, the drive may have been removed. Reconnect it and import again; nothing was damaged."
        case .copyFailed(let reason):
            return "The file could not be copied into the project: \(reason)"
        }
    }
}

/// Probing, validation, folder scanning, and copy/reference handling for the
/// "Import from USB or Folder" workflow. All functions are synchronous and
/// meant to be called off the main thread.
enum AudioImporter {

    static let supportedExtensions: Set<String> = [
        "mp3", "wav", "aif", "aiff", "m4a", "aac", "flac", "caf",
    ]

    /// File names that are clearly not music even when they carry an audio
    /// extension is rare; this list is for the folder scan's junk filter.
    private static let ignoredNames: Set<String> = [
        ".ds_store", "desktop.ini", "thumbs.db",
    ]

    static func isSupported(_ url: URL) -> Bool {
        supportedExtensions.contains(url.pathExtension.lowercased())
    }

    // MARK: Probe

    /// Reads a file's technical details and produces quality warnings.
    /// Throws for unsupported or unreadable/corrupt files.
    static func probe(url: URL) throws -> (info: AudioSourceInfo, warnings: [String]) {
        let name = url.lastPathComponent
        guard isSupported(url) else {
            throw ImportError.unsupportedFormat(name)
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ImportError.sourceVanished(name)
        }
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw ImportError.unreadable(name, error.localizedDescription)
        }

        let processingFormat = file.processingFormat
        let fileFormat = file.fileFormat
        guard file.length > 0, processingFormat.sampleRate > 0 else {
            throw ImportError.unreadable(name, "The file contains no audio.")
        }

        var info = AudioSourceInfo()
        info.fileExtension = url.pathExtension.lowercased()
        info.sampleRate = fileFormat.sampleRate > 0 ? fileFormat.sampleRate : processingFormat.sampleRate
        info.channelCount = Int(fileFormat.channelCount > 0 ? fileFormat.channelCount : processingFormat.channelCount)
        info.durationSeconds = Double(file.length) / processingFormat.sampleRate

        let formatID = fileFormat.streamDescription.pointee.mFormatID
        switch formatID {
        case kAudioFormatMPEGLayer3:
            info.formatName = "MP3"
        case kAudioFormatMPEG4AAC, kAudioFormatMPEG4AAC_HE, kAudioFormatMPEG4AAC_HE_V2:
            info.formatName = info.fileExtension == "aac" ? "AAC" : "M4A (AAC)"
        case kAudioFormatFLAC:
            info.formatName = "FLAC"
            info.isLossless = true
        case kAudioFormatAppleLossless:
            info.formatName = "Apple Lossless"
            info.isLossless = true
        case kAudioFormatLinearPCM:
            switch info.fileExtension {
            case "wav": info.formatName = "WAV"
            case "aif", "aiff": info.formatName = "AIFF"
            case "caf": info.formatName = "CAF"
            default: info.formatName = "PCM"
            }
            info.isLossless = true
            let bits = Int(fileFormat.streamDescription.pointee.mBitsPerChannel)
            info.bitDepth = bits > 0 ? bits : nil
        default:
            info.formatName = info.fileExtension.uppercased()
        }

        if !info.isLossless, info.durationSeconds > 0,
           let fileSize = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
            info.bitrateKbps = Int((Double(fileSize) * 8 / info.durationSeconds / 1000).rounded())
        }

        var warnings: [String] = []
        if info.channelCount < 2 {
            warnings.append("Mono file — the exported tracks will be mono.")
        }
        if let bitrate = info.bitrateKbps, bitrate < 128 {
            warnings.append("Heavily compressed (~\(bitrate) kbps). Quality is already limited; exporting to MP3 keeps that limit.")
        }
        if info.sampleRate < 32_000 {
            warnings.append(String(format: "Low sample rate (%.1f kHz).", info.sampleRate / 1000))
        }
        if info.durationSeconds < 5 {
            warnings.append("Unusually short (\(TimeFormat.mmss(info.durationSeconds))).")
        }
        return (info, warnings)
    }

    // MARK: Folder scan

    /// Finds supported audio files in a folder, ignoring hidden/system/artwork
    /// files, sorted by embedded track number where available (MP3 ID3),
    /// otherwise by name, then creation date.
    static func scanFolder(_ folderURL: URL) -> [URL] {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: [.isRegularFileKey, .creationDateKey],
            options: [.skipsHiddenFiles]) else {
            return []
        }
        let candidates = contents.filter { url in
            guard isSupported(url) else { return false }
            guard !ignoredNames.contains(url.lastPathComponent.lowercased()) else { return false }
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                return false
            }
            return true
        }

        struct Sortable {
            var url: URL
            var trackNumber: Int?
            var created: Date
        }
        let sortables = candidates.map { url -> Sortable in
            let created = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            return Sortable(url: url, trackNumber: embeddedTrackNumber(of: url), created: created)
        }

        let allNumbered = !sortables.isEmpty && sortables.allSatisfy { $0.trackNumber != nil }
        return sortables.sorted { lhs, rhs in
            if allNumbered, let l = lhs.trackNumber, let r = rhs.trackNumber, l != r {
                return l < r
            }
            let nameOrder = lhs.url.lastPathComponent.localizedStandardCompare(rhs.url.lastPathComponent)
            if nameOrder != .orderedSame {
                return nameOrder == .orderedAscending
            }
            return lhs.created < rhs.created
        }
        .map(\.url)
    }

    /// Track number from an MP3's ID3 tag (TRCK "3" or "3/12"), if any.
    static func embeddedTrackNumber(of url: URL) -> Int? {
        guard url.pathExtension.lowercased() == "mp3",
              let handle = try? FileHandle(forReadingFrom: url),
              let head = try? handle.read(upToCount: 128 * 1024) else { return nil }
        try? handle.close()
        guard let parsed = ID3TagWriter.parseTag(head),
              let trck = parsed.textFrames["TRCK"] else { return nil }
        return Int(trck.split(separator: "/").first ?? "")
    }

    /// Embedded title from an MP3's ID3 tag, else the file name stem.
    static func embeddedTitle(of url: URL) -> String {
        if url.pathExtension.lowercased() == "mp3",
           let handle = try? FileHandle(forReadingFrom: url),
           let head = try? handle.read(upToCount: 128 * 1024) {
            try? handle.close()
            if let parsed = ID3TagWriter.parseTag(head),
               let title = parsed.textFrames["TIT2"], !title.isEmpty {
                return title
            }
        }
        return url.deletingPathExtension().lastPathComponent
    }

    // MARK: Copy / reference

    /// Copies `source` into the package's Recordings folder under
    /// `preferredName` (extension preserved), never modifying the original.
    /// Detects mid-copy source removal (unplugged drive) and reports it
    /// clearly.
    static func copyIntoProject(
        source: URL, packageURL: URL, preferredName: String
    ) throws -> String {
        let fm = FileManager.default
        guard fm.fileExists(atPath: source.path) else {
            throw ImportError.sourceVanished(source.lastPathComponent)
        }
        let recordings = ProjectStore.recordingsDirectory(in: packageURL)
        try? fm.createDirectory(at: recordings, withIntermediateDirectories: true)

        let ext = source.pathExtension
        var name = FileNameSanitizer.sanitize(preferredName) + "." + ext
        var destination = recordings.appendingPathComponent(name)
        var counter = 2
        while fm.fileExists(atPath: destination.path) {
            name = FileNameSanitizer.sanitize(preferredName) + " \(counter)." + ext
            destination = recordings.appendingPathComponent(name)
            counter += 1
        }
        do {
            try fm.copyItem(at: source, to: destination)
        } catch {
            try? fm.removeItem(at: destination) // no half-copied leftovers
            if !fm.fileExists(atPath: source.path) {
                throw ImportError.sourceVanished(source.lastPathComponent)
            }
            throw ImportError.copyFailed(error.localizedDescription)
        }
        return name
    }

    static func bookmark(for url: URL) -> Data? {
        try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    }
}
