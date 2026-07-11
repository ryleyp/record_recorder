import SwiftUI

/// Stage 3: record a full side losslessly.
struct RecordView: View {
    @EnvironmentObject private var appState: AppState
    @State private var sideToRecord: SideLabel = .a
    @State private var confirmCancel = false
    @State private var confirmRerecord = false

    private var recorder: RecordingEngine { appState.recorder }
    private var isRecording: Bool { recorder.state == .recording || recorder.state == .paused }

    var body: some View {
        StageContainer(
            title: "Record a Side",
            subtitle: "Cue the needle at the start of the side, click Record, then drop the needle. Let the whole side play — the app captures everything losslessly and you'll split it into tracks afterward."
        ) {
            if recorder.state == .idle {
                HelpCallout(
                    systemImage: "exclamationmark.triangle",
                    text: "Monitoring is not running. Go back to Connect and select an input device.",
                    tint: .orange)
            }

            sideStatusPanel

            if isRecording {
                recordingPanel
            } else {
                readyPanel
            }

            Spacer()
        }
        .confirmationDialog(
            "Discard this recording?",
            isPresented: $confirmCancel
        ) {
            Button("Discard Recording", role: .destructive) {
                appState.cancelRecording()
            }
            Button("Keep Recording", role: .cancel) {}
        } message: {
            Text("The audio recorded so far for \(appState.activeSide.title) will be deleted. This cannot be undone.")
        }
        .confirmationDialog(
            "Record \(sideToRecord.title) again?",
            isPresented: $confirmRerecord
        ) {
            Button("Replace Existing Recording", role: .destructive) {
                appState.startRecording(side: sideToRecord)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(sideToRecord.title) has already been recorded. Recording again will replace it, along with its track markers.")
        }
    }

    private var sideStatusPanel: some View {
        HStack(spacing: 16) {
            ForEach(SideLabel.allCases) { side in
                let record = appState.project?.side(side)
                HStack(spacing: 8) {
                    Image(systemName: record?.hasRecording == true
                          ? "checkmark.circle.fill" : "circle.dashed")
                        .foregroundStyle(record?.hasRecording == true ? .green : .secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(side.title).font(.headline)
                        Text(record?.hasRecording == true
                             ? "Recorded · \(TimeFormat.mmss(record?.durationSeconds ?? 0))"
                             : "Not recorded")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                .accessibilityElement(children: .combine)
            }
        }
    }

    private var readyPanel: some View {
        VStack(spacing: 20) {
            Picker("Side to record", selection: $sideToRecord) {
                ForEach(SideLabel.allCases) { side in
                    Text(side.title).tag(side)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 320)
            .labelsHidden()

            Button {
                if appState.project?.side(sideToRecord).hasRecording == true {
                    confirmRerecord = true
                } else {
                    appState.startRecording(side: sideToRecord)
                }
            } label: {
                VStack(spacing: 6) {
                    Image(systemName: "record.circle")
                        .font(.system(size: 44))
                    Text("Record \(sideToRecord.title)")
                        .font(.title3.bold())
                }
                .frame(width: 260, height: 110)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .disabled(recorder.state != .monitoring)
            .keyboardShortcut("r")
            .accessibilityLabel("Start recording \(sideToRecord.title)")
            .accessibilityHint("Begins a lossless recording of the whole side")
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 12)
    }

    private var recordingPanel: some View {
        VStack(spacing: 16) {
            HStack(spacing: 10) {
                Circle()
                    .fill(recorder.state == .paused ? Color.orange : Color.red)
                    .frame(width: 14, height: 14)
                    .opacity(recorder.state == .paused ? 1 : 0.9)
                Text(recorder.state == .paused
                     ? "Paused — \(appState.activeSide.title)"
                     : "Recording \(appState.activeSide.title)")
                    .font(.title2.bold())
            }
            Text(TimeFormat.mmss(recorder.elapsedSeconds))
                .font(.system(size: 56, weight: .medium, design: .monospaced))
                .accessibilityLabel("Elapsed time \(TimeFormat.mmss(recorder.elapsedSeconds))")

            HStack(spacing: 20) {
                LevelMeterBar(label: "L", reading: recorder.leftLevel)
                ClipIndicator(isClipping: recorder.clipDetected)
            }
            LevelMeterBar(
                label: "R",
                reading: recorder.activeChannelCount >= 2 ? recorder.rightLevel : recorder.leftLevel)

            Text("Free disk space: \(TimeFormat.bytes(recorder.freeDiskBytes)) · The Mac will not sleep while recording.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 14) {
                if recorder.state == .paused {
                    Button {
                        recorder.resumeRecording()
                    } label: {
                        Label("Resume", systemImage: "play.fill")
                            .frame(minWidth: 110)
                    }
                    .controlSize(.large)
                    .keyboardShortcut(.space, modifiers: [])
                } else {
                    Button {
                        recorder.pauseRecording()
                    } label: {
                        Label("Pause", systemImage: "pause.fill")
                            .frame(minWidth: 110)
                    }
                    .controlSize(.large)
                    .keyboardShortcut(.space, modifiers: [])
                }

                Button {
                    appState.stopRecording()
                    appState.stage = .detect
                } label: {
                    Label("Stop & Continue", systemImage: "stop.fill")
                        .frame(minWidth: 160)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return)

                Button(role: .destructive) {
                    confirmCancel = true
                } label: {
                    Label("Discard", systemImage: "trash")
                        .frame(minWidth: 110)
                }
                .controlSize(.large)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(20)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    }
}
