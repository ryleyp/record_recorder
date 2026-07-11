import XCTest
import AVFoundation
@testable import VinylAlbumRecorder

final class AudioImporterTests: XCTestCase {

    /// Renders a small MP3 (via the app's own encoder) for import tests.
    private func makeMP3(
        in dir: URL, name: String, duration: Double = 6,
        title: String? = nil, trackNumber: Int? = nil
    ) throws -> URL {
        let sourceURL = dir.appendingPathComponent("src-\(name).caf")
        try TestAudioFactory.writeAudioFile(
            to: sourceURL, left: TestAudioFactory.song(duration: duration))
        var tag = TrackTagInfo()
        if let title { tag.title = title }
        if let trackNumber {
            tag.trackNumber = trackNumber
            tag.trackTotal = 12
        }
        let mp3URL = dir.appendingPathComponent(name)
        try TrackExporter.exportTrack(
            sourceURL: sourceURL, range: 0...duration, tag: tag,
            settings: ExportSettings(), to: mp3URL)
        try FileManager.default.removeItem(at: sourceURL)
        return mp3URL
    }

    func testProbeWAVReportsLosslessInfo() throws {
        let dir = TestAudioFactory.temporaryDirectory("probe-wav")
        let url = dir.appendingPathComponent("side.wav")
        let left = TestAudioFactory.song(duration: 8)
        try TestAudioFactory.writeAudioFile(to: url, left: left, right: left)

        let (info, warnings) = try AudioImporter.probe(url: url)
        XCTAssertEqual(info.formatName, "WAV")
        XCTAssertTrue(info.isLossless)
        XCTAssertEqual(info.channelCount, 2)
        XCTAssertEqual(info.bitDepth, 16)
        XCTAssertEqual(info.sampleRate, 44_100)
        XCTAssertEqual(info.durationSeconds, 8, accuracy: 0.1)
        XCTAssertNil(info.bitrateKbps)
        XCTAssertTrue(warnings.isEmpty, "Clean stereo WAV should have no warnings: \(warnings)")
    }

    func testProbeMP3ReportsBitrateAndFormat() throws {
        let dir = TestAudioFactory.temporaryDirectory("probe-mp3")
        let url = try makeMP3(in: dir, name: "side.mp3", duration: 10)

        let (info, _) = try AudioImporter.probe(url: url)
        XCTAssertEqual(info.formatName, "MP3")
        XCTAssertTrue(info.isMP3)
        XCTAssertFalse(info.isLossless)
        XCTAssertEqual(info.durationSeconds, 10, accuracy: 0.3)
        XCTAssertEqual(Double(info.bitrateKbps ?? 0), 320, accuracy: 40)
    }

    func testProbeWarnsAboutMonoFiles() throws {
        let dir = TestAudioFactory.temporaryDirectory("probe-mono")
        let url = dir.appendingPathComponent("mono.wav")
        try TestAudioFactory.writeAudioFile(to: url, left: TestAudioFactory.song(duration: 8))

        let (info, warnings) = try AudioImporter.probe(url: url)
        XCTAssertEqual(info.channelCount, 1)
        XCTAssertTrue(warnings.contains { $0.localizedCaseInsensitiveContains("mono") })
    }

    func testProbeRejectsCorruptFile() throws {
        let dir = TestAudioFactory.temporaryDirectory("probe-corrupt")
        let url = dir.appendingPathComponent("broken.wav")
        try Data([0x52, 0x49, 0x46, 0x46, 0x00, 0x01, 0x02]).write(to: url) // truncated RIFF

        XCTAssertThrowsError(try AudioImporter.probe(url: url)) { error in
            guard case ImportError.unreadable = error else {
                return XCTFail("Expected unreadable, got \(error)")
            }
        }
    }

    func testProbeRejectsUnsupportedExtension() throws {
        let dir = TestAudioFactory.temporaryDirectory("probe-unsupported")
        let url = dir.appendingPathComponent("notes.pdf")
        try Data("hello".utf8).write(to: url)

        XCTAssertThrowsError(try AudioImporter.probe(url: url)) { error in
            guard case ImportError.unsupportedFormat = error else {
                return XCTFail("Expected unsupportedFormat, got \(error)")
            }
        }
    }

    func testScanFolderFiltersJunkAndSortsByTrackNumber() throws {
        let dir = TestAudioFactory.temporaryDirectory("scan-folder")
        // Deliberately misleading file names: track numbers say the true order.
        _ = try makeMP3(in: dir, name: "zebra.mp3", title: "First", trackNumber: 1)
        _ = try makeMP3(in: dir, name: "apple.mp3", title: "Second", trackNumber: 2)
        _ = try makeMP3(in: dir, name: "mango.mp3", title: "Third", trackNumber: 3)
        // Junk that must be ignored.
        try Data("art".utf8).write(to: dir.appendingPathComponent("cover.jpg"))
        try Data("x".utf8).write(to: dir.appendingPathComponent(".hidden.mp3"))
        try Data("sys".utf8).write(to: dir.appendingPathComponent("notes.txt"))

        let found = AudioImporter.scanFolder(dir)
        XCTAssertEqual(found.map(\.lastPathComponent), ["zebra.mp3", "apple.mp3", "mango.mp3"])
    }

