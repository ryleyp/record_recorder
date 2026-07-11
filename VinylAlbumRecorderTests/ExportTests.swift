import XCTest
import AVFoundation
@testable import VinylAlbumRecorder

final class ID3TagWriterTests: XCTestCase {

    func testTagRoundTripIncludingUnicode() {
        var info = TrackTagInfo()
        info.title = "Süßes Café — Track №1"
        info.artist = "Sigur Rós"
        info.albumTitle = "Ágætis byrjun"
        info.albumArtist = "Sigur Rós"
        info.year = 1999
        info.genre = "Post-Rock"
        info.trackNumber = 3
        info.trackTotal = 10
        info.discNumber = 1
        info.discTotal = 2

        let tag = ID3TagWriter.makeTag(info)
        let parsed = ID3TagWriter.parseTag(tag)

        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.textFrames["TIT2"], "Süßes Café — Track №1")
        XCTAssertEqual(parsed?.textFrames["TPE1"], "Sigur Rós")
        XCTAssertEqual(parsed?.textFrames["TALB"], "Ágætis byrjun")
        XCTAssertEqual(parsed?.textFrames["TPE2"], "Sigur Rós")
        XCTAssertEqual(parsed?.textFrames["TYER"], "1999")
        XCTAssertEqual(parsed?.textFrames["TCON"], "Post-Rock")
        XCTAssertEqual(parsed?.textFrames["TRCK"], "3/10")
        XCTAssertEqual(parsed?.textFrames["TPOS"], "1/2")
        XCTAssertEqual(parsed?.hasArtwork, false)
    }

    func testArtworkFrameIsIncluded() {
        var info = TrackTagInfo()
        info.title = "Art"
        info.artwork = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10]) // JPEG-ish header
        let tag = ID3TagWriter.makeTag(info)
        XCTAssertEqual(ID3TagWriter.parseTag(tag)?.hasArtwork, true)
    }

    func testDefaultMetadataStillCarriesTrackNumbering() {
        // Track/disc numbers always have values, so even a "blank" track gets
        // TRCK and TPOS frames — but no empty title/artist frames.
        let parsed = ID3TagWriter.parseTag(ID3TagWriter.makeTag(TrackTagInfo()))
        XCTAssertEqual(parsed?.textFrames["TRCK"], "1/1")
        XCTAssertEqual(parsed?.textFrames["TPOS"], "1/1")
        XCTAssertNil(parsed?.textFrames["TIT2"])
        XCTAssertNil(parsed?.textFrames["TPE1"])
    }
}

final class MP3ExportTests: XCTestCase {

    /// End-to-end: CAF side → exportTrack → MP3 that CoreAudio can decode,
    /// carrying the right ID3 metadata.
    func testExportedTrackIsAValidTaggedMP3() throws {
        let dir = TestAudioFactory.temporaryDirectory("mp3-export")
        let sourceURL = dir.appendingPathComponent("side.caf")
        // 10 s song, mixed stereo with different channel levels.
        let left = TestAudioFactory.song(duration: 10, amplitude: 0.5)
        let right = TestAudioFactory.song(duration: 10, amplitude: 0.25)
        try TestAudioFactory.writeAudioFile(to: sourceURL, left: left, right: right)

        var tag = TrackTagInfo()
        tag.title = "Test Song"
        tag.artist = "Test Artist"
        tag.albumTitle = "Test Album"
        tag.trackNumber = 1
        tag.trackTotal = 1

        var settings = ExportSettings()
        settings.bitrate = .kbps320

        let mp3URL = dir.appendingPathComponent("01 - Test Song.mp3")
        try TrackExporter.exportTrack(
            sourceURL: sourceURL, range: 0...10, tag: tag,
            settings: settings, to: mp3URL)

        // 1) The ID3 tag reads back.
        let data = try Data(contentsOf: mp3URL)
        let parsed = ID3TagWriter.parseTag(data)
        XCTAssertEqual(parsed?.textFrames["TIT2"], "Test Song")
        XCTAssertEqual(parsed?.textFrames["TRCK"], "1/1")

        // 2) CoreAudio decodes it with the expected duration (proxy for
        //    Apple Music compatibility).
        let decoded = try AVAudioFile(forReading: mp3URL)
        let duration = Double(decoded.length) / decoded.processingFormat.sampleRate
        XCTAssertEqual(duration, 10, accuracy: 0.3)
        XCTAssertEqual(decoded.processingFormat.sampleRate, 44_100)

        // 3) 320 kbps CBR: ~400 KB for 10 s (±15%).
        let expectedBytes = Double(320_000 / 8 * 10)
        XCTAssertEqual(Double(data.count), expectedBytes, accuracy: expectedBytes * 0.15)
    }

