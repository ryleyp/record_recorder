import SwiftUI

/// Stage 1: pick the USB audio input device.
struct ConnectView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        StageContainer(
            title: "Connect Your Record Player",
            subtitle: "Plug the record player's AUX or headphone output into your USB audio adapter, then plug the adapter into the Mac and select it below."
        ) {
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

    private var selected: AudioInputDevice? { appState.selectedDevice }

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