    func testScanFolderFallsBackToFilenameOrder() throws {
        let dir = TestAudioFactory.temporaryDirectory("scan-names")
        for name in ["03 three.wav", "01 one.wav", "02 two.wav", "10 ten.wav"] {
            try TestAudioFactory.writeAudioFile(
                to: dir.appendingPathComponent(name),
                left: TestAudioFactory.song(duration: 1))
        }
        let found = AudioImporter.scanFolder(dir)
        XCTAssertEqual(
            found.map(\.lastPathComponent),
            ["01 one.wav", "02 two.wav", "03 three.wav", "10 ten.wav"])
    }

    func testEmbeddedTitleAndTrackNumberAreRead() throws {
        let dir = TestAudioFactory.temporaryDirectory("embedded")
        let url = try makeMP3(in: dir, name: "x.mp3", title: "Gimme Shelter", trackNumber: 4)
        XCTAssertEqual(AudioImporter.embeddedTitle(of: url), "Gimme Shelter")
        XCTAssertEqual(AudioImporter.embeddedTrackNumber(of: url), 4)
    }

    func testCopyIntoProjectPreservesOriginalAndAvoidsCollisions() throws {
        let dir = TestAudioFactory.temporaryDirectory("copy-import")
        let packageURL = dir.appendingPathComponent("P.vinylproj")
        _ = try ProjectStore.create(at: packageURL)
        let source = dir.appendingPathComponent("song.wav")
        try TestAudioFactory.writeAudioFile(to: source, left: TestAudioFactory.song(duration: 2))
        let originalData = try Data(contentsOf: source)

        let name1 = try AudioImporter.copyIntoProject(
            source: source, packageURL: packageURL, preferredName: "Side A - song")
        let name2 = try AudioImporter.copyIntoProject(
            source: source, packageURL: packageURL, preferredName: "Side A - song")

        XCTAssertNotEqual(name1, name2, "Second copy must get a distinct name")
        XCTAssertEqual(try Data(contentsOf: source), originalData, "Original must be untouched")
        let copied = ProjectStore.recordingsDirectory(in: packageURL).appendingPathComponent(name1)
        XCTAssertEqual(try Data(contentsOf: copied), originalData)
    }

    func testMissingSourceIsReportedAfterMove() throws {
        let dir = TestAudioFactory.temporaryDirectory("moved-source")
        let packageURL = dir.appendingPathComponent("Moved.vinylproj")
        var project = try ProjectStore.create(at: packageURL)
        let external = dir.appendingPathComponent("external.wav")
        try TestAudioFactory.writeAudioFile(to: external, left: TestAudioFactory.song(duration: 2))

        project.updateSide(.a) { side in
            side.hasRecording = true
            side.sourceType = .importedFile
            side.referencedPath = external.path
            // No bookmark: simulates the file being fully gone.
        }
        XCTAssertTrue(ProjectStore.audioStatus(of: project, at: packageURL).missingSides.isEmpty)

        try FileManager.default.removeItem(at: external)
        XCTAssertEqual(
            ProjectStore.audioStatus(of: project, at: packageURL).missingSides, [.a])
    }
}

final class MP3PassthroughTests: XCTestCase {

    func testStripTagsRemovesID3v2AndV1() {
        var tagged = ID3TagWriter.makeTag(TrackTagInfo(title: "Old Title"))
        let frames = Data(repeating: 0xFF, count: 4096) // stand-in audio frames
        tagged.append(frames)
        var v1 = Data("TAG".utf8)
        v1.append(Data(count: 125))
        tagged.append(v1)

        XCTAssertEqual(MP3Retagger.stripTags(tagged), frames)
    }

    func testStripTagsLeavesBareFramesAlone() {
        let frames = Data([0xFF, 0xFB, 0x90, 0x00] + Array(repeating: 0x11, count: 512))
        XCTAssertEqual(MP3Retagger.stripTags(frames), frames)
    }

