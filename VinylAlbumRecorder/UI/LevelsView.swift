import SwiftUI

/// Stage 2: watch meters while adjusting the record player's volume.
struct LevelsView: View {
    @EnvironmentObject private var appState: AppState
    @State private var showMonitorWarning = false

    var body: some View {
        StageContainer(
            title: "Set Your Recording Level",
            subtitle: "Play the loudest part of the record (usually the first track) and adjust the record player's volume so peaks land between the two green lines — about -12 to -6 dBFS. If the CLIP lamp lights, turn the volume down."
        ) {
            if appState.recorder.state == .idle {
                HelpCallout(
                    systemImage: "exclamationmark.triangle",
                    text: "Monitoring is not running. Go back to Connect and select an input device.",
                    tint: .orange)
                Button("Start Monitoring") {
                    appState.startMonitoringSelectedDevice()
                }
            } else {
                meterPanel
            }

            HelpCallout(
                systemImage: "lightbulb",
                text: "Aim for peaks around -12 to -6 dBFS on loud passages. A little low is safe — vinyl has plenty of headroom — but clipping at 0 dBFS permanently distorts the recording.")

            Toggle(isOn: monitorBinding) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Play input through the speakers")
                    Text("Off by default to prevent feedback. Use headphones if you enable this.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
            .confirmationDialog(
                "Play input through the speakers?",
                isPresented: $showMonitorWarning
            ) {
                Button("Enable Monitoring") {
                    appState.recorder.monitorThroughSpeakers = true
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("If the record player can pick up sound from the speakers, this can cause loud feedback. Headphones are strongly recommended.")
            }

            HStack {
                Spacer()
                Button {
                    appState.stage = .record
                } label: {
                    Label("Continue to Record", systemImage: "arrow.right")
                        .frame(minWidth: 200)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .disabled(appState.recorder.state == .idle)
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var monitorBinding: Binding<Bool> {
        Binding(
            get: { appState.recorder.monitorThroughSpeakers },
            set: { enable in
                if enable {
                    showMonitorWarning = true
                } else {
                    appState.recorder.monitorThroughSpeakers = false
                }
            })
    }

    private var meterPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(appState.selectedDevice?.name ?? "Input")
                    .font(.headline)
                Text(appState.recorder.activeFormatDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                ClipIndicator(isClipping: appState.recorder.clipDetected)
            }
            LevelMeterBar(label: "L", reading: appState.recorder.leftLevel)
            LevelMeterBar(
                label: "R",
                reading: appState.recorder.activeChannelCount >= 2
                    ? appState.recorder.rightLevel
                    : appState.recorder.leftLevel)
            if appState.recorder.activeChannelCount < 2 {
                Text("Mono input — the same signal is shown on both meters.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Divider()
            HStack {
                Text("Loudest peak so far:")
                    .font(.callout)
                Text(appState.recorder.sessionMaxPeakDB <= -119
                     ? "—"
                     : String(format: "%.1f dBFS", appState.recorder.sessionMaxPeakDB))
                    .font(.callout.monospaced().bold())
                    .foregroundStyle(peakAssessmentColor)
                Text(peakAssessment)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Reset Peak") {
                    appState.recorder.resetSessionPeak()
                }
                .accessibilityLabel("Reset loudest peak measurement")
            }
        }
        .padding(16)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }

    private var peakAssessment: String {
        let peak = appState.recorder.sessionMaxPeakDB
        if peak <= -119 { return "Play the record to measure." }
        if peak >= -1 { return "Too hot — clipping. Turn the volume down." }
        if peak > -6 { return "A little hot. Nudge the volume down." }
        if peak >= -12 { return "Perfect." }
        if peak >= -24 { return "Safe, but a bit quiet. Turn it up if you can." }
        return "Very quiet — check connections and turn the volume up."
    }

    private var peakAssessmentColor: Color {
        let peak = appState.recorder.sessionMaxPeakDB
        if peak >= -1 { return .red }
        if peak > -6 { return .orange }
        if peak >= -12 { return .green }
        return .primary
    }
}
