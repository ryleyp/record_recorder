import SwiftUI
import AppKit

/// Stage 7: MP3 export, output folder layout, and iPod sync guidance.
struct ExportView: View {
    @EnvironmentObject private var appState: AppState
    @State private var outputRoot: URL = FileManager.default
        .urls(for: .musicDirectory, in: .userDomainMask).first
        ?? FileManager.default.homeDirectoryForCurrentUser
    @State private var showIPodHelp = false

    var body: some View {
        StageContainer(
            title: "Export Your Album",
            subtitle: "Each track is exported as a high-quality MP3 with full album metadata, organized into an Artist/Album folder that Apple Music and Finder can sync to an iPod."
        ) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    settingsPanel
                    destinationPanel

                    if appState.project?.totalTrackCount == 0 {
                        HelpCallout(
                            systemImage: "exclamationmark.triangle",
                            text: "There are no tracks to export yet. Record a side and run track detection first.",
                            tint: .orange)
                    }

                    if let progress = appState.exportProgress {
                        progressPanel(progress)
                    }
                    if let error = appState.exportError {
                        HelpCallout(systemImage: "xmark.octagon", text: error, tint: .red)
                    }
                    if let result = appState.exportResult {
                        resultPanel(result)
                    }
                }
                .padding(.bottom, 12)
            }

            HStack {
                Button {
                    showIPodHelp = true
                } label: {
                    Label("How do I get this onto my iPod?", systemImage: "questionmark.circle")
                }
                Spacer()
                if appState.exportProgress != nil {
                    Button(role: .cancel) {
                        appState.cancelExport()
                    } label: {
                        Label("Cancel Export", systemImage: "xmark")
                    }
                    .controlSize(.large)
                } else {
                    Button {
                        appState.beginExport(outputRoot: outputRoot)
                    } label: {
                        Label("Export Album", systemImage: "square.and.arrow.up")
                            .frame(minWidth: 200)
                    }
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
                    .disabled(appState.project?.totalTrackCount == 0)
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .sheet(isPresented: $showIPodHelp) {
            IPodHelpView()
        }
        .confirmationDialog(
            "Replace the existing album folder?",
            isPresented: Binding(
                get: { appState.pendingOverwriteFolder != nil },
                set: { if !$0 { appState.pendingOverwriteFolder = nil } })
        ) {
            Button("Replace", role: .destructive) {
                appState.beginExport(outputRoot: outputRoot, allowOverwrite: true)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("A folder for this album already exists at \(appState.pendingOverwriteFolder?.path ?? "") and is not empty. Replacing it deletes its current contents.")
        }
        .onAppear {
            if let saved = appState.project?.lastOutputFolderPath {
                var isDirectory: ObjCBool = false
                if FileManager.default.fileExists(atPath: saved, isDirectory: &isDirectory),
                   isDirectory.boolValue {
                    outputRoot = URL(fileURLWithPath: saved)
                }
            }
        }
    }

    // MARK: Panels

    private var settingsPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("MP3 Settings").font(.headline)
            Picker("Quality", selection: exportBinding(\.bitrate)) {
                ForEach(ExportSettings.Bitrate.allCases) { rate in
                    Text(rate.title).tag(rate)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 340)
            Text("320 kbps constant bitrate is the highest MP3 quality and works on every iPod.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if hasImportedMP3Tracks {
                Toggle(isOn: exportBinding(\.keepOriginalEncoding)) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Keep original encoding for imported MP3 tracks")
                        Text("Copies the imported MP3s' audio unchanged and only rewrites the tags — no quality loss. Turn off to re-encode everything at the chosen bitrate.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
            }
            if let warning = reencodeWarning {
                HelpCallout(systemImage: "exclamationmark.triangle", text: warning, tint: .orange)
            }

            Toggle(isOn: exportBinding(\.normalizePeaks)) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Gentle peak normalization")
                    Text("Raises quiet recordings so the loudest moment reaches -1 dBFS. Off by default to preserve the record exactly as captured.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)

            Toggle(isOn: exportBinding(\.copyOriginalRecordings)) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Include original lossless recordings")
                    Text("Copies the full-side WAV files into an “Original Recordings” folder inside the album.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)

            Toggle(isOn: exportBinding(\.createM3UPlaylist)) {
                Text("Create an M3U playlist")
            }
            .toggleStyle(.switch)
        }
        .padding(16)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }

    private var destinationPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Destination").font(.headline)
            HStack {
                Image(systemName: "folder")
                Text(previewPath)
                    .font(.callout.monospaced())
                    .lineLimit(2)
                    .truncationMode(.middle)
                Spacer()
                Button("Choose Folder…") { chooseFolder() }
            }
        }
        .padding(16)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }

    private func progressPanel(_ progress: Double) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(appState.exportStatus).font(.headline)
            ProgressView(value: progress)
                .accessibilityLabel("Export progress")
        }
        .padding(16)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }

    private func resultPanel(_ result: ExportResult) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Export complete — \(result.trackURLs.count) tracks", systemImage: "checkmark.circle.fill")
                .font(.headline)
                .foregroundStyle(.green)
            Text(result.albumFolder.path)
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([result.albumFolder])
                } label: {
                    Label("Reveal Album in Finder", systemImage: "magnifyingglass")
                }
                Button {
                    openInAppleMusic(result)
                } label: {
                    Label("Open in Apple Music", systemImage: "music.note")
                }
            }
        }
        .padding(16)
        .background(.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: Helpers

    /// Any imported side made of individual MP3 files (passthrough-eligible).
    private var hasImportedMP3Tracks: Bool {
        appState.project?.sides.contains { side in
            side.hasRecording && side.sourceType == .importedFolder
                && side.trackFiles.contains { $0.info?.isMP3 == true }
        } ?? false
    }

    /// Explains when MP3 → MP3 re-encoding (generation loss) will happen.
    private var reencodeWarning: String? {
        guard let project = appState.project else { return nil }
        let settings = project.exportSettings
        var reasons: [String] = []
        for side in project.sides where side.hasRecording {
            switch side.sourceType {
            case .importedFile where side.sourceInfo?.isMP3 == true:
                reasons.append("\(side.side.title) is a full-side MP3 — cutting it into tracks requires re-encoding, which loses a little quality. For best results import a WAV/FLAC of the side if you have one.")
            case .importedFolder:
                let hasMP3 = side.trackFiles.contains { $0.info?.isMP3 == true }
                if hasMP3 && (!settings.keepOriginalEncoding || settings.normalizePeaks) {
                    reasons.append("\(side.side.title)'s imported MP3s will be re-encoded (\(settings.normalizePeaks ? "normalization is on" : "Keep original encoding is off")), which loses a little quality.")
                }
            default:
                break
            }
        }
        return reasons.isEmpty ? nil : reasons.joined(separator: "\n")
    }

    private var previewPath: String {
        guard let project = appState.project else { return outputRoot.path }
        return TrackExporter.albumFolder(project: project, outputRoot: outputRoot).path
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = outputRoot
        panel.prompt = "Choose"
        panel.message = "The album folder (Artist Name/Album Name) is created inside the folder you choose."
        if panel.runModal() == .OK, let url = panel.url {
            outputRoot = url
        }
    }

    private func openInAppleMusic(_ result: ExportResult) {
        guard let musicApp = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "com.apple.Music") else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open(
            result.trackURLs, withApplicationAt: musicApp, configuration: configuration)
    }

    private func exportBinding<T>(_ keyPath: WritableKeyPath<ExportSettings, T>) -> Binding<T> {
        Binding(
            get: { appState.project?.exportSettings[keyPath: keyPath] ?? ExportSettings()[keyPath: keyPath] },
            set: { appState.project?.exportSettings[keyPath: keyPath] = $0 })
    }
}

