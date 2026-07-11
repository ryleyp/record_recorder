import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        Group {
            if appState.project == nil {
                WelcomeView()
            } else {
                workspace
            }
        }
        .alert(
            "Something Went Wrong",
            isPresented: Binding(
                get: { appState.errorMessage != nil },
                set: { if !$0 { appState.errorMessage = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(appState.errorMessage ?? "")
        }
        .alert(
            "Audio Input Problem",
            isPresented: Binding(
                get: { appState.recorder.lastError != nil },
                set: { if !$0 { appState.recorder.lastError = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(appState.recorder.lastError?.errorDescription ?? "")
        }
        .alert(
            "Recording Recovered",
            isPresented: Binding(
                get: { appState.recoveredSide != nil },
                set: { if !$0 { appState.recoveredSide = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("The app did not shut down cleanly while recording \(appState.recoveredSide?.title ?? ""). The audio captured before the interruption has been kept — review it in Detect Tracks, or record the side again.")
        }
        .alert(
            "Recordings Missing",
            isPresented: Binding(
                get: { !appState.missingAudioSides.isEmpty },
                set: { if !$0 { appState.missingAudioSides = [] } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("The audio for \(appState.missingAudioSides.map(\.title).joined(separator: " and ")) could not be found inside the project. The files may have been moved or deleted. Those sides will need to be recorded again.")
        }
    }

    private var workspace: some View {
        NavigationSplitView {
            List(selection: stageSelection) {
                Section(appState.project?.displayTitle ?? "Album") {
                    ForEach(WorkflowStage.allCases) { stage in
                        Label(stage.title, systemImage: stage.systemImage)
                            .tag(stage)
                            .accessibilityLabel("Step \(stage.rawValue + 1): \(stage.title)")
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210)
        } detail: {
            stageView
        }
    }

    private var stageSelection: Binding<WorkflowStage?> {
        Binding(
            get: { appState.stage },
            set: { newValue in
                if let newValue { appState.stage = newValue }
            })
    }

    @ViewBuilder
    private var stageView: some View {
        switch appState.stage {
        case .connect: ConnectView()
        case .levels: LevelsView()
        case .record: RecordView()
        case .detect: DetectView()
        case .review: ReviewView()
        case .metadata: MetadataView()
        case .export: ExportView()
        }
    }
}

/// Landing screen: create or open a project.
struct WelcomeView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "opticaldisc")
                .font(.system(size: 72))
                .foregroundStyle(.secondary)
            Text("Vinyl Album Recorder")
                .font(.largeTitle.bold())
            Text("Record a vinyl record through a USB audio adapter, split it into tracks, and export a ready-to-sync MP3 album.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 480)
            HStack(spacing: 16) {
                Button {
                    appState.requestNewProject()
                } label: {
                    Label("New Album Project", systemImage: "plus")
                        .frame(minWidth: 180)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)

                Button {
                    appState.requestOpenProject()
                } label: {
                    Label("Open Project…", systemImage: "folder")
                        .frame(minWidth: 180)
                }
                .controlSize(.large)
            }
        }
        .padding(48)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
