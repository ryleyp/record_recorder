import Foundation
import AVFoundation
import CoreAudio
import Accelerate

/// Per-channel level reading in dBFS.
struct LevelReading: Equatable {
    var peakDB: Float = -120
    var rmsDB: Float = -120
}

enum RecorderState: Equatable {
    case idle
    case monitoring
    case recording
    case paused
}

enum RecorderError: LocalizedError {
    case microphonePermissionDenied
    case noUsableInput
    case deviceSelectionFailed(OSStatus)
    case engineStartFailed(String)
    case fileCreationFailed(String)
    case deviceDisconnected

    var errorDescription: String? {
        switch self {
        case .microphonePermissionDenied:
            return "Audio input access was denied. macOS treats USB line-in adapters as microphones — open System Settings › Privacy & Security › Microphone and enable Vinyl Album Recorder."
        case .noUsableInput:
            return "No usable audio input was found. Connect your USB audio adapter, then click Refresh."
        case .deviceSelectionFailed(let status):
            return "The selected input device could not be activated (CoreAudio error \(status)). Try unplugging and reconnecting the adapter."
        case .engineStartFailed(let message):
            return "The audio engine could not start: \(message)"
        case .fileCreationFailed(let message):
            return "The recording file could not be created: \(message)"
        case .deviceDisconnected:
            return "The audio input device was disconnected. The recording made so far has been kept."
        }
    }
}

/// Captures audio from a selected input device with live metering, and writes
/// a lossless CAF file. CAF is used for the working copy because a partially
/// written CAF remains readable after a crash (its data chunk is sized "to
/// end of file"), which gives us free crash recovery.
@MainActor
final class RecordingEngine: ObservableObject {

    @Published private(set) var state: RecorderState = .idle
    @Published private(set) var leftLevel = LevelReading()
    @Published private(set) var rightLevel = LevelReading()
    /// Sticky for a short period after a clip so the user can see it happened.
    @Published private(set) var clipDetected = false
    /// Highest peak observed since the user last reset it (for the level-check test).
    @Published private(set) var sessionMaxPeakDB: Float = -120
    @Published private(set) var elapsedSeconds: Double = 0
    @Published private(set) var freeDiskBytes: Int64 = 0
    @Published private(set) var activeFormatDescription = ""
    @Published private(set) var activeChannelCount = 0
    @Published private(set) var activeSampleRate: Double = 0
    @Published var lastError: RecorderError?
    /// Loops captured input to the speakers when enabled (feedback risk — off by default).
    @Published var monitorThroughSpeakers = false {
        didSet { applyMonitorVolume() }
    }

    private let engine = AVAudioEngine()
    private var file: AVAudioFile?
    private var monitoredDeviceID: AudioDeviceID?
    private var framesWritten: AVAudioFramePosition = 0
    private var fileSampleRate: Double = 44_100
    private var uiTimer: Timer?
    private var sleepActivity: NSObjectProtocol?
    private var configChangeObserver: NSObjectProtocol?
    private var isWriting = false   // set on main; read on render thread via lock-free flag
    private let writeFlag = AtomicFlag()
    private let clipHold = 1.5      // seconds the clip lamp stays lit
    private var lastClipTime: Date = .distantPast

    /// Meter values are produced on the audio render thread and drained by a UI timer.
    private let meterBox = MeterBox()

    // MARK: Permission

    static func requestInputPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    // MARK: Monitoring

