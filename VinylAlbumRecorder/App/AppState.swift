import SwiftUI
import Combine
import AVFoundation

enum WorkflowStage: Int, CaseIterable, Identifiable, Codable {
    case connect
    case levels
    case record
    case detect
    case review
    case metadata
    case export

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .connect: return "Connect"
        case .levels: return "Set Levels"
        case .record: return "Record"
        case .detect: return "Detect Tracks"
        case .review: return "Review Tracks"
        case .metadata: return "Album Details"
        case .export: return "Export"
        }
    }

    var systemImage: String {
        switch self {
        case .connect: return "cable.connector"
        case .levels: return "waveform.badge.mic"
        case .record: return "record.circle"
        case .detect: return "scissors"
        case .review: return "waveform.path.ecg"
        case .metadata: return "square.and.pencil"
        case .export: return "square.and.arrow.up"
        }
    }
}

/// Top-level application state: the open project, current workflow stage,
/// and glue between the audio engine, detection, and export layers.
@MainActor
final class AppState: ObservableObject {

    // MARK: Project

    @Published var project: AlbumProject? {
        didSet { scheduleAutosave() }
    }
    @Published private(set) var packageURL: URL?
    @Published var stage: WorkflowStage = .connect
    @Published var missingAudioSides: [SideLabel] = []
    @Published var recoveredSide: SideLabel?

    // MARK: Audio

    let deviceManager = AudioDeviceManager()
    let recorder = RecordingEngine()
    let playback = PlaybackController()

    @Published var selectedDeviceUID: String? {
        didSet { UserDefaults.standard.set(selectedDeviceUID, forKey: "selectedDeviceUID") }
    }
    @Published var activeSide: SideLabel = .a

    // MARK: Analysis

    @Published var analyses: [SideLabel: SideAnalysis] = [:]
    @Published var analysisProgress: Double?
    @Published var analysisError: String?

    // MARK: Export

    @Published var exportProgress: Double?
    @Published var exportStatus: String = ""
    @Published var exportResult: ExportResult?
    @Published var exportError: String?
    @Published var pendingOverwriteFolder: URL?
    private var exportTask: Task<Void, Never>?

    // MARK: Misc UI

    @Published var errorMessage: String?

    private var autosaveWork: DispatchWorkItem?

    init() {
        selectedDeviceUID = UserDefaults.standard.string(forKey: "selectedDeviceUID")
    }

    var selectedDevice: AudioInputDevice? {
        guard let uid = selectedDeviceUID else { return nil }
        return deviceManager.device(withUID: uid)
    }

    // MARK: - Project lifecycle

