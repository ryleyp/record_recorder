import SwiftUI

/// Stage 4: analyze the recorded side and propose track boundaries.
struct DetectView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        StageContainer(
            title: "Detect Tracks",
            subtitle: "The app scans the recording for quiet gaps between songs and proposes track boundaries. You can re-run detection with different settings at any time — the original recording is never modified."
        ) {
            sidePicker

            if currentSide?.hasRecording != true {
                HelpCallout(
                    systemImage: "exclamationmark.triangle",
                    text: "\(appState.activeSide.title) has not been recorded yet. Go to the Record step first.",
                    tint: .orange)
            } else if let progress = appState.analysisProgress {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Analyzing the recording…").font(.headline)
                    ProgressView(value: progress)
                        .accessibilityLabel("Analysis progress")
                }
                .padding(16)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
            } else if let error = appState.analysisError {
                HelpCallout(systemImage: "xmark.octagon", text: error, tint: .red)
            } else if appState.analyses[appState.activeSide] != nil {
                settingsPanel
                resultsPanel
            }

            Spacer()

            HStack {
                Spacer()
                Button {
                    appState.stage = .review
                } label: {
                    Label("Review Tracks", systemImage: "arrow.right")
                        .frame(minWidth: 200)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .disabled(currentSide?.hasRecording != true)
                .keyboardShortcut(.defaultAction)
            }
        }
        .onAppear { appState.ensureAnalysis(for: appState.activeSide) }
        .onChange(of: appState.activeSide) {
            appState.ensureAnalysis(for: appState.activeSide)
        }
    }

    private var currentSide: RecordSide? {
        appState.project?.side(appState.activeSide)
    }

    private var sidePicker: some View {
        Picker("Side", selection: $appState.activeSide) {
            ForEach(SideLabel.allCases) { side in
                Text(side.title).tag(side)
            }
        }
        .pickerStyle(.segmented)
        .frame(maxWidth: 320)
    }

    private var settingsPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Detection Settings").font(.headline)

            Picker("Preset", selection: presetBinding) {
                ForEach(DetectionPreset.allCases) { preset in
                    Text(preset.title).tag(preset)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 420)

            Text(presetBinding.wrappedValue.explanation)
                .font(.caption)
                .foregroundStyle(.secondary)

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
                GridRow {
                    Text("Silence threshold")
                    Slider(value: settingBinding(\.silenceThresholdDB), in: -60...(-20), step: 1)
                        .frame(maxWidth: 280)
                        .accessibilityLabel("Silence threshold in decibels")
                    Text("\(Int(settings.silenceThresholdDB)) dBFS")
                        .font(.callout.monospaced())
                        .frame(width: 80, alignment: .trailing)
                }
                GridRow {
                    Text("Minimum gap")
                    Slider(value: settingBinding(\.minimumGapSeconds), in: 0.5...5, step: 0.1)
                        .frame(maxWidth: 280)
                        .accessibilityLabel("Minimum gap duration in seconds")
                    Text(String(format: "%.1f s", settings.minimumGapSeconds))
                        .font(.callout.monospaced())
                        .frame(width: 80, alignment: .trailing)
                }
                GridRow {
                    Text("Minimum track length")
                    Slider(value: settingBinding(\.minimumTrackSeconds), in: 10...120, step: 5)
                        .frame(maxWidth: 280)
                        .accessibilityLabel("Minimum track length in seconds")
                    Text("\(Int(settings.minimumTrackSeconds)) s")
                        .font(.callout.monospaced())
                        .frame(width: 80, alignment: .trailing)
                }
            }

            Button {
                appState.runDetection(for: appState.activeSide)
            } label: {
                Label("Detect Track Boundaries", systemImage: "scissors")
                    .frame(minWidth: 220)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
        }
        .padding(16)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private var resultsPanel: some View {
        if let side = currentSide, side.hasRecording {
            let segments = side.segments
            if side.boundaries.isEmpty && segments.count <= 1 {
                HelpCallout(
                    systemImage: "scissors",
                    text: "No track breaks found yet. Click “Detect Track Boundaries”, or switch to the Aggressive preset if the gaps on this record are short or noisy.")
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(segments.count) tracks proposed for \(side.side.title)")
                        .font(.headline)
                    ForEach(Array(segments.enumerated()), id: \.offset) { index, range in
                        HStack {
                            Text(String(format: "Track %02d", index + 1))
                                .font(.callout.monospaced())
                            Text("\(TimeFormat.mmss(range.lowerBound)) – \(TimeFormat.mmss(range.upperBound))")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                            Text("(\(TimeFormat.mmss(range.upperBound - range.lowerBound)))")
                                .font(.callout)
                            if range.upperBound - range.lowerBound < 30 {
                                Label("Short", systemImage: "exclamationmark.triangle.fill")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                                    .labelStyle(.titleAndIcon)
                            }
                        }
                    }
                }
                .padding(16)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    private var settings: DetectionSettings {
        currentSide?.detectionSettings ?? .default
    }

    private var presetBinding: Binding<DetectionPreset> {
        Binding(
            get: { settings.preset },
            set: { preset in
                appState.updateSide(appState.activeSide) { side in
                    side.detectionSettings = preset.settings
                }
            })
    }

    private func settingBinding(_ keyPath: WritableKeyPath<DetectionSettings, Double>) -> Binding<Double> {
        Binding(
            get: { settings[keyPath: keyPath] },
            set: { value in
                appState.updateSide(appState.activeSide) { side in
                    side.detectionSettings[keyPath: keyPath] = value
                }
            })
    }
}
