import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        Text("LAME \(String(cString: get_lame_version()))")
            .padding()
    }
}
