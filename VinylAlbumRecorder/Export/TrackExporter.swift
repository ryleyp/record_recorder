import Foundation
import AVFoundation
import Accelerate

enum ExportError: LocalizedError {
    case albumFolderExists(URL)
    case missingRecording(SideLabel)
    case audioReadFailed(String)
    case writeFailed(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .albumFolderExists(let url):
            return "An album folder already exists at \(url.path). Choose Replace to overwrite it or pick a different output folder."
        case .missingRecording(let side):
            return "The recording for \(side.title) is missing from the project."
        case .audioReadFailed(let message):
            return "The recording could not be read: \(message)"
        case .writeFailed(let message):
            return "Writing the exported files failed: \(message)"
        case .cancelled:
            return "Export was cancelled."
        }
    }
}

struct ExportResult {
    var albumFolder: URL
    var trackURLs: [URL] = []
    var playlistURL: URL?
    var originalsFolder: URL?
}

/// Renders each detected track to an individual MP3 and lays out the album
/// folder:
///
///     <output root>/
///       Artist Name/
///         Album Name/
///           01 - Song Title.mp3
///           ...
///           Album Artwork.jpg
///           Album.m3u                (optional)
///           Original Recordings/
///             Side A.wav
///             Side B.wav             (optional lossless copies)
enum TrackExporter {

    static let outputSampleRate = 44_100.0

    static func albumFolder(project: AlbumProject, outputRoot: URL) -> URL {
        let artist = FileNameSanitizer.sanitize(project.displayArtist, fallback: "Unknown Artist")
        let album = FileNameSanitizer.sanitize(project.displayTitle, fallback: "Untitled Album")
        return outputRoot
            .appendingPathComponent(artist, isDirectory: true)
            .appendingPathComponent(album, isDirectory: true)
    }

