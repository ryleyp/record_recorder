import XCTest
@testable import VinylAlbumRecorder

final class TracklistParserTests: XCTestCase {

    func testParsesCommonLineShapes() {
        let text = """
        Artist: Fleetwood Mac
        Album: Rumours
        Year: 1977
        1. Second Hand News 2:56
        02 - Dreams (4:14)
        A3. Never Going Back Again – 2:02
        Don't Stop\t3:13
        5) Go Your Own Way [3:38]
        Songbird
        """
        let parsed = TracklistParser.parse(text)

        XCTAssertEqual(parsed.albumArtist, "Fleetwood Mac")
        XCTAssertEqual(parsed.albumTitle, "Rumours")
        XCTAssertEqual(parsed.year, 1977)
        XCTAssertEqual(parsed.entries.count, 6)
        XCTAssertEqual(parsed.entries[0].title, "Second Hand News")
        XCTAssertEqual(parsed.entries[0].duration ?? 0, 176, accuracy: 0.5)
        XCTAssertEqual(parsed.entries[1].title, "Dreams")
        XCTAssertEqual(parsed.entries[1].duration ?? 0, 254, accuracy: 0.5)
        XCTAssertEqual(parsed.entries[2].title, "Never Going Back Again")
        XCTAssertEqual(parsed.entries[3].title, "Don't Stop")
        XCTAssertEqual(parsed.entries[4].title, "Go Your Own Way")
        XCTAssertEqual(parsed.entries[4].duration ?? 0, 218, accuracy: 0.5)
        XCTAssertEqual(parsed.entries[5].title, "Songbird")
        XCTAssertNil(parsed.entries[5].duration)
        XCTAssertFalse(parsed.hasAllRuntimes)
    }

    func testTimestampParsing() {
        XCTAssertEqual(TracklistParser.seconds(fromTimestamp: "3:45"), 225)
        XCTAssertEqual(TracklistParser.seconds(fromTimestamp: "1:02:03"), 3723)
        XCTAssertNil(TracklistParser.seconds(fromTimestamp: "3:75"))
        XCTAssertNil(TracklistParser.seconds(fromTimestamp: "abc"))
    }

    func testTitlesWithNumbersSurvive() {
        let parsed = TracklistParser.parse("1. 99 Luftballons 3:52")
        XCTAssertEqual(parsed.entries.first?.title, "99 Luftballons")
        // A bare "19th Nervous Breakdown" keeps its leading number? The line
        // has no separator after "19th" digits+suffix, so the designator
        // regex must not strip it.
        let tricky = TracklistParser.parse("19th Nervous Breakdown 3:57")
        XCTAssertEqual(tricky.entries.first?.title, "19th Nervous Breakdown")
    }
}

final class TracklistAlignerTests: XCTestCase {

    /// Detection over three 40 s songs with 2.5 s gaps, then alignment with
    /// slightly-off sleeve runtimes (as real sleeves are).
    func testRuntimesSnapToDetectedGaps() {
        let samples = TestAudioFactory.threeSongsWithSilence(songDuration: 40, gapDuration: 2.5)
        let envelope = TestAudioFactory.envelope(of: samples)
        let detection = TrackDetector.detect(
            envelope: envelope, settings: DetectionPreset.balanced.settings)

        // Sleeve claims 0:42 / 0:41 / 0:39 — close but not exact.
        let entries = [
            TracklistEntry(title: "One", duration: 42),
            TracklistEntry(title: "Two", duration: 41),
            TracklistEntry(title: "Three", duration: 39),
        ]
        let boundaries = TracklistAligner.align(entries: entries, detection: detection)

        XCTAssertEqual(boundaries.count, 2)
        // Must land in the actual gaps (~42.75 s and ~85.25 s), i.e. snapped
        // to detection rather than at the raw cumulative runtimes.
        XCTAssertEqual(boundaries[0], 42.75, accuracy: 2.5)
        XCTAssertEqual(boundaries[1], 85.25, accuracy: 2.5)
    }

