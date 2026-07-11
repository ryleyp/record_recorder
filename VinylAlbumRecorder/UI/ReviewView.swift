import SwiftUI

/// Stage 5: full-side waveform with editable track markers.
struct ReviewView: View {
    @EnvironmentObject private var appState: AppState

    // Zoom/scroll state (seconds).
    @State private var zoom: Double = 1          // 1 = whole side visible
    @State private var scrollPosition: Double = 0 // left edge of the visible window (0…1 of scrollable range)
    @State private var selectedMarker: MarkerID?

    // Undo/redo snapshots of (boundaries, trimStart, trimEnd).
    @State private var undoStack: [SideEditSnapshot] = []
    @State private var redoStack: [SideEditSnapshot] = []
    @State private var dragStartSnapshot: SideEditSnapshot?

    enum MarkerID: Hashable {
        case boundary(Int)
        case trimStart
        case trimEnd
    }

    struct SideEditSnapshot: Equatable {
        var boundaries: [Double]
        var trimStart: Double
        var trimEnd: Double
    }

    var body: some View {
        StageContainer(
            title: "Review Tracks",
            subtitle: "Drag the yellow markers to adjust where tracks split. Green and red markers trim silence from the start and end of the side. Click a marker to select it; use Preview to hear the audio around a cut."
        ) {
            sideHeader

            if currentSide?.sourceType == .importedFolder {
                HelpCallout(
                    systemImage: "checkmark.circle",
                    text: "\(appState.activeSide.title) was imported as separate song files, so there are no cut points to review. Rename and reorder the tracks in Album Details.")
            } else if let analysis = appState.analyses[appState.activeSide],
               currentSide?.hasRecording == true {
                editor(analysis: analysis)
                trackList
            } else if currentSide?.hasRecording == true {
                ProgressView("Loading waveform…")
                    .frame(maxWidth: .infinity)
                    .onAppear { appState.ensureAnalysis(for: appState.activeSide) }
            } else {
                HelpCallout(
                    systemImage: "exclamationmark.triangle",
                    text: "\(appState.activeSide.title) has not been recorded yet.",
                    tint: .orange)
            }

            Spacer(minLength: 0)

            HStack {
                Spacer()
                Button {
                    appState.stage = .metadata
                } label: {
                    Label("Continue to Album Details", systemImage: "arrow.right")
                        .frame(minWidth: 220)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
            }
        }
        .onAppear { loadPlayback() }
        .onChange(of: appState.activeSide) {
            selectedMarker = nil
            undoStack = []
            redoStack = []
            appState.ensureAnalysis(for: appState.activeSide)
            loadPlayback()
        }
        .onDisappear { appState.playback.stop() }
    }

    private var currentSide: RecordSide? {
        appState.project?.side(appState.activeSide)
    }

    private func loadPlayback() {
        guard let url = appState.recordingURL(for: appState.activeSide),
              currentSide?.hasRecording == true,
              currentSide?.sourceType != .importedFolder else { return }
        try? appState.playback.load(url: url)
    }

    // MARK: Header / transport

    private var sideHeader: some View {
        HStack(spacing: 12) {
            Picker("Side", selection: $appState.activeSide) {
                ForEach(SideLabel.allCases) { side in
                    Text(side.title).tag(side)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 200)

            Button {
                appState.playback.togglePlayPause()
            } label: {
                Image(systemName: appState.playback.isPlaying ? "pause.fill" : "play.fill")
                    .frame(width: 36)
            }
            .controlSize(.large)
            .keyboardShortcut(.space, modifiers: [])
            .accessibilityLabel(appState.playback.isPlaying ? "Pause" : "Play")

            Text(TimeFormat.mmss(appState.playback.currentTime))
                .font(.body.monospaced())
                .frame(width: 70, alignment: .leading)

            Spacer()

            Button {
                addMarkerAtPlayhead()
            } label: {
                Label("Add Marker", systemImage: "plus")
            }
            .keyboardShortcut("m")
            .accessibilityHint("Adds a track boundary at the playhead position")

            Button {
                deleteSelectedMarker()
            } label: {
                Label("Delete Marker", systemImage: "minus")
            }
            .disabled({
                guard case .boundary = selectedMarker else { return true }
                return false
            }())
            .keyboardShortcut(.delete, modifiers: [])

            Divider().frame(height: 20)

            Button {
                undo()
            } label: {
                Image(systemName: "arrow.uturn.backward")
            }
            .disabled(undoStack.isEmpty)
            .keyboardShortcut("z")
            .accessibilityLabel("Undo")

            Button {
                redo()
            } label: {
                Image(systemName: "arrow.uturn.forward")
            }
            .disabled(redoStack.isEmpty)
            .keyboardShortcut("z", modifiers: [.command, .shift])
            .accessibilityLabel("Redo")
        }
    }

    // MARK: Waveform editor

    private func editor(analysis: SideAnalysis) -> some View {
        let duration = analysis.duration
        let visibleDuration = duration / zoom
        let maxStart = max(0, duration - visibleDuration)
        let viewStart = scrollPosition * maxStart

        return VStack(spacing: 8) {
            WaveformCanvas(
                analysis: analysis,
                viewStart: viewStart,
                visibleDuration: visibleDuration,
                boundaries: currentSide?.boundaries ?? [],
                trimStart: currentSide?.trimStart ?? 0,
                trimEnd: currentSide?.effectiveEnd ?? duration,
                playhead: appState.playback.currentTime,
                selectedMarker: selectedMarker,
                onSeek: { time in
                    appState.playback.seek(to: time)
                },
                onSelectMarker: { marker in
                    selectedMarker = marker
                },
                onDragMarker: { marker, time in
                    if dragStartSnapshot == nil {
                        dragStartSnapshot = snapshot()
                    }
                    moveMarker(marker, to: time, duration: duration)
                },
                onDragEnded: {
                    if let start = dragStartSnapshot, start != snapshot() {
                        undoStack.append(start)
                        redoStack = []
                    }
                    dragStartSnapshot = nil
                })
                .frame(height: 180)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
                .accessibilityLabel("Waveform of \(appState.activeSide.title)")
                .accessibilityHint("Shows the recorded audio with draggable track markers")

            HStack(spacing: 12) {
                Image(systemName: "minus.magnifyingglass")
                    .foregroundStyle(.secondary)
                Slider(value: $zoom, in: 1...60)
                    .frame(maxWidth: 220)
                    .accessibilityLabel("Zoom")
                Image(systemName: "plus.magnifyingglass")
                    .foregroundStyle(.secondary)
                if zoom > 1.01 {
                    Slider(value: $scrollPosition, in: 0...1)
                        .accessibilityLabel("Scroll position")
                } else {
                    Spacer()
                }
                Text("\(TimeFormat.mmss(viewStart)) – \(TimeFormat.mmss(viewStart + visibleDuration))")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Track list

    private var trackList: some View {
        let segments = currentSide?.segments ?? []
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("\(segments.count) tracks").font(.headline)
                Spacer()
                Text("Short tracks are flagged — they are often false splits.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(Array(segments.enumerated()), id: \.offset) { index, range in
                        HStack {
                            Text(String(format: "%02d", index + 1))
                                .font(.callout.monospaced().bold())
                                .frame(width: 30)
                            Text("\(TimeFormat.mmss(range.lowerBound)) – \(TimeFormat.mmss(range.upperBound))")
                                .font(.callout.monospaced())
                                .foregroundStyle(.secondary)
                            Text(TimeFormat.mmss(range.upperBound - range.lowerBound))
                                .font(.callout.monospaced())
                            if range.upperBound - range.lowerBound < 30 {
                                Label("Short track", systemImage: "exclamationmark.triangle.fill")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            }
                            Spacer()
                            Button {
                                appState.playback.play(
                                    from: range.lowerBound,
                                    until: min(range.lowerBound + 5, range.upperBound))
                            } label: {
                                Label("Start", systemImage: "play.circle")
                                    .font(.caption)
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Preview start of track \(index + 1)")
                            if index < segments.count - 1 {
                                Button {
                                    let cut = range.upperBound
                                    appState.playback.previewAround(time: cut)
                                } label: {
                                    Label("Cut", systemImage: "scissors")
                                        .font(.caption)
                                }
                                .buttonStyle(.borderless)
                                .accessibilityLabel("Preview the cut after track \(index + 1)")
                            }
                        }
                        .padding(.vertical, 4)
                        .padding(.horizontal, 8)
                        .background(
                            index % 2 == 0 ? Color.primary.opacity(0.03) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 4))
                    }
                }
            }
            .frame(maxHeight: 170)
        }
    }

    // MARK: Editing operations

    private func snapshot() -> SideEditSnapshot {
        SideEditSnapshot(
            boundaries: currentSide?.boundaries ?? [],
            trimStart: currentSide?.trimStart ?? 0,
            trimEnd: currentSide?.trimEnd ?? 0)
    }

    private func apply(_ snap: SideEditSnapshot) {
        appState.updateSide(appState.activeSide) { side in
            side.boundaries = snap.boundaries
            side.trimStart = snap.trimStart
            side.trimEnd = snap.trimEnd
            side.reconcileTrackList()
        }
    }

    private func pushUndo() {
        undoStack.append(snapshot())
        redoStack = []
    }

    private func undo() {
        guard let last = undoStack.popLast() else { return }
        redoStack.append(snapshot())
        apply(last)
    }

    private func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(snapshot())
        apply(next)
    }

    private func addMarkerAtPlayhead() {
        let time = appState.playback.currentTime
        guard let side = currentSide,
              time > side.trimStart + 1,
              time < side.effectiveEnd - 1 else { return }
        pushUndo()
        appState.updateSide(appState.activeSide) { side in
            side.boundaries.append(time)
            side.boundaries.sort()
            side.reconcileTrackList()
        }
        if let index = currentSide?.boundaries.firstIndex(of: time) {
            selectedMarker = .boundary(index)
        }
    }

    private func deleteSelectedMarker() {
        guard case .boundary(let index) = selectedMarker,
              let side = currentSide, index < side.boundaries.count else { return }
        pushUndo()
        appState.updateSide(appState.activeSide) { side in
            side.boundaries.remove(at: index)
            side.reconcileTrackList()
        }
        selectedMarker = nil
    }

    private func moveMarker(_ marker: MarkerID, to time: Double, duration: Double) {
        appState.updateSide(appState.activeSide) { side in
            switch marker {
            case .boundary(let index):
                guard index < side.boundaries.count else { return }
                let lower = index > 0 ? side.boundaries[index - 1] + 0.5 : side.trimStart + 0.5
                let upper = index < side.boundaries.count - 1
                    ? side.boundaries[index + 1] - 0.5
                    : side.effectiveEnd - 0.5
                side.boundaries[index] = min(max(time, lower), upper)
            case .trimStart:
                let upper = (side.boundaries.first ?? side.effectiveEnd) - 0.5
                side.trimStart = min(max(time, 0), upper)
            case .trimEnd:
                let lower = (side.boundaries.last ?? side.trimStart) + 0.5
                side.trimEnd = min(max(time, lower), duration)
            }
            side.reconcileTrackList()
        }
    }
}

// MARK: - Canvas

/// Draws the waveform, markers, trim handles, and playhead, and translates
/// clicks/drags into seek and marker-move actions.
struct WaveformCanvas: View {
    let analysis: SideAnalysis
    let viewStart: Double
    let visibleDuration: Double
    let boundaries: [Double]
    let trimStart: Double
    let trimEnd: Double
    let playhead: Double
    let selectedMarker: ReviewView.MarkerID?
    let onSeek: (Double) -> Void
    let onSelectMarker: (ReviewView.MarkerID?) -> Void
    let onDragMarker: (ReviewView.MarkerID, Double) -> Void
    let onDragEnded: () -> Void