    /// Runs the full export. Call off the main thread; honors Task cancellation.
    /// `progress` receives (fraction 0…1, status message).
    static func export(
        project: AlbumProject,
        packageURL: URL,
        outputRoot: URL,
        allowOverwrite: Bool,
        progress: @escaping @Sendable (Double, String) -> Void
    ) throws -> ExportResult {
        let fm = FileManager.default
        let albumURL = albumFolder(project: project, outputRoot: outputRoot)

        if fm.fileExists(atPath: albumURL.path) {
            let contents = (try? fm.contentsOfDirectory(atPath: albumURL.path)) ?? []
            if !contents.isEmpty && !allowOverwrite {
                throw ExportError.albumFolderExists(albumURL)
            }
            if allowOverwrite {
                try? fm.removeItem(at: albumURL)
            }
        }
        do {
            try fm.createDirectory(at: albumURL, withIntermediateDirectories: true)
        } catch {
            throw ExportError.writeFailed(error.localizedDescription)
        }

        var result = ExportResult(albumFolder: albumURL)

        // Load artwork once.
        var artworkData: Data?
        if project.hasArtwork {
            artworkData = try? Data(contentsOf: ProjectStore.artworkURL(in: packageURL))
        }

        let order = project.exportOrder
        let totalTracks = max(order.count, 1)
        let totalSteps = Double(totalTracks) + (project.exportSettings.copyOriginalRecordings ? 1 : 0)

        var exportedDurations: [Double] = []

        for (position, entry) in order.enumerated() {
            try checkCancelled()
            let side = project.side(entry.side)
            guard side.hasRecording else { throw ExportError.missingRecording(entry.side) }
            let segments = side.segments
            guard entry.indexOnSide < segments.count else { continue }
            let segment = segments[entry.indexOnSide]

            let title = AlbumProject.effectiveTitle(entry.info, number: entry.number)
            let fileName = FileNameSanitizer.trackFileName(number: entry.number, title: title)
            let trackURL = albumURL.appendingPathComponent(fileName)
            progress(Double(position) / totalSteps, "Exporting \(fileName)")

            var tag = TrackTagInfo()
            tag.title = title
            tag.artist = entry.info.artist.isEmpty ? project.displayArtist : entry.info.artist
            tag.albumTitle = project.displayTitle
            tag.albumArtist = project.displayArtist
            tag.year = project.year
            tag.genre = project.genre
            tag.trackNumber = entry.number
            tag.trackTotal = order.count
            tag.discNumber = project.discNumber
            tag.discTotal = project.discTotal
            tag.artwork = artworkData

            let sourceURL = ProjectStore.recordingURL(for: entry.side, in: packageURL)
            try exportTrack(
                sourceURL: sourceURL,
                range: segment,
                tag: tag,
                settings: project.exportSettings,
                to: trackURL)
            result.trackURLs.append(trackURL)
            exportedDurations.append(segment.upperBound - segment.lowerBound)
        }

        // Artwork copy.
        if let artworkData {
            let artworkURL = albumURL.appendingPathComponent("Album Artwork.jpg")
            try? artworkData.write(to: artworkURL)
        }

        // Original lossless copies.
        if project.exportSettings.copyOriginalRecordings {
            try checkCancelled()
            progress(Double(totalTracks) / totalSteps, "Copying original recordings")
            let originalsURL = albumURL.appendingPathComponent("Original Recordings", isDirectory: true)
            try? fm.createDirectory(at: originalsURL, withIntermediateDirectories: true)
            for side in project.sides where side.hasRecording {
                let source = ProjectStore.recordingURL(for: side.side, in: packageURL)
                let destination = originalsURL.appendingPathComponent(side.side.exportedWAVName)
                try convertToWAV(source: source, destination: destination)
            }
            result.originalsFolder = originalsURL
        }

        // Playlist.
        if project.exportSettings.createM3UPlaylist {
            let playlistURL = albumURL.appendingPathComponent(
                FileNameSanitizer.sanitize(project.displayTitle) + ".m3u")
            var lines = ["#EXTM3U"]
            for (index, url) in result.trackURLs.enumerated() {
                let seconds = Int(exportedDurations[index].rounded())
                let name = url.deletingPathExtension().lastPathComponent
                lines.append("#EXTINF:\(seconds),\(name)")
                lines.append(url.lastPathComponent)
            }
            let text = lines.joined(separator: "\n") + "\n"
            try? text.write(to: playlistURL, atomically: true, encoding: .utf8)
            result.playlistURL = playlistURL
        }

        progress(1.0, "Done")
        return result
    }

    // MARK: One track

