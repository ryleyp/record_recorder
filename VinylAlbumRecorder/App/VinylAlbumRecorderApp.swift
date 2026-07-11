import SwiftUI

@main
struct VinylAlbumRecorderApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .frame(minWidth: 980, minHeight: 640)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Album Project…") {
                    appState.requestNewProject()
                }
                .keyboardShortcut("n")
                Button("Open Album Project…") {
                    appState.requestOpenProject()
                }
                .keyboardShortcut("o")
            }
            CommandGroup(after: .saveItem) {
                Button("Save Project") {
                    appState.saveProjectNow()
                }
                .keyboardShortcut("s")
                .disabled(appState.project == nil)
            }
        }
    }
}
