import SwiftUI
import UniformTypeIdentifiers

/// Stage 1: choose how audio gets into the project — record live from the
/// USB audio input, or import files the Crosley saved to a USB drive.
struct ConnectView: View {
    @EnvironmentObject private var appState: AppState
    @State private var choice: SourceChoice?
    @State private var showImportSheet = false
    @State private var droppedURLs: [URL] = []

    enum SourceChoice {
        case record
        case importFiles
    }

    var body: some View {
        StageContainer(
            title: "Add Your Music",
            subtitle: "Record straight from the turntable, or import recordings the Crosley already saved to a USB flash drive or SD card. Both paths lead to the same track detection, review, and MP3 export."
        ) {
            HStack(spacing: 16) {
                sourceCard(
                    selected: choice == .record,
                    systemImage: "waveform.badge.mic",
                    title: "Record from Audio Input",
                    text: "Play the record into the Mac through a USB audio adapter and capture it losslessly."
                ) {
                    choice = .record
                }
                .accessibilityHint("Shows the audio input device list")

                sourceCard(
                    selected: false,
                    systemImage: "externaldrive.badge.plus",
                    title: "Import from USB or Folder",
                    text: "Bring in MP3, WAV, AIFF, M4A, FLAC, or CAF files — from a USB drive, SD card, or any folder. Audacity exports and label files welcome."
                ) {
                    choice = .importFiles
                    droppedURLs = []
                    showImportSheet = true
                }
                .accessibilityHint("Opens the file import window")
                .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                    handleDrop(providers)
                }
            }
            .frame(maxHeight: 150)

            if choice == .record {
                recordingSetup
            } else {
                HelpCallout(
                    systemImage: "hand.point.up.left",
                    text: "Tip: you can also drag audio files (or an Audacity label .txt) onto the Import card.")
            }
        }
        .sheet(isPresented: $showImportSheet) {
            ImportSheet(initialURLs: droppedURLs)
                .environmentObject(appState)
        }
    }

    private func sourceCard(
        selected: Bool, systemImage: String, title: String, text: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: 28))
                    .foregroundStyle(Color.accentColor)
                Text(title).font(.headline)
                Text(text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(
                selected ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.04),
                in: RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(
                        selected ? Color.accentColor : Color.primary.opacity(0.1),
                        lineWidth: selected ? 2 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var found = false
        let group = DispatchGroup()
        var urls: [URL] = []
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            found = true
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url { urls.append(url) }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            guard !urls.isEmpty else { return }
            droppedURLs = urls
            showImportSheet = true
        }
        return found
    }

    // MARK: Live-recording device setup (the original Connect content)

    private var selected: AudioInputDevice? { appState.selectedDevice }

    private var recordingSetup: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Audio Inputs").font(.headline)
                Spacer()
                Button {
                    appState.deviceManager.refresh()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .accessibilityLabel("Refresh device list")
            }

            if appState.deviceManager.inputDevices.isEmpty {
                HelpCallout(
                    systemImage: "exclamationmark.triangle",
                    text: "No audio input devices were found. Connect your USB audio adapter and click Refresh. Note: the MacBook headphone jack does not accept audio input — a USB adapter is required.",
                    tint: .orange)
            } else {
                deviceList
            }

            if let device = selected, !device.isStereo {
                HelpCallout(
                    systemImage: "speaker.wave.1",
                    text: "\(device.name) only provides mono input. The recording will be mono. For stereo, use an adapter with a stereo line input.",
                    tint: .orange)
            }

            HelpCallout(
                systemImage: "info.circle",
                text: "macOS treats USB line-in adapters as microphones, so the first time you continue, macOS will ask for microphone permission. That request is this app asking to hear your record player.")

            HStack {
                Spacer()
                Button {
                    appState.startMonitoringSelectedDevice()
                    appState.stage = .levels
                } label: {
                    Label("Continue to Set Levels", systemImage: "arrow.right")
                        .frame(minWidth: 200)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .disabled(selected == nil)
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var deviceList: some View {
        VStack(spacing: 1) {
            ForEach(appState.deviceManager.inputDevices) { device in
                Button {
                    appState.selectedDeviceUID = device.uid
                } label: {
                    HStack {
                        Image(systemName: device.isStereo ? "cable.connector" : "speaker.wave.1")
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(device.name).font(.body.weight(.medium))
                            Text("\(device.channelDescription) · \(String(format: "%.1f kHz", device.nominalSampleRate / 1000))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if device.uid == appState.selectedDeviceUID {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(Color.accentColor)
                        }
                        if device.id == appState.deviceManager.defaultInputDeviceID {
                            Text("System Default")
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.quaternary, in: Capsule())
                        }
                    }
                    .contentShape(Rectangle())
                    .padding(10)
                }
                .buttonStyle(.plain)
                .background(
                    device.uid == appState.selectedDeviceUID
                        ? Color.accentColor.opacity(0.12) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 6))
                .accessibilityLabel("\(device.name), \(device.channelDescription)")
                .accessibilityAddTraits(device.uid == appState.selectedDeviceUID ? .isSelected : [])
            }
        }
        .padding(4)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }
}
