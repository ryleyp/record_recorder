import XCTest
@testable import VinylAlbumRecorder

final class TrackDetectorTests: XCTestCase {

    // MARK: Core detection

    func testThreeSongsSeparatedByClearSilence() {
        let samples = TestAudioFactory.threeSongsWithSilence(songDuration: 40, gapDuration: 2.5)
        let envelope = TestAudioFactory.envelope(of: samples)
        let result = TrackDetector.detect(envelope: envelope, settings: DetectionPreset.balanced.settings)

        XCTAssertEqual(result.boundaries.count, 2, "Three songs need exactly two boundaries")
        // Boundaries should land inside the gaps: after song 1 (~41.5–44 s) and song 2 (~84–86.5 s).
        XCTAssertEqual(result.boundaries[0], 42.75, accuracy: 2.0)
        XCTAssertEqual(result.boundaries[1], 85.25, accuracy: 2.0)
    }

    func testQuietMusicalPassageIsNotSplit() {
        // One long song with a -30 dBFS quiet middle: must remain one track.
        var samples = TestAudioFactory.silence(duration: 1.0)
        samples += TestAudioFactory.songWithQuietPassage(duration: 120)
        samples += TestAudioFactory.silence(duration: 1.0)
        let envelope = TestAudioFactory.envelope(of: samples)
        let result = TrackDetector.detect(envelope: envelope, settings: DetectionPreset.balanced.settings)

        XCTAssertTrue(
            result.boundaries.isEmpty,
            "Quiet passage was wrongly split at \(result.boundaries)")
    }

    func testSurfaceNoiseGapsAreStillDetected() {
        let samples = TestAudioFactory.noisyRealisticSide(songDuration: 40)
        let envelope = TestAudioFactory.envelope(of: samples)
        let result = TrackDetector.detect(envelope: envelope, settings: DetectionPreset.balanced.settings)

        XCTAssertEqual(
            result.boundaries.count, 2,
            "Expected 2 boundaries in noisy side, got \(result.boundaries)")
    }

    func testVeryShortFalseGapIsRejected() {
        // 0.4 s dropout inside a song: shorter than the 1.5 s minimum.
        var samples = TestAudioFactory.song(duration: 60)
        samples += TestAudioFactory.silence(duration: 0.4)
        samples += TestAudioFactory.song(duration: 60)
        let envelope = TestAudioFactory.envelope(of: samples)
        let result = TrackDetector.detect(envelope: envelope, settings: DetectionPreset.balanced.settings)

        XCTAssertTrue(result.boundaries.isEmpty, "Short dropout must not split the song")
    }

    // MARK: Trim logic

    func testLeadInAndRunOutBecomeTrimSuggestionsNotTracks() {
        let samples = TestAudioFactory.threeSongsWithSilence()
        let envelope = TestAudioFactory.envelope(of: samples)
        let result = TrackDetector.detect(envelope: envelope, settings: DetectionPreset.balanced.settings)

        // 1.5 s of lead-in silence → trim start near 1.5 s, not a boundary at ~0.
        XCTAssertEqual(result.suggestedTrimStart, 1.5, accuracy: 0.5)
        XCTAssertLessThan(result.suggestedTrimEnd, envelope.duration - 1.0)
        XCTAssertGreaterThan(
            result.boundaries.first ?? .infinity, 5,
            "Lead-in silence must not create a track boundary")
    }

    // MARK: Minimum track duration

    func testTracksShorterThanMinimumAreMerged() {
        // Two songs 10 s apart-in-length around a legit gap, but minimum track
        // length of 30 s should merge a 12-second "track".
        var samples = TestAudioFactory.song(duration: 12)
        samples += TestAudioFactory.silence(duration: 2.5)
        samples += TestAudioFactory.song(duration: 60)
        let envelope = TestAudioFactory.envelope(of: samples)
        var settings = DetectionPreset.balanced.settings
        settings.minimumTrackSeconds = 30
        let result = TrackDetector.detect(envelope: envelope, settings: settings)

        XCTAssertTrue(
            result.boundaries.isEmpty,
            "A 12 s segment is below the 30 s minimum and must be merged")
    }

    func testMinimumTrackMergeKeepsLongTracks() {
        let samples = TestAudioFactory.threeSongsWithSilence(songDuration: 45)
        let envelope = TestAudioFactory.envelope(of: samples)
        var settings = DetectionPreset.balanced.settings
        settings.minimumTrackSeconds = 30
        let result = TrackDetector.detect(envelope: envelope, settings: settings)

        XCTAssertEqual(result.boundaries.count, 2, "45 s tracks all clear the 30 s minimum")
    }

    // MARK: Presets

    func testConservativePresetRejectsShortGaps() {
        // 1.2 s gaps: balanced (1.5 min gap) rejects too; aggressive (1.0) accepts.
        let samples = TestAudioFactory.threeSongsWithSilence(songDuration: 40, gapDuration: 1.2)
        let envelope = TestAudioFactory.envelope(of: samples)

        let aggressive = TrackDetector.detect(
            envelope: envelope, settings: DetectionPreset.aggressive.settings)
        let conservative = TrackDetector.detect(
            envelope: envelope, settings: DetectionPreset.conservative.settings)

        XCTAssertEqual(aggressive.boundaries.count, 2, "Aggressive should split 1.2 s gaps")
        XCTAssertTrue(conservative.boundaries.isEmpty, "Conservative should ignore 1.2 s gaps")
    }

    // MARK: Scoring internals

    func testGapScoresRankLongDeepGapsHigher() {
        var samples = TestAudioFactory.song(duration: 40)
        samples += TestAudioFactory.silence(duration: 3.0)          // strong gap
        samples += TestAudioFactory.song(duration: 40)
        samples += TestAudioFactory.surfaceNoise(duration: 1.6, amplitudeDB: -42) // weaker gap
        samples += TestAudioFactory.song(duration: 40)
        let envelope = TestAudioFactory.envelope(of: samples)
        let result = TrackDetector.detect(envelope: envelope, settings: DetectionPreset.balanced.settings)

        XCTAssertEqual(result.candidateGaps.count, 2)
        XCTAssertGreaterThan(
            result.candidateGaps[0].score, result.candidateGaps[1].score,
            "The longer, silent gap must outscore the short, noisy one")
    }

    func testEmptyEnvelopeProducesNoBoundaries() {
        let envelope = LoudnessEnvelope(hopSeconds: 0.05, valuesDB: [])
        let result = TrackDetector.detect(envelope: envelope, settings: .default)
        XCTAssertTrue(result.boundaries.isEmpty)
    }
}
