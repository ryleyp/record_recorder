import SwiftUI

/// Top-level application state: the open project, current workflow stage,
/// and glue between the audio engine, detection, and export layers.
@MainActor
final class AppState: ObservableObject {
    @Published var project: AlbumProject?
    @Published var stage: WorkflowStage = .connect

    func requestNewProject() {}
    func requestOpenProject() {}
    func saveProjectNow() {}
}

enum WorkflowStage: Int, CaseIterable, Identifiable, Codable {
    case connect
    case levels
    case record
    case detect
    case review
    case metadata
    case export

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .connect: return "Connect"
        case .levels: return "Set Levels"
        case .record: return "Record"
        case .detect: return "Detect Tracks"
        case .review: return "Review Tracks"
        case .metadata: return "Album Details"
        case .export: return "Export"
        }
    }
}
