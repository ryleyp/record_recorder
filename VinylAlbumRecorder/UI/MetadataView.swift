import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Stage 6: album information and per-track titles.
struct MetadataView: View {
    @EnvironmentObject private var appState: AppState
    @State private var artworkImage: NSImage?

    var body: some View {
        StageContainer(
            title: "Album Details",
            subtitle: "This information is written into every MP3 so Apple Music and your iPod can display the album properly. Unnamed tracks are exported as “Track 01”, “Track 02”, and so on."
        ) {
            if appState.project != nil {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        albumForm
                        trackTable
                    }
                    .padding(.bottom, 12)
                }
            }
            HStack {
                Spacer()
                Button {
                    appState.stage = .export
                } label: {
                    Label("Continue to Export", systemImage: "arrow.right")
                        .frame(minWidth: 200)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .onAppear { loadArtwork() }
    }

    // MARK: Album form

    private var albumForm: some View {
        HStack(alignment: .top, spacing: 24) {
            artworkWell
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text("Album title")
                    TextField("Album title", text: projectBinding(\.albumTitle))
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 340)
                        .accessibilityLabel("Album title")
                }
                GridRow {
                    Text("Album artist")
                    TextField("Album artist", text: projectBinding(\.albumArtist))
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 340)
                        .accessibilityLabel("Album artist")
                }
                GridRow {
                    Text("Year")
                    TextField("e.g. 1974", text: yearBinding)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 120)
                        .accessibilityLabel("Release year")
                }
                GridRow {
                    Text("Genre")
                    TextField("e.g. Rock", text: projectBinding(\.genre))
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 240)
                        .accessibilityLabel("Genre")
                }
                GridRow {
                    Text("Disc")
                    HStack {
                        Stepper(value: projectBinding(\.discNumber), in: 1...20) {
                            Text("\(appState.project?.discNumber ?? 1)")
                                .frame(width: 24)
                        }
                        .accessibilityLabel("Disc number")
                        Text("of")
                        Stepper(value: projectBinding(\.discTotal), in: 1...20) {
                            Text("\(appState.project?.discTotal ?? 1)")
                                .frame(width: 24)
                        }
                        .accessibilityLabel("Total discs")
                    }
                }
            }
        }
    }

    private var artworkWell: some View {
        VStack(spacing: 8) {
            Group {
                if let artworkImage {
                    Image(nsImage: artworkImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    VStack(spacing: 6) {
                        Image(systemName: "photo.badge.plus")
                            .font(.title)
                            .foregroundStyle(.secondary)
                        Text("Drop artwork\nor click Choose")
                            .font(.caption)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(width: 150, height: 150)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(.quaternary, lineWidth: 1))
            .onDrop(of: [.image, .fileURL], isTargeted: nil) { providers in
                handleDrop(providers)
            }
            .accessibilityLabel("Album artwork")

            HStack {
                Button("Choose…") { chooseArtwork() }
                    .controlSize(.small)
                if artworkImage != nil {
                    Button("Remove") { removeArtwork() }
                        .controlSize(.small)
                }
            }
        }
    }

    // MARK: Track table

    private var trackTable: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Tracks").font(.headline)
            if appState.project?.totalTrackCount == 0 {
                HelpCallout(
                    systemImage: "info.circle",
                    text: "No tracks yet — record a side and run track detection first. Track numbering continues from Side A to Side B automatically.")
            }
            ForEach(SideLabel.allCases) { label in
                let side = appState.project?.side(label)
                if side?.hasRecording == true, let tracks = side?.tracks, !tracks.isEmpty {
                    sideSection(label: label, trackCount: tracks.count)
                }
            }
        }
    }

    private func sideSection(label: SideLabel, trackCount: Int) -> some View {
        let numberOffset = startingNumber(for: label)
        let side = appState.project?.side(label)
        let segments = side?.segments ?? []
        let isFileBased = side?.sourceType == .importedFolder
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label.title)
                    .font(.subheadline.bold())
                    .foregroundStyle(.secondary)
                if isFileBased {
                    Text("· imported files — use the arrows to reorder")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            ForEach(0..<trackCount, id: \.self) { index in
                let number = numberOffset + index
                HStack(spacing: 10) {
                    Text(String(format: "%02d", number))
                        .font(.callout.monospaced().bold())
                        .frame(width: 30)
                    if isFileBased {
                        Button {
                            reorder(side: label, from: index, to: index - 1)
                        } label: {
                            Image(systemName: "chevron.up")
                        }
                        .buttonStyle(.borderless)
                        .disabled(index == 0)
                        .accessibilityLabel("Move track \(number) up")
                        Button {
                            reorder(side: label, from: index, to: index + 1)
                        } label: {
                            Image(systemName: "chevron.down")
                        }
                        .buttonStyle(.borderless)
                        .disabled(index == trackCount - 1)
                        .accessibilityLabel("Move track \(number) down")
                    }
                    TextField(
                        String(format: "Track %02d", number),
                        text: trackBinding(side: label, index: index, keyPath: \.title))
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Title for track \(number)")
                    TextField(
                        "Artist (optional)",
                        text: trackBinding(side: label, index: index, keyPath: \.artist))
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 220)
                        .accessibilityLabel("Artist for track \(number)")
                    if index < segments.count {
                        Text(TimeFormat.mmss(segments[index].upperBound - segments[index].lowerBound))
                            .font(.callout.monospaced())
                            .foregroundStyle(.secondary)
                            .frame(width: 56, alignment: .trailing)
                    }
                }
            }
        }
    }

    private func reorder(side: SideLabel, from: Int, to: Int) {
        appState.updateSide(side) { record in
            record.moveTrackFile(from: from, to: to)
        }
    }

    private func startingNumber(for label: SideLabel) -> Int {
        guard label == .b, let sideA = appState.project?.side(.a), sideA.hasRecording else {
            return 1
        }
        return sideA.tracks.count + 1
    }

    // MARK: Bindings

    private func projectBinding<T>(_ keyPath: WritableKeyPath<AlbumProject, T>) -> Binding<T> {
        Binding(
            get: { appState.project![keyPath: keyPath] },
            set: { appState.project?[keyPath: keyPath] = $0 })
    }

    private var yearBinding: Binding<String> {
        Binding(
            get: {
                guard let year = appState.project?.year else { return "" }
                return String(year)
            },
            set: { text in
                appState.project?.year = Int(text.trimmingCharacters(in: .whitespaces))
            })
    }

    private func trackBinding(
        side: SideLabel, index: Int, keyPath: WritableKeyPath<TrackInfo, String>
    ) -> Binding<String> {
        Binding(
            get: {
                guard let tracks = appState.project?.side(side).tracks,
                      index < tracks.count else { return "" }
                return tracks[index][keyPath: keyPath]
            },
            set: { value in
                appState.updateSide(side) { record in
                    guard index < record.tracks.count else { return }
                    record.tracks[index][keyPath: keyPath] = value
                }
            })
    }

    // MARK: Artwork handling

    private func loadArtwork() {
        guard let packageURL = appState.packageURLValue,
              appState.project?.hasArtwork == true else { return }
        artworkImage = NSImage(contentsOf: ProjectStore.artworkURL(in: packageURL))
    }

    private func chooseArtwork() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url,
              let image = NSImage(contentsOf: url) else { return }
        setArtwork(image)
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        for provider in providers where provider.canLoadObject(ofClass: NSImage.self) {
            _ = provider.loadObject(ofClass: NSImage.self) { object, _ in
                if let image = object as? NSImage {
                    DispatchQueue.main.async {
                        setArtwork(image)
                    }
                }
            }
            return true
        }
        return false
    }

    private func setArtwork(_ image: NSImage) {
        guard let packageURL = appState.packageURLValue,
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.9])
        else { return }
        do {
            try jpeg.write(to: ProjectStore.artworkURL(in: packageURL))
            appState.project?.hasArtwork = true
            artworkImage = image
        } catch {
            appState.errorMessage = "The artwork could not be saved: \(error.localizedDescription)"
        }
    }

    private func removeArtwork() {
        guard let packageURL = appState.packageURLValue else { return }
        try? FileManager.default.removeItem(at: ProjectStore.artworkURL(in: packageURL))
        appState.project?.hasArtwork = false
        artworkImage = nil
    }
}

extension AppState {
    /// Convenience for views that need the package URL.
    var packageURLValue: URL? { packageURL }
}
