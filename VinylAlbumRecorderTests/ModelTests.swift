import XCTest
@testable import VinylAlbumRecorder

final class FileNameSanitizerTests: XCTestCase {

    func testIllegalCharactersAreReplaced() {
        XCTAssertEqual(FileNameSanitizer.sanitize("AC/DC: Back?"), "AC-DC- Back-")
        XCTAssertEqual(FileNameSanitizer.sanitize("What <Is> \"Love\"|*"), "What -Is- -Love---")
        XCTAssertEqual(FileNameSanitizer.sanitize("a\\b"), "a-b")
    }

    func testWhitespaceIsCollapsedAndTrimmed() {
        XCTAssertEqual(FileNameSanitizer.sanitize("  Hello   World  "), "Hello World")
        XCTAssertEqual(FileNameSanitizer.sanitize("Line\nBreak\tTab"), "Line Break Tab")
    }

    func testLeadingDotsAndTrailingDotsRemoved() {
        XCTAssertEqual(FileNameSanitizer.sanitize(".hidden"), "hidden")
        XCTAssertEqual(FileNameSanitizer.sanitize("Name..."), "Name")
    }

    func testEmptyFallsBackToDefault() {
        XCTAssertEqual(FileNameSanitizer.sanitize("   "), "Untitled")
        XCTAssertEqual(FileNameSanitizer.sanitize("///", fallback: "Track 01"), "---")
        XCTAssertEqual(FileNameSanitizer.sanitize("...", fallback: "Track 01"), "Track 01")
    }

    func testUnicodeTitlesSurvive() {
        XCTAssertEqual(FileNameSanitizer.sanitize("Café Olé — Süß"), "Café Olé — Süß")
    }

    func testLongNamesAreTruncated() {
        let long = String(repeating: "a", count: 300)
        XCTAssertEqual(FileNameSanitizer.sanitize(long).count, FileNameSanitizer.maxLength)
    }

    func testTrackFileNameFormat() {
        XCTAssertEqual(
            FileNameSanitizer.trackFileName(number: 3, title: "Moonlight Mile"),
            "03 - Moonlight Mile.mp3")
        XCTAssertEqual(
            FileNameSanitizer.trackFileName(number: 12, title: ""),
            "12 - Track 12.mp3")
    }
}

final class TrackNumberingTests: XCTestCase {

    private func makeProject(sideATracks: Int, sideBTracks: Int) -> AlbumProject {
        var project = AlbumProject()
        project.updateSide(.a) { side in
            side.hasRecording = sideATracks > 0
            side.durationSeconds = 600
            side.boundaries = (1..<max(sideATracks, 1)).map { Double($0) * 100 }
            side.reconcileTrackList()
        }
        project.updateSide(.b) { side in
            side.hasRecording = sideBTracks > 0
            side.durationSeconds = 600
            side.boundaries = (1..<max(sideBTracks, 1)).map { Double($0) * 100 }
            side.reconcileTrackList()
        }
        return project
    }

    func testNumberingContinuesFromSideAToSideB() {
        let project = makeProject(sideATracks: 5, sideBTracks: 4)
        let order = project.exportOrder

        XCTAssertEqual(order.count, 9)
        XCTAssertEqual(order.map(\.number), Array(1...9))
        // First Side B track must be number 6.
        let firstB = order.first { $0.side == .b }
        XCTAssertEqual(firstB?.number, 6)
        XCTAssertEqual(firstB?.indexOnSide, 0)
    }

    func testSideBOnlyProjectStartsAtOne() {
        let project = makeProject(sideATracks: 0, sideBTracks: 3)
        let order = project.exportOrder
        XCTAssertEqual(order.map(\.number), [1, 2, 3])
        XCTAssertTrue(order.allSatisfy { $0.side == .b })
    }

    func testEffectiveTitleFallback() {
        XCTAssertEqual(AlbumProject.effectiveTitle(TrackInfo(), number: 7), "Track 07")
        XCTAssertEqual(
            AlbumProject.effectiveTitle(TrackInfo(title: "  Gimme Shelter "), number: 1),
            "Gimme Shelter")
    }