    func testTrimmedSegmentExportsOnlyTheRange() throws {
        let dir = TestAudioFactory.temporaryDirectory("mp3-trim")
        let sourceURL = dir.appendingPathComponent("side.caf")
        try TestAudioFactory.writeAudioFile(
            to: sourceURL, left: TestAudioFactory.song(duration: 30))

        let mp3URL = dir.appendingPathComponent("cut.mp3")
        try TrackExporter.exportTrack(
            sourceURL: sourceURL, range: 5...12, tag: TrackTagInfo(title: "Cut"),
            settings: ExportSettings(), to: mp3URL)

        let decoded = try AVAudioFile(forReading: mp3URL)
        let duration = Double(decoded.length) / decoded.processingFormat.sampleRate
        XCTAssertEqual(duration, 7, accuracy: 0.3)
    }

    func testNormalizationBoostsQuietAudio() throws {
        let dir = TestAudioFactory.temporaryDirectory("mp3-normalize")
        let sourceURL = dir.appendingPathComponent("quiet.caf")
        // Quiet source: peak 0.2 ≈ -14 dBFS (within the encoder's +18 dB
        // normalization boost cap).
        try TestAudioFactory.writeAudioFile(
            to: sourceURL, left: TestAudioFactory.sine(frequency: 440, duration: 5, amplitude: 0.2))

        var settings = ExportSettings()
        settings.normalizePeaks = true
        settings.normalizeTargetDB = -1

        let mp3URL = dir.appendingPathComponent("normalized.mp3")
        try TrackExporter.exportTrack(
            sourceURL: sourceURL, range: 0...5, tag: TrackTagInfo(title: "N"),
            settings: settings, to: mp3URL)

        let decoded = try AVAudioFile(forReading: mp3URL)
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: decoded.processingFormat,
            frameCapacity: AVAudioFrameCount(decoded.length)) else {
            return XCTFail("Could not allocate buffer")
        }
        try decoded.read(into: buffer)
        var peak: Float = 0
        let frames = Int(buffer.frameLength)
        if let channel = buffer.floatChannelData?[0] {
            for i in 0..<frames { peak = max(peak, abs(channel[i])) }
        }
        let peakDB = 20 * log10(peak)
        XCTAssertGreaterThan(peakDB, -4, "Normalization should lift the peak near -1 dBFS")
    }

    func testFadeSuppressesSegmentEdges() {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 44_100, channels: 1, interleaved: false),
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1000) else {
            return XCTFail("format")
        }
        buffer.frameLength = 1000
        let channel = buffer.floatChannelData![0]
        for i in 0..<1000 { channel[i] = 1.0 }

        TrackExporter.applyFades(
            buffer: buffer, segmentOffset: 0, segmentTotal: 1000,
            fadeInFrames: 100, fadeOutFrames: 100)

        XCTAssertEqual(channel[0], 0, accuracy: 0.02, "Start must fade from zero")
        XCTAssertEqual(channel[50], 0.5, accuracy: 0.05, "Midpoint of fade-in ≈ 0.5")
        XCTAssertEqual(channel[500], 1.0, "Middle untouched")
        XCTAssertLessThan(channel[999], 0.05, "End must fade to near zero")
    }

    /// The analyzer must handle stereo files with different L/R levels by
    /// mixing before detection.
    func testAnalyzerMixesUnequalStereoChannels() throws {
        let dir = TestAudioFactory.temporaryDirectory("analyze-stereo")
        let url = dir.appendingPathComponent("stereo.caf")
        var left = TestAudioFactory.song(duration: 20, amplitude: 0.6)
        left += TestAudioFactory.silence(duration: 2.5)
        left += TestAudioFactory.song(duration: 20, amplitude: 0.6)
        var right = TestAudioFactory.song(duration: 20, amplitude: 0.15)
        right += TestAudioFactory.silence(duration: 2.5)
        right += TestAudioFactory.song(duration: 20, amplitude: 0.15)
        try TestAudioFactory.writeAudioFile(to: url, left: left, right: right)

        let analysis = try SideAnalyzer.analyze(url: url)
        XCTAssertEqual(analysis.channelCount, 2)
        XCTAssertEqual(analysis.duration, 42.5, accuracy: 0.2)

        var settings = DetectionPreset.balanced.settings
        settings.minimumTrackSeconds = 15
        let result = TrackDetector.detect(envelope: analysis.envelope, settings: settings)
        XCTAssertEqual(result.boundaries.count, 1, "One gap between the two songs")
    }

    /// Full pipeline through TrackExporter.export: folder layout, playlist,
    /// WAV originals, numbering across sides.
    func testFullAlbumExportLayout() throws {
        let dir = TestAudioFactory.temporaryDirectory("album-export")
        let packageURL = dir.appendingPathComponent("Layout.vinylproj")
        var project = try ProjectStore.create(at: packageURL)
        project.albumTitle = "Layout: The/Album"
        project.albumArtist = "The Testers"
        project.year = 2024
        project.genre = "Test"

        // Side A: two 8 s songs; Side B: one 8 s song.
        var sideASamples = TestAudioFactory.song(duration: 8)
        sideASamples += TestAudioFactory.silence(duration: 2)
        sideASamples += TestAudioFactory.song(duration: 8)
        try TestAudioFactory.writeAudioFile(
            to: ProjectStore.recordingURL(for: .a, in: packageURL), left: sideASamples)
        try TestAudioFactory.writeAudioFile(
            to: ProjectStore.recordingURL(for: .b, in: packageURL),
            left: TestAudioFactory.song(duration: 8))

        project.updateSide(.a) { side in
            side.hasRecording = true
            side.durationSeconds = 18
            side.boundaries = [9]
            side.reconcileTrackList()
            side.tracks[0].title = "Opener"
            side.tracks[1].title = "Closer A"
        }
        project.updateSide(.b) { side in
            side.hasRecording = true
            side.durationSeconds = 8
            side.reconcileTrackList()
            side.tracks[0].title = "Only B"
        }

        let outputRoot = dir.appendingPathComponent("Music", isDirectory: true)
        let result = try TrackExporter.export(
            project: project, packageURL: packageURL, outputRoot: outputRoot,
            allowOverwrite: false) { _, _ in }

        let fm = FileManager.default
        // Sanitized folder names: "The Testers/Layout- The-Album"
        XCTAssertTrue(result.albumFolder.path.contains("The Testers"))
        XCTAssertTrue(result.albumFolder.lastPathComponent.contains("Layout- The-Album"))
        XCTAssertEqual(result.trackURLs.count, 3)
        XCTAssertEqual(result.trackURLs[0].lastPathComponent, "01 - Opener.mp3")
        XCTAssertEqual(result.trackURLs[1].lastPathComponent, "02 - Closer A.mp3")
        XCTAssertEqual(result.trackURLs[2].lastPathComponent, "03 - Only B.mp3")
        for url in result.trackURLs {
            XCTAssertTrue(fm.fileExists(atPath: url.path))
        }
        // Original WAVs.
        XCTAssertTrue(fm.fileExists(
            atPath: result.albumFolder.appendingPathComponent("Original Recordings/Side A.wav").path))
        XCTAssertTrue(fm.fileExists(
            atPath: result.albumFolder.appendingPathComponent("Original Recordings/Side B.wav").path))
        // Playlist exists and lists the tracks in order.
        let playlist = try String(contentsOf: result.playlistURL!, encoding: .utf8)
        XCTAssertTrue(playlist.hasPrefix("#EXTM3U"))
        XCTAssertTrue(playlist.contains("01 - Opener.mp3"))
        XCTAssertTrue(playlist.contains("03 - Only B.mp3"))
        // Side B track is tagged as number 3 of 3.
        let sideBData = try Data(contentsOf: result.trackURLs[2])
        XCTAssertEqual(ID3TagWriter.parseTag(sideBData)?.textFrames["TRCK"], "3/3")

        // Re-export without overwrite permission must fail.
        XCTAssertThrowsError(
            try TrackExporter.export(
                project: project, packageURL: packageURL, outputRoot: outputRoot,
                allowOverwrite: false) { _, _ in }
        ) { error in
            guard case ExportError.albumFolderExists = error else {
                return XCTFail("Expected albumFolderExists, got \(error)")
            }
        }
    }
}