    /// Starts the engine on the given device and begins metering (no file writing yet).
    func startMonitoring(device: AudioInputDevice) async throws {
        guard await Self.requestInputPermission() else {
            throw RecorderError.microphonePermissionDenied
        }
        stopEverything()

        let input = engine.inputNode
        var deviceID = device.id
        guard let audioUnit = input.audioUnit else {
            throw RecorderError.engineStartFailed("Input node has no audio unit.")
        }
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size))
        guard status == noErr else {
            throw RecorderError.deviceSelectionFailed(status)
        }

        let format = input.inputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw RecorderError.noUsableInput
        }
        activeSampleRate = format.sampleRate
        activeChannelCount = Int(format.channelCount)
        activeFormatDescription = String(
            format: "%.1f kHz · %@", format.sampleRate / 1000,
            activeChannelCount >= 2 ? "Stereo" : "Mono")

        // Route input to the output mixer so optional speaker monitoring works;
        // volume 0 keeps it silent (the default) without rebuilding the graph.
        engine.connect(input, to: engine.mainMixerNode, format: format)
        applyMonitorVolume()

        let box = meterBox
        let flag = writeFlag
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            box.ingest(buffer: buffer)
            guard flag.isSet, let self else { return }
            // AVAudioFile.write(from:) is safe off the main thread; `file` is
            // only mutated while the tap is quiesced (writeFlag cleared first).
            if let file = self.file {
                do {
                    try file.write(from: buffer)
                } catch {
                    flag.clear()
                }
            }
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw RecorderError.engineStartFailed(error.localizedDescription)
        }

        monitoredDeviceID = device.id
        state = .monitoring
        startUITimer()
        installConfigChangeObserver()
    }

    /// Stops metering/recording and tears the engine down.
    func stopEverything() {
        if state == .recording || state == .paused {
            _ = stopRecording()
        }
        uiTimer?.invalidate()
        uiTimer = nil
        if configChangeObserver != nil {
            NotificationCenter.default.removeObserver(configChangeObserver!)
            configChangeObserver = nil
        }
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        engine.reset()
        monitoredDeviceID = nil
        state = .idle
        leftLevel = LevelReading()
        rightLevel = LevelReading()
    }

    func resetSessionPeak() {
        sessionMaxPeakDB = -120
        clipDetected = false
    }

    // MARK: Recording

    /// Begins writing the monitored input to `url` as 16-bit PCM CAF at the
    /// device's native sample rate (no resampling while recording).
    func startRecording(to url: URL) throws {
        guard state == .monitoring else { return }
        let channels = min(activeChannelCount, 2)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: activeSampleRate,
            AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            let format = engine.inputNode.inputFormat(forBus: 0)
            file = try AVAudioFile(
                forWriting: url,
                settings: settings,
                commonFormat: format.commonFormat,
                interleaved: format.isInterleaved)
        } catch {
            throw RecorderError.fileCreationFailed(error.localizedDescription)
        }
        fileSampleRate = activeSampleRate
        framesWritten = 0
        elapsedSeconds = 0
        beginSleepPrevention()
        updateDiskSpace()
        writeFlag.set()
        state = .recording
    }

    func pauseRecording() {
        guard state == .recording else { return }
        writeFlag.clear()
        state = .paused
    }

    func resumeRecording() {
        guard state == .paused else { return }
        writeFlag.set()
        state = .recording
    }

    /// Finalizes the file and returns to monitoring. Returns the recorded duration.
    @discardableResult
    func stopRecording() -> Double {
        writeFlag.clear()
        let duration = currentRecordedDuration()
        file = nil   // AVAudioFile finalizes on deallocation
        endSleepPrevention()
        if state == .recording || state == .paused {
            state = engine.isRunning ? .monitoring : .idle
        }
        return duration
    }

    /// Stops and deletes the in-progress file.
    func cancelRecording(deleting url: URL) {
        writeFlag.clear()
        file = nil
        endSleepPrevention()
        try? FileManager.default.removeItem(at: url)
        state = engine.isRunning ? .monitoring : .idle
        elapsedSeconds = 0
    }

    func currentRecordedDuration() -> Double {
        guard let file else { return elapsedSeconds }
        return Double(file.length) / fileSampleRate
    }

    var isEngineRunning: Bool { engine.isRunning }

    // MARK: Internals

    private func applyMonitorVolume() {
        engine.mainMixerNode.outputVolume = monitorThroughSpeakers ? 1 : 0
    }

    private func startUITimer() {
        uiTimer?.invalidate()
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.drainMeters()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        uiTimer = timer
    }

    private func drainMeters() {
        let snapshot = meterBox.snapshotAndReset()
        guard snapshot.frames > 0 else { return }
        leftLevel = LevelReading(peakDB: snapshot.peakDB[0], rmsDB: snapshot.rmsDB[0])
        let rightIndex = activeChannelCount >= 2 ? 1 : 0
        rightLevel = LevelReading(peakDB: snapshot.peakDB[rightIndex], rmsDB: snapshot.rmsDB[rightIndex])
        let maxPeak = max(leftLevel.peakDB, rightLevel.peakDB)
        sessionMaxPeakDB = max(sessionMaxPeakDB, maxPeak)
        if maxPeak >= -0.3 {
            lastClipTime = Date()
        }
        clipDetected = Date().timeIntervalSince(lastClipTime) < clipHold

        if state == .recording || state == .paused {
            if let file {
                elapsedSeconds = Double(file.length) / fileSampleRate
            }
            if Int(elapsedSeconds) % 5 == 0 { updateDiskSpace() }
            checkDeviceStillPresent()
        }
    }

    private func updateDiskSpace() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        if let values = try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let capacity = values.volumeAvailableCapacityForImportantUsage {
            freeDiskBytes = capacity
        }
    }

    private func checkDeviceStillPresent() {
        guard let deviceID = monitoredDeviceID else { return }
        if !AudioDeviceManager.deviceIsAlive(deviceID) {
            handleDeviceDisconnect()
        }
    }

    private func installConfigChangeObserver() {
        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let deviceID = self.monitoredDeviceID else { return }
                if !AudioDeviceManager.deviceIsAlive(deviceID) {
                    self.handleDeviceDisconnect()
                }
            }
        }
    }

    private func handleDeviceDisconnect() {
        let wasRecording = state == .recording || state == .paused
        if wasRecording {
            _ = stopRecording()
        }
        stopEverything()
        lastError = .deviceDisconnected
    }

    private func beginSleepPrevention() {
        guard sleepActivity == nil else { return }
        sleepActivity = ProcessInfo.processInfo.beginActivity(
            options: [.idleSystemSleepDisabled, .userInitiated],
            reason: "Recording a vinyl record side")
    }

    private func endSleepPrevention() {
        if let activity = sleepActivity {
            ProcessInfo.processInfo.endActivity(activity)
            sleepActivity = nil
        }
    }
}