    /// The "Keep original encoding" promise: after export, the audio frames
    /// are byte-identical to the imported MP3 — only tags changed.
    func testPassthroughExportDoesNotReencode() throws {
        let dir = TestAudioFactory.temporaryDirectory("passthrough")
        let packageURL = dir.appendingPathComponent("Pass.vinylproj")
        var project = try ProjectStore.create(at: packageURL)
        project.albumTitle = "Pass Album"
        project.albumArtist = "Tester"

        // Build two source MP3s and import them as track files (copy mode).
        var sourceFrames: [Data] = []
        var trackFiles: [ImportedTrackFile] = []
        for index in 0..<2 {
            let caf = dir.appendingPathComponent("s\(index).caf")
            try TestAudioFactory.writeAudioFile(
                to: caf, left: TestAudioFactory.song(duration: 4, amplitude: 0.3 + Float(index) * 0.1))
            let mp3 = dir.appendingPathComponent("song\(index).mp3")
            var tag = TrackTagInfo()
            tag.title = "Original \(index)"
            try TrackExporter.exportTrack(
                sourceURL: caf, range: 0...4, tag: tag,
                settings: ExportSettings(), to: mp3)
            sourceFrames.append(MP3Retagger.stripTags(try Data(contentsOf: mp3)))

            let copied = try AudioImporter.copyIntoProject(
                source: mp3, packageURL: packageURL,
                preferredName: "Side A Track 0\(index + 1) - song\(index)")
            var trackFile = ImportedTrackFile()
            trackFile.fileName = copied
            trackFile.title = "Imported Song \(index + 1)"
            trackFile.info = try AudioImporter.probe(
                url: ProjectStore.recordingsDirectory(in: packageURL).appendingPathComponent(copied)).info
            trackFiles.append(trackFile)
        }

        let files = trackFiles
        project.updateSide(.a) { side in
            side.hasRecording = true
            side.sourceType = .importedFolder
            side.trackFiles = files
            side.reconcileTrackList()
        }
        project.exportSettings.keepOriginalEncoding = true

        let outputRoot = dir.appendingPathComponent("Out")
        let result = try TrackExporter.export(
            project: project, packageURL: packageURL, outputRoot: outputRoot,
            allowOverwrite: false) { _, _ in }

        XCTAssertEqual(result.trackURLs.count, 2)
        for (index, url) in result.trackURLs.enumerated() {
            let exported = try Data(contentsOf: url)
            XCTAssertEqual(
                MP3Retagger.stripTags(exported), sourceFrames[index],
                "Track \(index) audio frames must be byte-identical (no re-encode)")
            let parsed = ID3TagWriter.parseTag(exported)
            XCTAssertEqual(parsed?.textFrames["TIT2"], "Imported Song \(index + 1)")
            XCTAssertEqual(parsed?.textFrames["TALB"], "Pass Album")
            XCTAssertEqual(parsed?.textFrames["TRCK"], "\(index + 1)/2")
        }
    }

    /// Full-side WAV import → detection → per-track MP3 export, plus
    /// numbering continuing onto an imported Side B track list.
    func testImportedSidesNumberAcrossAAndB() throws {
        let dir = TestAudioFactory.temporaryDirectory("import-number")
        let packageURL = dir.appendingPathComponent("N.vinylproj")
        var project = try ProjectStore.create(at: packageURL)

        // Side A: full-side WAV with two songs, imported (copy mode).
        var sideA = TestAudioFactory.song(duration: 8)
        sideA += TestAudioFactory.silence(duration: 2)
        sideA += TestAudioFactory.song(duration: 8)
        let wav = dir.appendingPathComponent("sideA.wav")
        try TestAudioFactory.writeAudioFile(to: wav, left: sideA)
        let copiedName = try AudioImporter.copyIntoProject(
            source: wav, packageURL: packageURL, preferredName: "Side A - sideA")
        project.updateSide(.a) { side in
            side.hasRecording = true
            side.sourceType = .importedFile
            side.audioFileName = copiedName
            side.durationSeconds = 18
            side.boundaries = [9]
            side.reconcileTrackList()
        }

        // Side B: one imported track file.
        let bTrack = dir.appendingPathComponent("b1.wav")
        try TestAudioFactory.writeAudioFile(to: bTrack, left: TestAudioFactory.song(duration: 5))
        let bName = try AudioImporter.copyIntoProject(
            source: bTrack, packageURL: packageURL, preferredName: "Side B Track 01 - b1")
        var bFile = ImportedTrackFile()
        bFile.fileName = bName
        bFile.title = "B Song"
        bFile.info = try AudioImporter.probe(
            url: ProjectStore.recordingsDirectory(in: packageURL).appendingPathComponent(bName)).info
        let finalBFile = bFile
        project.updateSide(.b) { side in
            side.hasRecording = true
            side.sourceType = .importedFolder
            side.trackFiles = [finalBFile]
            side.reconcileTrackList()
        }

        let result = try TrackExporter.export(
            project: project, packageURL: packageURL,
            outputRoot: dir.appendingPathComponent("Out"),
            allowOverwrite: false) { _, _ in }

        XCTAssertEqual(result.trackURLs.count, 3)
        let lastData = try Data(contentsOf: result.trackURLs[2])
        XCTAssertEqual(ID3TagWriter.parseTag(lastData)?.textFrames["TRCK"], "3/3")
        XCTAssertEqual(ID3TagWriter.parseTag(lastData)?.textFrames["TIT2"], "B Song")
    }
}