    @State private var activeDragMarker: ReviewView.MarkerID?

    private let markerGrabDistance: CGFloat = 10

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            Canvas { context, size in
                draw(context: context, size: size)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let time = time(atX: value.location.x, width: size.width)
                        if activeDragMarker == nil {
                            // Decide once at gesture start: grab a marker or scrub.
                            if let marker = nearestMarker(toX: value.startLocation.x, width: size.width) {
                                activeDragMarker = marker
                                onSelectMarker(marker)
                            } else {
                                activeDragMarker = nil
                                onSelectMarker(nil)
                                onSeek(time)
                                return
                            }
                        }
                        if let marker = activeDragMarker {
                            onDragMarker(marker, time)
                        } else {
                            onSeek(time)
                        }
                    }
                    .onEnded { _ in
                        if activeDragMarker != nil {
                            onDragEnded()
                        }
                        activeDragMarker = nil
                    })
        }
    }

    private func x(forTime time: Double, width: CGFloat) -> CGFloat {
        CGFloat((time - viewStart) / visibleDuration) * width
    }

    private func time(atX x: CGFloat, width: CGFloat) -> Double {
        viewStart + Double(x / max(width, 1)) * visibleDuration
    }

    private func nearestMarker(toX x: CGFloat, width: CGFloat) -> ReviewView.MarkerID? {
        var best: (ReviewView.MarkerID, CGFloat)?
        func consider(_ marker: ReviewView.MarkerID, _ time: Double) {
            let distance = abs(self.x(forTime: time, width: width) - x)
            if distance <= markerGrabDistance && (best == nil || distance < best!.1) {
                best = (marker, distance)
            }
        }
        for (index, boundary) in boundaries.enumerated() {
            consider(.boundary(index), boundary)
        }
        consider(.trimStart, trimStart)
        consider(.trimEnd, trimEnd)
        return best?.0
    }

    private func draw(context: GraphicsContext, size: CGSize) {
        let midY = size.height / 2
        let bucketDuration = analysis.bucketSeconds
        let firstBucket = max(0, Int(viewStart / bucketDuration))
        let lastBucket = min(analysis.peaks.count, Int((viewStart + visibleDuration) / bucketDuration) + 1)
        guard lastBucket > firstBucket else { return }

        // Aggregate buckets per pixel column.
        let bucketsVisible = lastBucket - firstBucket
        let bucketsPerPixel = max(1, bucketsVisible / max(Int(size.width), 1))

        var path = Path()
        var bucket = firstBucket
        while bucket < lastBucket {
            let groupEnd = min(bucket + bucketsPerPixel, lastBucket)
            var lo: Float = 0
            var hi: Float = 0
            for b in bucket..<groupEnd {
                lo = min(lo, analysis.peaks[b].minValue)
                hi = max(hi, analysis.peaks[b].maxValue)
            }
            let time = Double(bucket) * bucketDuration
            let px = x(forTime: time, width: size.width)
            let yHi = midY - CGFloat(hi) * midY
            let yLo = midY - CGFloat(lo) * midY
            path.move(to: CGPoint(x: px, y: yHi))
            path.addLine(to: CGPoint(x: px, y: max(yLo, yHi + 1)))
            bucket = groupEnd
        }
        context.stroke(path, with: .color(.accentColor.opacity(0.75)), lineWidth: 1)

        // Dim the trimmed-away regions.
        let trimStartX = x(forTime: trimStart, width: size.width)
        if trimStartX > 0 {
            context.fill(
                Path(CGRect(x: 0, y: 0, width: trimStartX, height: size.height)),
                with: .color(.black.opacity(0.25)))
        }
        let trimEndX = x(forTime: trimEnd, width: size.width)
        if trimEndX < size.width {
            context.fill(
                Path(CGRect(x: trimEndX, y: 0, width: size.width - trimEndX, height: size.height)),
                with: .color(.black.opacity(0.25)))
        }

        // Track boundaries.
        for (index, boundary) in boundaries.enumerated() {
            let bx = x(forTime: boundary, width: size.width)
            guard bx >= -20, bx <= size.width + 20 else { continue }
            let isSelected = selectedMarker == .boundary(index)
            var line = Path()
            line.move(to: CGPoint(x: bx, y: 0))
            line.addLine(to: CGPoint(x: bx, y: size.height))
            context.stroke(
                line,
                with: .color(isSelected ? .orange : .yellow),
                lineWidth: isSelected ? 2.5 : 1.5)
            // Handle at the top.
            let handle = Path(ellipseIn: CGRect(x: bx - 5, y: 2, width: 10, height: 10))
            context.fill(handle, with: .color(isSelected ? .orange : .yellow))
        }

        // Trim markers.
        for (marker, time, color) in [
            (ReviewView.MarkerID.trimStart, trimStart, Color.green),
            (ReviewView.MarkerID.trimEnd, trimEnd, Color.red),
        ] {
            let mx = x(forTime: time, width: size.width)
            guard mx >= -20, mx <= size.width + 20 else { continue }
            let isSelected = selectedMarker == marker
            var line = Path()
            line.move(to: CGPoint(x: mx, y: 0))
            line.addLine(to: CGPoint(x: mx, y: size.height))
            context.stroke(line, with: .color(color), lineWidth: isSelected ? 2.5 : 1.5)
            let handle = Path(CGRect(x: marker == .trimStart ? mx : mx - 8, y: 0, width: 8, height: 12))
            context.fill(handle, with: .color(color))
        }

        // Playhead.
        let px = x(forTime: playhead, width: size.width)
        if px >= 0, px <= size.width {
            var line = Path()
            line.move(to: CGPoint(x: px, y: 0))
            line.addLine(to: CGPoint(x: px, y: size.height))
            context.stroke(line, with: .color(.primary), lineWidth: 1)
        }
    }
}
