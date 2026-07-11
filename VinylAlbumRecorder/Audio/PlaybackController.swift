import Foundation
import AVFoundation

/// Simple seekable playback of the recorded side (CAF PCM), used by the
/// track review editor. AVAudioPlayer handles CAF natively and supports
/// sample-accurate-enough scrubbing for marker placement.
@MainActor
final class PlaybackController: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var isPlaying = false
    @Published var currentTime: Double = 0
    @Published private(set) var duration: Double = 0

    private var player: AVAudioPlayer?
    private var timer: Timer?
    private var stopAtTime: Double?

    func load(url: URL) throws {
        stop()
        let player = try AVAudioPlayer(contentsOf: url)
        player.delegate = self
        player.prepareToPlay()
        self.player = player
        duration = player.duration
        currentTime = 0
    }

    func unload() {
        stop()
        player = nil
        duration = 0
        currentTime = 0
    }

    func play(from time: Double? = nil, until end: Double? = nil) {
        guard let player else { return }
        if let time {
            player.currentTime = max(0, min(time, duration))
        }
        stopAtTime = end
        player.play()
        isPlaying = true
        startTimer()
    }

    func pause() {
        player?.pause()
        isPlaying = false
        stopTimer()
        syncTime()
    }

    func stop() {
        player?.stop()
        isPlaying = false
        stopAtTime = nil
        stopTimer()
    }

    func togglePlayPause(fromTime time: Double? = nil) {
        if isPlaying {
            pause()
        } else {
            play(from: time)
        }
    }

    func seek(to time: Double) {
        guard let player else { return }
        let clamped = max(0, min(time, duration))
        player.currentTime = clamped
        currentTime = clamped
    }

    /// Plays a few seconds around a marker so the user can audition a cut point.
    func previewAround(time: Double, before: Double = 3, after: Double = 3) {
        play(from: max(0, time - before), until: min(duration, time + after))
    }

    private func startTimer() {
        stopTimer()
        let timer = Timer(timeInterval: 0.03, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.syncTime()
                if let stopAt = self.stopAtTime, self.currentTime >= stopAt {
                    self.pause()
                    self.stopAtTime = nil
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func syncTime() {
        if let player {
            currentTime = player.currentTime
        }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.isPlaying = false
            self.stopTimer()
        }
    }
}