/// Plain-language instructions for syncing the exported album to an iPod.
struct IPodHelpView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Getting Your Album onto an iPod")
                .font(.title2.bold())

            VStack(alignment: .leading, spacing: 12) {
                instructionStep(
                    number: 1,
                    text: "Open the exported album in Apple Music (use the “Open in Apple Music” button, or drag the album folder onto the Music app). The album appears in your library with its artwork and track names.")
                instructionStep(
                    number: 2,
                    text: "Connect your iPod to the Mac with its cable. It appears in the Finder sidebar (classic iPods and iPod nano/shuffle) and in Music's sidebar for iPod touch.")
                instructionStep(
                    number: 3,
                    text: "For classic iPods: click the iPod in the Finder sidebar, open the Music tab, choose “Sync music onto your iPod”, select this album (or your whole library), and click Apply.")
                instructionStep(
                    number: 4,
                    text: "For iPod touch: select the iPod in Music/Finder, enable music syncing, pick the album, and sync.")
                instructionStep(
                    number: 5,
                    text: "Wait for the sync to finish before unplugging. The album — artwork, track names, and order — now lives on your iPod.")
            }

            HelpCallout(
                systemImage: "info.circle",
                text: "The MP3s this app creates are standard files. Any music manager that supports iPods can also sync them.")

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(28)
        .frame(width: 560)
    }

    private func instructionStep(number: Int, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.headline)
                .frame(width: 26, height: 26)
                .background(Color.accentColor.opacity(0.15), in: Circle())
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