    func testSegmentsRespectTrimsAndBoundaries() {
        var side = RecordSide(side: .a)
        side.hasRecording = true
        side.durationSeconds = 100
        side.trimStart = 2
        side.trimEnd = 95
        side.boundaries = [40, 70]
        let segments = side.segments

        XCTAssertEqual(segments.count, 3)
        XCTAssertEqual(segments[0].lowerBound, 2, accuracy: 0.001)
        XCTAssertEqual(segments[0].upperBound, 40, accuracy: 0.001)
        XCTAssertEqual(segments[2].upperBound, 95, accuracy: 0.001)
    }

    func testReconcileTrackListPreservesTitles() {
        var side = RecordSide(side: .a)
        side.hasRecording = true
        side.durationSeconds = 300
        side.boundaries = [100, 200]
        side.reconcileTrackList()
        side.tracks[0].title = "Keep Me"
        // Removing a boundary shrinks the list but keeps earlier titles.
        side.boundaries = [100]
        side.reconcileTrackList()

        XCTAssertEqual(side.tracks.count, 2)
        XCTAssertEqual(side.tracks[0].title, "Keep Me")
    }
}

final class ProjectStoreTests: XCTestCase {

    func testCreateSaveAndReopenRoundTrip() throws {
        let dir = TestAudioFactory.temporaryDirectory("project-roundtrip")
        let packageURL = dir.appendingPathComponent("Test Album.vinylproj")

        var project = try ProjectStore.create(at: packageURL)
        project.albumTitle = "Sticky Fingers"
        project.albumArtist = "The Rolling Stones"
        project.year = 1971
        project.genre = "Rock"
        project.discNumber = 1
        project.updateSide(.a) { side in
            side.hasRecording = true
            side.durationSeconds = 1301.5
            side.boundaries = [163.2, 425.9, 610.0]
            side.trimStart = 1.2
            side.trimEnd = 1290.4
            side.reconcileTrackList()
            side.tracks[0].title = "Brown Sugar"
            side.detectionSettings = DetectionPreset.aggressive.settings
        }
        try ProjectStore.save(project, to: packageURL)

        let reopened = try ProjectStore.open(at: packageURL)
        XCTAssertEqual(reopened, project)
        XCTAssertEqual(reopened.side(.a).tracks[0].title, "Brown Sugar")
        XCTAssertEqual(reopened.side(.a).boundaries, [163.2, 425.9, 610.0])
        XCTAssertEqual(reopened.side(.a).detectionSettings.preset, .aggressive)
    }

    func testOpenMissingProjectThrows() {
        let dir = TestAudioFactory.temporaryDirectory("project-missing")
        XCTAssertThrowsError(
            try ProjectStore.open(at: dir.appendingPathComponent("Nope.vinylproj")))
    }

    func testAudioStatusReportsMissingRecording() throws {
        let dir = TestAudioFactory.temporaryDirectory("project-health")
        let packageURL = dir.appendingPathComponent("Health.vinylproj")
        var project = try ProjectStore.create(at: packageURL)
        project.updateSide(.a) { $0.hasRecording = true } // no file on disk

        let status = ProjectStore.audioStatus(of: project, at: packageURL)
        XCTAssertEqual(status.missingSides, [.a])
        XCTAssertNil(status.interruptedSide)
    }

    func testRecoveryMarkerRoundTrip() throws {
        let dir = TestAudioFactory.temporaryDirectory("project-recovery")
        let packageURL = dir.appendingPathComponent("Crash.vinylproj")
        var project = try ProjectStore.create(at: packageURL)
        project.updateSide(.b) { $0.hasRecording = false }

        // Simulate a crash: marker written, partial audio exists.
        let recordingURL = ProjectStore.recordingURL(for: .b, in: packageURL)
        try TestAudioFactory.writeAudioFile(
            to: recordingURL, left: TestAudioFactory.song(duration: 2))
        ProjectStore.writeRecoveryMarker(side: .b, in: packageURL)

        let status = ProjectStore.audioStatus(of: project, at: packageURL)
        XCTAssertEqual(status.interruptedSide, .b)

        ProjectStore.clearRecoveryMarker(in: packageURL)
        let cleared = ProjectStore.audioStatus(of: project, at: packageURL)
        XCTAssertNil(cleared.interruptedSide)
    }
}