/// Lock-free boolean the render thread can read without blocking.
final class AtomicFlag: @unchecked Sendable {
    private let value = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
    init() { value.initialize(to: 0) }
    deinit { value.deallocate() }
    var isSet: Bool { OSAtomicAdd32(0, value) != 0 }
    func set() { OSAtomicCompareAndSwap32(0, 1, value) }
    func clear() { OSAtomicCompareAndSwap32(1, 0, value) }
}

/// Accumulates peak/RMS per channel on the render thread; the main thread
/// snapshots and resets it on a timer. Guarded by a lightweight unfair lock.
final class MeterBox: @unchecked Sendable {
    struct Snapshot {
        var peakDB: [Float]
        var rmsDB: [Float]
        var frames: Int
    }

    private var lock = os_unfair_lock()
    private var peak: [Float] = [0, 0]
    private var sumSquares: [Double] = [0, 0]
    private var frames = 0

    func ingest(buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData else { return }
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return }
        let channels = min(Int(buffer.format.channelCount), 2)

        var localPeak: [Float] = [0, 0]
        var localSum: [Double] = [0, 0]
        for channel in 0..<channels {
            let samples = channelData[channel]
            var magnitude: Float = 0
            vDSP_maxmgv(samples, 1, &magnitude, vDSP_Length(frameCount))
            localPeak[channel] = magnitude
            var meanSquare: Float = 0
            vDSP_measqv(samples, 1, &meanSquare, vDSP_Length(frameCount))
            localSum[channel] = Double(meanSquare) * Double(frameCount)
        }

        os_unfair_lock_lock(&lock)
        for channel in 0..<channels {
            peak[channel] = max(peak[channel], localPeak[channel])
            sumSquares[channel] += localSum[channel]
        }
        frames += frameCount
        os_unfair_lock_unlock(&lock)
    }

    func snapshotAndReset() -> Snapshot {
        os_unfair_lock_lock(&lock)
        let capturedPeak = peak
        let capturedSum = sumSquares
        let capturedFrames = frames
        peak = [0, 0]
        sumSquares = [0, 0]
        frames = 0
        os_unfair_lock_unlock(&lock)

        func toDB(_ linear: Float) -> Float {
            linear <= 0 ? -120 : max(-120, 20 * log10(linear))
        }
        let rms: [Float] = capturedSum.map { sum in
            capturedFrames == 0 ? -120 : toDB(Float((sum / Double(capturedFrames)).squareRoot()))
        }
        return Snapshot(
            peakDB: capturedPeak.map(toDB),
            rmsDB: rms,
            frames: capturedFrames)
    }
}
