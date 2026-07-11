import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// The "Import from USB or Folder" workflow: pick files (from a removable
/// drive, folder, or anywhere), confirm the order, choose how they map to
/// record sides, and import — optionally with an Audacity label file.
struct ImportSheet: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var staged: [StagedImportFile] = []
    @State private var mode: ImportMode = .wholeSide
    @State private var side: SideLabel = .a
    @State private var splitAcrossSides = false
    @State private var copyIntoProject = true
    @State private var labelFileURL: URL?
    @State private var labelText: String?
    @State private var probeInFlight = false

    /// Files dropped on the start screen arrive pre-staged.
    var initialURLs: [URL] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Import Recordings")
                .font(.title2.bold())
            Text("Bring in audio the Crosley saved to a USB drive or SD card — or any audio files on this Mac. Originals are never modified. Supported: MP3, WAV, AIFF, M4A, AAC, FLAC, CAF.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            sourceButtons

            if !staged.isEmpty {
                fileList
                optionsPanel
            } else {
                dropZone
            }

            if let progress = appState.importProgress {
                VStack(alignment: .leading, spacing: 6) {
                    Text(appState.importStatus).font(.callout)
                    ProgressView(value: progress)
                }
            }
            if let error = appState.importError {
                HelpCallout(systemImage: "xmark.octagon", text: error, tint: .red)
            }

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button {
                    startImport()
                } label: {
                    Label(importButtonTitle, systemImage: "square.and.arrow.down")
                        .frame(minWidth: 160)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canImport)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 640)
        .frame(minHeight: 420)
        .onAppear {
            appState.importError = nil
            if !initialURLs.isEmpty {
                stage(urls: initialURLs)
            }
        }
        .onChange(of: appState.importProgress) { _, newValue in
            // performImport finished successfully → close the sheet.
            if newValue == nil && appState.importError == nil && probeInFlight == false && importStarted {
                dismiss()
            }
        }
    }

    @State private var importStarted = false

    // MARK: Sources

    private var sourceButtons: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Button {
                    chooseFiles(directory: nil)
                } label: {
                    Label("Choose Files…", systemImage: "doc.badge.plus")
                }
                Button {
                    chooseFolder(directory: nil)
                } label: {
                    Label("Choose Folder…", systemImage: "folder.badge.plus")
                }
                Button {
                    chooseLabelFile()
                } label: {
                    Label(labelFileURL == nil ? "Attach Audacity Labels…" : "Labels: \(labelFileURL!.lastPathComponent)",
                          systemImage: "text.badge.checkmark")
                }
                .help("An Audacity label file (.txt) provides track boundaries and titles, skipping silence detection.")
            }

            if !appState.volumeWatcher.removableVolumes.isEmpty {
                HStack(spacing: 8) {
                    Text("Removable drives:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(appState.volumeWatcher.removableVolumes) { volume in
                        Button {
                            chooseFiles(directory: volume.url)
                        } label: {
                            Label(volume.name, systemImage: "externaldrive.badge.plus")
                                .font(.caption)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .accessibilityLabel("Browse \(volume.name)")
                    }
                    Button {
                        appState.volumeWatcher.refresh()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Refresh drive list")
                }
            }
        }
    }

    private var dropZone: some View {
        VStack(spacing: 8) {
            Image(systemName: "square.and.arrow.down.on.square")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("Drop audio files or a folder here")
                .foregroundStyle(.secondary)
            Text("You can also drop an Audacity label .txt together with its audio file.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, minHeight: 140)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            handleDrop(providers)
        }
    }

    // MARK: File list

    private var fileList: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("\(staged.count) file\(staged.count == 1 ? "" : "s") — confirm the order")
                    .font(.headline)
                Spacer()
                Button("Clear") {
                    staged = []
                    labelFileURL = nil
                    labelText = nil
                }
                .controlSize(.small)
            }
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(Array(staged.enumerated()), id: \.element.id) { index, file in
                        HStack(spacing: 8) {
                            Text(String(format: "%02d", index + 1))
                                .font(.caption.monospaced().bold())
                                .frame(width: 24)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(file.url.lastPathComponent)
                                    .font(.callout)
                                    .lineLimit(1)
                                if let error = file.error {
                                    Text(error).font(.caption).foregroundStyle(.red)
                                } else if let info = file.info {
                                    Text(info.summary).font(.caption).foregroundStyle(.secondary)
                                }
                                ForEach(file.warnings, id: \.self) { warning in
                                    Label(warning, systemImage: "exclamationmark.triangle")
                                        .font(.caption)
                                        .foregroundStyle(.orange)
                                }
                            }
                            Spacer()
                            if staged.count > 1 {
                                Button {
                                    move(index: index, by: -1)
                                } label: {
                                    Image(systemName: "chevron.up")
                                }
                                .buttonStyle(.borderless)
                                .disabled(index == 0)
                                .accessibilityLabel("Move \(file.url.lastPathComponent) up")
                                Button {
                                    move(index: index, by: 1)
                                } label: {
                                    Image(systemName: "chevron.down")
                                }
                                .buttonStyle(.borderless)
                                .disabled(index == staged.count - 1)
                                .accessibilityLabel("Move \(file.url.lastPathComponent) down")
                            }
                            Button {
                                staged.remove(at: index)
                            } label: {
                                Image(systemName: "xmark.circle")
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Remove \(file.url.lastPathComponent)")
                        }
                        .padding(.vertical, 3)
                        .padding(.horizontal, 6)
                        .background(
                            index % 2 == 0 ? Color.primary.opacity(0.03) : .clear,
                            in: RoundedRectangle(cornerRadius: 4))
                    }
                }
            }
            .frame(maxHeight: 180)
        }
    }

    // MARK: Options

    private var optionsPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            if staged.count == 1 {
                // A single file is almost always a whole side.
                Picker("This file is", selection: $mode) {
                    ForEach(ImportMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
            } else {
                Picker("These files are", selection: $mode) {
                    ForEach(ImportMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
            }
            Text(mode.explanation)
                .font(.caption)
                .foregroundStyle(.secondary)

            if mode == .wholeSide && staged.count >= 2 {
                Toggle("First file is Side A, second file is Side B", isOn: $splitAcrossSides)
                    .toggleStyle(.switch)
            }
            if !(mode == .wholeSide && splitAcrossSides) {
                Picker("Import into", selection: $side) {
                    Text("Side A").tag(SideLabel.a)
                    Text("Side B").tag(SideLabel.b)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 260)
            }

            Toggle(isOn: $copyIntoProject) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Copy files into the project (recommended)")
                    Text("Copies stay safe when the USB drive is removed. Turn off to reference the originals in place instead.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)

            if labelText != nil && mode == .wholeSide {
                HelpCallout(
                    systemImage: "text.badge.checkmark",
                    text: "The Audacity labels will set the track boundaries and titles automatically — no silence detection needed.")
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: Actions

    private var canImport: Bool {
        appState.importProgress == nil
            && staged.contains { $0.error == nil }
            && !(mode == .wholeSide && !splitAcrossSides && staged.filter { $0.error == nil }.count > 1)
    }

    private var importButtonTitle: String {
        if mode == .wholeSide && !splitAcrossSides && staged.filter({ $0.error == nil }).count > 1 {
            return "Pick one file or enable A/B split"
        }
        return "Import"
    }

    private func startImport() {
        importStarted = true
        appState.performImport(ImportRequest(
            files: staged,
            side: side,
            mode: mode,
            copyIntoProject: copyIntoProject,
            labelText: mode == .wholeSide ? labelText : nil,
            splitAcrossSides: mode == .wholeSide && splitAcrossSides))
    }

    private func move(index: Int, by offset: Int) {
        let target = index + offset
        guard staged.indices.contains(index), staged.indices.contains(target) else { return }
        staged.swapAt(index, target)
    }

    private func chooseFiles(directory: URL?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.directoryURL = directory
        panel.message = "Choose audio files, a folder of audio files, or an Audacity label .txt."
        if panel.runModal() == .OK {
            stage(urls: panel.urls)
        }
    }

    private func chooseFolder(directory: URL?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = directory
        if panel.runModal() == .OK, let url = panel.url {
            stage(urls: [url])
        }
    }

    private func chooseLabelFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.plainText]
        panel.allowsMultipleSelection = false
        panel.message = "Choose the label file exported from Audacity (File › Export › Export Labels)."
        if panel.runModal() == .OK, let url = panel.url {
            attachLabelFile(url)
        }
    }

    private func attachLabelFile(_ url: URL) {
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              !AudacityLabels.parse(text).isEmpty else {
            appState.importError = "\(url.lastPathComponent) does not look like an Audacity label file."
            return
        }
        labelFileURL = url
        labelText = text
        mode = .wholeSide
        appState.importError = nil
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var found = false
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            found = true
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                DispatchQueue.main.async {
                    stage(urls: [url])
                }
            }
        }
        return found
    }

    /// Expands folders, routes label files, probes audio files.
    private func stage(urls: [URL]) {
        probeInFlight = true
        appState.importError = nil
        let existingPaths = Set(staged.map(\.url.path))
        Task.detached(priority: .userInitiated) {
            var newFiles: [StagedImportFile] = []
            var labelURL: URL?
            var rejected: [String] = []

            for url in urls {
                var isDirectory: ObjCBool = false
                FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
                if isDirectory.boolValue && url.pathExtension.lowercased() != "aup3" {
                    for fileURL in AudioImporter.scanFolder(url) where !existingPaths.contains(fileURL.path) {
                        newFiles.append(probeStaged(fileURL))
                    }
                } else if url.pathExtension.lowercased() == "txt" {
                    labelURL = url
                } else if url.pathExtension.lowercased() == "aup3" {
                    rejected.append("\(url.lastPathComponent): Audacity .aup3 projects can't be opened directly yet. In Audacity use File › Export › Export Audio (plus Export Labels), then import those files.")
                } else if AudioImporter.isSupported(url) {
                    if !existingPaths.contains(url.path) {
                        newFiles.append(probeStaged(url))
                    }
                } else {
                    rejected.append("\(url.lastPathComponent): unsupported format.")
                }
            }

            let files = newFiles
            let label = labelURL
            let rejections = rejected
            await MainActor.run {
                staged.append(contentsOf: files)
                if staged.filter({ $0.error == nil }).count > 1 {
                    mode = staged.count == 2 ? mode : .trackPerFile
                }
                if let label {
                    attachLabelFile(label)
                }
                if !rejections.isEmpty {
                    appState.importError = rejections.joined(separator: "\n")
                }
                probeInFlight = false
            }
        }
    }
}

/// Probes one file for the staging list (runs off the main thread).
private func probeStaged(_ url: URL) -> StagedImportFile {
    var file = StagedImportFile(url: url)
    do {
        let (info, warnings) = try AudioImporter.probe(url: url)
        file.info = info
        file.warnings = warnings
        file.title = AudioImporter.embeddedTitle(of: url)
    } catch {
        file.error = error.localizedDescription
    }
    return file
}