    /// Continuous audio (no gaps at all): cuts fall at the scaled runtime
    /// positions so the user has something sensible to nudge.
    func testRuntimesWithoutGapsFallBackToExpectedPositions() {
        let samples = TestAudioFactory.song(duration: 120)
        let envelope = TestAudioFactory.envelope(of: samples)
        let detection = TrackDetector.detect(
            envelope: envelope, settings: DetectionPreset.balanced.settings)
        XCTAssertTrue(detection.candidateGaps.isEmpty)

        let entries = [
            TracklistEntry(title: "One", duration: 60),
            TracklistEntry(title: "Two", duration: 60),
        ]
        let boundaries = TracklistAligner.align(entries: entries, detection: detection)
        XCTAssertEqual(boundaries.count, 1)
        XCTAssertEqual(boundaries[0], 60, accuracy: 5)
    }

    /// Titles only (no runtimes): the best-scoring gaps are used, and if the
    /// record offers fewer gaps than needed the rest are placed evenly.
    func testTitlesOnlyUsesBestGapsAndFills() {
        let samples = TestAudioFactory.threeSongsWithSilence(songDuration: 40, gapDuration: 2.5)
        let envelope = TestAudioFactory.envelope(of: samples)
        let detection = TrackDetector.detect(
            envelope: envelope, settings: DetectionPreset.balanced.settings)

        // Three real songs but the user lists four titles → 3 boundaries.
        let entries = ["A", "B", "C", "D"].map { TracklistEntry(title: $0, duration: nil) }
        let boundaries = TracklistAligner.align(entries: entries, detection: detection)

        XCTAssertEqual(boundaries.count, 3)
        XCTAssertEqual(boundaries, boundaries.sorted())
    }

    func testSingleTrackNeedsNoBoundaries() {
        let detection = DetectionResult(
            boundaries: [], candidateGaps: [],
            suggestedTrimStart: 0, suggestedTrimEnd: 100,
            effectiveThresholdDB: -40)
        XCTAssertTrue(TracklistAligner.align(
            entries: [TracklistEntry(title: "Only", duration: 100)],
            detection: detection).isEmpty)
    }
}

final class AudacityLabelTests: XCTestCase {

    func testParsesRegionLabels() {
        let text = """
        0.000000\t185.230000\tFirst Song
        187.100000\t402.500000\tSecond Song
        404.000000\t598.760000\tThird Song
        """
        let labels = AudacityLabels.parse(text)
        XCTAssertEqual(labels.count, 3)
        XCTAssertEqual(labels[1].start, 187.1, accuracy: 0.001)
        XCTAssertEqual(labels[1].title, "Second Song")
    }

    func testRegionLabelsBecomeTracksWithTrims() {
        let text = """
        1.500000\t185.230000\tFirst Song
        187.100000\t402.500000\tSecond Song
        404.000000\t598.760000\tThird Song
        """
        let applied = AudacityLabels.apply(
            labels: AudacityLabels.parse(text), duration: 600)

        XCTAssertNotNil(applied)
        XCTAssertEqual(applied?.boundaries.count, 2)
        XCTAssertEqual(applied?.boundaries[0] ?? 0, 187.1, accuracy: 0.001)
        XCTAssertEqual(applied?.trimStart ?? -1, 1.5, accuracy: 0.001)
        XCTAssertEqual(applied?.trimEnd ?? -1, 598.76, accuracy: 0.001)
        XCTAssertEqual(applied?.titles, ["First Song", "Second Song", "Third Song"])
    }

    func testPointLabelsBecomeCuts() {
        let text = """
        120.500000\t120.500000\t
        245.000000\t245.000000\t
        """
        let applied = AudacityLabels.apply(
            labels: AudacityLabels.parse(text), duration: 400)
        XCTAssertEqual(applied?.boundaries, [120.5, 245.0])
        XCTAssertEqual(applied?.trimStart, 0)
        XCTAssertEqual(applied?.trimEnd, 400)
    }

    func testGarbageLinesAreIgnored() {
        let text = """
        not a label
        12.0\tabc\tBroken
        30.0\t60.0\tGood One
        """
        let labels = AudacityLabels.parse(text)
        XCTAssertEqual(labels.count, 1)
        XCTAssertEqual(labels[0].title, "Good One")
    }

    func testEmptyTextYieldsNothing() {
        XCTAssertTrue(AudacityLabels.parse("").isEmpty)
        XCTAssertNil(AudacityLabels.apply(labels: [], duration: 100))
    }
}