    /// Reads `range` seconds from the lossless source, applies optional gentle
    /// peak normalization and edge fades, resamples to 44.1 kHz, and encodes
    /// a CBR MP3 with an ID3v2.3 tag.
    static func exportTrack(
        sourceURL: URL,
        range: ClosedRange<Double>,
        tag: TrackTagInfo,
        settings: ExportSettings,
        to destination: URL
    ) throws {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: sourceURL)
        } catch {
            throw ExportError.audioReadFailed(error.localizedDescription)
        }
        let inFormat = file.processingFormat
        let inRate = inFormat.sampleRate
        let channels = min(Int(inFormat.channelCount), 2)

        let startFrame = AVAudioFramePosition(range.lowerBound * inRate)
        let endFrame = min(AVAudioFramePosition(range.upperBound * inRate), file.length)
        let segmentFrames = max(0, endFrame - startFrame)
        guard segmentFrames > 0 else {
            throw ExportError.audioReadFailed("The track has no audio (zero-length segment).")
        }

        // Optional pre-pass: find the segment's peak so normalization can
        // compute a single clean gain for the whole track.
        var gain: Float = 1.0
        if settings.normalizePeaks {
            let peak = try segmentPeak(file: file, startFrame: startFrame, endFrame: endFrame)
            if peak > 0 {
                let target = powf(10, Float(settings.normalizeTargetDB) / 20)
                gain = min(target / peak, 8.0) // never boost more than +18 dB
            }
        }

        let fadeInFrames = Int(settings.fadeInMilliseconds / 1000 * inRate)
        let fadeOutFrames = Int(settings.fadeOutMilliseconds / 1000 * inRate)

        // Resampler to 44.1 kHz when the device recorded at another rate.
        let needsResample = abs(inRate - outputSampleRate) > 0.5
        var converter: AVAudioConverter?
        var outFormat = inFormat
        if needsResample {
            guard let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: outputSampleRate,
                channels: inFormat.channelCount, interleaved: false),
                let created = AVAudioConverter(from: inFormat, to: format) else {
                throw ExportError.audioReadFailed("Could not prepare the 44.1 kHz resampler.")
            }
            converter = created
            outFormat = format
        }

        let encoder = try LameMP3Encoder(
            inputSampleRate: 44_100,
            channels: Int32(channels == 1 ? 1 : 2),
            bitrateKbps: Int32(settings.bitrate.rawValue))

        var output = Data()
        output.append(ID3TagWriter.makeTag(tag))

        let chunkCapacity: AVAudioFrameCount = 65_536
        guard let inBuffer = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: chunkCapacity) else {
            throw ExportError.audioReadFailed("Could not allocate a read buffer.")
        }

        file.framePosition = startFrame
        var framesRemaining = segmentFrames
        var framesConsumed: Int = 0

        func processConverted(_ buffer: AVAudioPCMBuffer) throws {
            let frames = Int(buffer.frameLength)
            guard frames > 0, let channelData = buffer.floatChannelData else { return }
            var interleaved = [Int16](repeating: 0, count: frames * max(channels, 1))
            if channels == 1 {
                let src = channelData[0]
                for i in 0..<frames {
                    interleaved[i] = clampToInt16(src[i] * gain)
                }
            } else {
                let left = channelData[0]
                let right = channelData[min(1, Int(buffer.format.channelCount) - 1)]
                for i in 0..<frames {
                    interleaved[i * 2] = clampToInt16(left[i] * gain)
                    interleaved[i * 2 + 1] = clampToInt16(right[i] * gain)
                }
            }
            output.append(try encoder.encode(interleavedSamples: interleaved, frames: frames))
        }

        while framesRemaining > 0 {
            try checkCancelled()
            let toRead = AVAudioFrameCount(min(Int64(chunkCapacity), framesRemaining))
            inBuffer.frameLength = 0
            do {
                try file.read(into: inBuffer, frameCount: toRead)
            } catch {
                break // truncated tail — export what exists
            }
            let readFrames = Int(inBuffer.frameLength)
            if readFrames == 0 { break }

            // Edge fades, applied in the source timeline.
            applyFades(
                buffer: inBuffer,
                segmentOffset: framesConsumed,
                segmentTotal: Int(segmentFrames),
                fadeInFrames: fadeInFrames,
                fadeOutFrames: fadeOutFrames)

            framesConsumed += readFrames
            framesRemaining -= Int64(readFrames)

            if let converter {
                let ratio = outputSampleRate / inRate
                let outCapacity = AVAudioFrameCount(Double(readFrames) * ratio) + 64
                guard let outBuffer = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: outCapacity) else {
                    throw ExportError.audioReadFailed("Could not allocate a resampling buffer.")
                }
                var fed = false
                var conversionError: NSError?
                let status = converter.convert(to: outBuffer, error: &conversionError) { _, outStatus in
                    if fed {
                        outStatus.pointee = .noDataNow
                        return nil
                    }
                    fed = true
                    outStatus.pointee = .haveData
                    return inBuffer
                }
                if status == .error {
                    throw ExportError.audioReadFailed(
                        conversionError?.localizedDescription ?? "Resampling failed.")
                }
                try processConverted(outBuffer)
            } else {
                try processConverted(inBuffer)
            }
        }

        // Drain the resampler.
        if let converter {
            guard let outBuffer = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: 16_384) else {
                throw ExportError.audioReadFailed("Could not allocate a resampling buffer.")
            }
            var conversionError: NSError?
            let status = converter.convert(to: outBuffer, error: &conversionError) { _, outStatus in
                outStatus.pointee = .endOfStream
                return nil
            }
            if status != .error {
                try processConverted(outBuffer)
            }
        }

        output.append(try encoder.finish())

        do {
            try output.write(to: destination, options: .atomic)
        } catch {
            throw ExportError.writeFailed(error.localizedDescription)
        }
    }

    // MARK: Lossless WAV copies

    static func convertToWAV(source: URL, destination: URL) throws {
        let input: AVAudioFile
        do {
            input = try AVAudioFile(forReading: source)
        } catch {
            throw ExportError.audioReadFailed(error.localizedDescription)
        }
        let format = input.processingFormat
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            let output = try AVAudioFile(
                forWriting: destination, settings: settings,
                commonFormat: format.commonFormat, interleaved: format.isInterleaved)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 262_144) else {
                throw ExportError.writeFailed("Could not allocate a copy buffer.")
            }
            while input.framePosition < input.length {
                try checkCancelled()
                buffer.frameLength = 0
                do {
                    try input.read(into: buffer)
                } catch {
                    break
                }
                if buffer.frameLength == 0 { break }
                try output.write(from: buffer)
            }
        } catch let error as ExportError {
            throw error
        } catch is CancellationError {
            throw ExportError.cancelled
        } catch {
            throw ExportError.writeFailed(error.localizedDescription)
        }
    }

    // MARK: Helpers

    private static func segmentPeak(
        file: AVAudioFile, startFrame: AVAudioFramePosition, endFrame: AVAudioFramePosition
    ) throws -> Float {
        let format = file.processingFormat
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 262_144) else {
            return 0
        }
        file.framePosition = startFrame
        var remaining = endFrame - startFrame
        var peak: Float = 0
        while remaining > 0 {
            try checkCancelled()
            let toRead = AVAudioFrameCount(min(Int64(buffer.frameCapacity), remaining))
            buffer.frameLength = 0
            do {
                try file.read(into: buffer, frameCount: toRead)
            } catch {
                break
            }
            let frames = Int(buffer.frameLength)
            if frames == 0 { break }
            remaining -= Int64(frames)
            guard let channelData = buffer.floatChannelData else { break }
            for channel in 0..<Int(format.channelCount) {
                var channelPeak: Float = 0
                vDSP_maxmgv(channelData[channel], 1, &channelPeak, vDSP_Length(frames))
                peak = max(peak, channelPeak)
            }
        }
        file.framePosition = startFrame
        return peak
    }

    /// Linear fade-in/out at the segment edges, in place.
    static func applyFades(
        buffer: AVAudioPCMBuffer,
        segmentOffset: Int,
        segmentTotal: Int,
        fadeInFrames: Int,
        fadeOutFrames: Int
    ) {
        guard fadeInFrames > 0 || fadeOutFrames > 0,
              let channelData = buffer.floatChannelData else { return }
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        for i in 0..<frames {
            let globalIndex = segmentOffset + i
            var factor: Float = 1
            if fadeInFrames > 0 && globalIndex < fadeInFrames {
                factor = Float(globalIndex) / Float(fadeInFrames)
            }
            let fromEnd = segmentTotal - globalIndex
            if fadeOutFrames > 0 && fromEnd <= fadeOutFrames {
                factor = min(factor, Float(max(fromEnd, 0)) / Float(fadeOutFrames))
            }
            if factor < 1 {
                for channel in 0..<channels {
                    channelData[channel][i] *= factor
                }
            }
        }
    }

    private static func clampToInt16(_ value: Float) -> Int16 {
        let scaled = value * 32_767
        if scaled > 32_767 { return 32_767 }
        if scaled < -32_768 { return -32_768 }
        return Int16(scaled)
    }

    private static func checkCancelled() throws {
        if Task.isCancelled {
            throw ExportError.cancelled
        }
    }
}