    func requestNewProject() {
        let panel = NSSavePanel()
        panel.title = "New Album Project"
        panel.nameFieldLabel = "Album name:"
        panel.nameFieldStringValue = "My Album"
        panel.allowedContentTypes = []
        panel.allowsOtherFileTypes = true
        panel.directoryURL = defaultProjectsDirectory()
        panel.prompt = "Create"
        guard panel.runModal() == .OK, var url = panel.url else { return }
        if url.pathExtension != AlbumProject.packageExtension {
            url.appendPathExtension(AlbumProject.packageExtension)
        }
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            let project = try ProjectStore.create(at: url)
            adopt(project: project, at: url)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func requestOpenProject() {
        let panel = NSOpenPanel()
        panel.title = "Open Album Project"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = defaultProjectsDirectory()
        panel.message = "Choose a .\(AlbumProject.packageExtension) project"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        openProject(at: url)
    }

    func openProject(at url: URL) {
        do {
            let project = try ProjectStore.open(at: url)
            adopt(project: project, at: url)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func adopt(project: AlbumProject, at url: URL) {
        recorder.stopEverything()
        playback.unload()
        analyses = [:]
        exportResult = nil
        exportError = nil
        self.packageURL = url
        self.project = project

        let status = ProjectStore.audioStatus(of: project, at: url)
        missingAudioSides = status.missingSides
        recoveredSide = status.interruptedSide
        if let recovered = status.interruptedSide {
            // Keep the partial audio: mark the side as recorded so the user
            // can analyze and export what survived.
            updateSide(recovered) { side in
                side.hasRecording = true
            }
            refreshSideInfoFromDisk(recovered)
            ProjectStore.clearRecoveryMarker(in: url)
        }

        // Land the user on a sensible stage for the project's progress.
        if project.sides.contains(where: { $0.hasRecording }) {
            stage = .detect
        } else {
            stage = .connect
        }
        saveProjectNow()
    }

    func saveProjectNow() {
        guard let project, let packageURL else { return }
        do {
            try ProjectStore.save(project, to: packageURL)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func scheduleAutosave() {
        autosaveWork?.cancel()
        guard project != nil, packageURL != nil else { return }
        let work = DispatchWorkItem { [weak self] in
            self?.saveProjectNow()
        }
        autosaveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    private func defaultProjectsDirectory() -> URL {
        let music = FileManager.default.urls(for: .musicDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        let dir = music.appendingPathComponent("Vinyl Album Recorder", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func updateSide(_ label: SideLabel, _ mutate: (inout RecordSide) -> Void) {
        guard var project else { return }
        project.updateSide(label, mutate)
        self.project = project
    }

    // MARK: - Monitoring & recording

    func startMonitoringSelectedDevice() {
        guard let device = selectedDevice else { return }
        Task {
            do {
                try await recorder.startMonitoring(device: device)
            } catch let error as RecorderError {
                recorder.lastError = error
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func startRecording(side: SideLabel) {
        guard let packageURL else { return }
        let url = ProjectStore.recordingURL(for: side, in: packageURL)
        do {
            try recorder.startRecording(to: url)
            activeSide = side
            ProjectStore.writeRecoveryMarker(side: side, in: packageURL)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func stopRecording() {
        guard let packageURL else { return }
        let side = activeSide
        recorder.stopRecording()
        ProjectStore.clearRecoveryMarker(in: packageURL)
        updateSide(side) { record in
            record.hasRecording = true
            record.boundaries = []
            record.trimStart = 0
            record.trimEnd = 0
            record.tracks = []
        }
        refreshSideInfoFromDisk(side)
        analyses[side] = nil
        saveProjectNow()
    }

    func cancelRecording() {
        guard let packageURL else { return }
        let url = ProjectStore.recordingURL(for: activeSide, in: packageURL)
        recorder.cancelRecording(deleting: url)
        ProjectStore.clearRecoveryMarker(in: packageURL)
    }

    private func refreshSideInfoFromDisk(_ side: SideLabel) {
        guard let packageURL else { return }
        let url = ProjectStore.recordingURL(for: side, in: packageURL)
        guard let file = try? AVAudioFile(forReading: url) else { return }
        let duration = Double(file.length) / file.processingFormat.sampleRate
        updateSide(side) { record in
            record.sampleRate = file.processingFormat.sampleRate
            record.channelCount = Int(file.processingFormat.channelCount)
            record.durationSeconds = duration
        }
    }

    // MARK: - Analysis & detection

    func recordingURL(for side: SideLabel) -> URL? {
        guard let packageURL else { return nil }
        return ProjectStore.recordingURL(for: side, in: packageURL)
    }

    /// Analyzes the side's audio (waveform + envelope) if not already cached.
    func ensureAnalysis(for side: SideLabel) {
        guard analyses[side] == nil,
              analysisProgress == nil,
              let url = recordingURL(for: side),
              project?.side(side).hasRecording == true else { return }
        analysisProgress = 0
        analysisError = nil
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let analysis = try SideAnalyzer.analyze(url: url) { fraction in
                    Task { @MainActor [weak self] in
                        self?.analysisProgress = fraction
                    }
                }
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.analyses[side] = analysis
                    self.analysisProgress = nil
                    // Keep stored duration in sync with what's actually readable.
                    self.updateSide(side) { record in
                        record.durationSeconds = analysis.duration
                        record.sampleRate = analysis.sampleRate
                        record.channelCount = analysis.channelCount
                    }
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.analysisProgress = nil
                    self?.analysisError = error.localizedDescription
                }
            }
        }
    }

    /// Runs the detector on the cached analysis and installs the results.
    func runDetection(for side: SideLabel) {
        guard let analysis = analyses[side], var project else { return }
        let settings = project.side(side).detectionSettings
        let result = TrackDetector.detect(envelope: analysis.envelope, settings: settings)
        project.updateSide(side) { record in
            record.boundaries = result.boundaries
            record.trimStart = result.suggestedTrimStart
            record.trimEnd = result.suggestedTrimEnd
            record.reconcileTrackList()
        }
        self.project = project
    }

    // MARK: - Export

    func beginExport(outputRoot: URL, allowOverwrite: Bool = false) {
        guard let project, let packageURL else { return }
        exportProgress = 0
        exportStatus = "Preparing…"
        exportError = nil
        exportResult = nil
        pendingOverwriteFolder = nil

        var savedProject = project
        savedProject.lastOutputFolderPath = outputRoot.path
        self.project = savedProject

        exportTask = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let result = try TrackExporter.export(
                    project: savedProject,
                    packageURL: packageURL,
                    outputRoot: outputRoot,
                    allowOverwrite: allowOverwrite
                ) { fraction, message in
                    Task { @MainActor [weak self] in
                        self?.exportProgress = fraction
                        self?.exportStatus = message
                    }
                }
                await MainActor.run { [weak self] in
                    self?.exportProgress = nil
                    self?.exportResult = result
                }
            } catch ExportError.albumFolderExists(let folder) {
                await MainActor.run { [weak self] in
                    self?.exportProgress = nil
                    self?.pendingOverwriteFolder = folder
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.exportProgress = nil
                    self?.exportError = error.localizedDescription
                }
            }
        }
    }

    func cancelExport() {
        exportTask?.cancel()
        exportTask = nil
        exportProgress = nil
        exportStatus = ""
    }
}
