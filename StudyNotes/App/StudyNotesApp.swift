import SwiftData
import SwiftUI

@main
struct StudyNotesApp: App {
    private let container: ModelContainer

    init() {
        container = Persistence.container
        // Settings from iCloud first, so the study pal starts with them.
        CloudSettings.start()
        PDFFiles.storeMissingFiles()
        // The study pal searches your notes, and shows her reminders.
        PalLibrary.container = container
        _ = Pal.shared
    }

    var body: some Scene {
        // Each window has its own tabs (see `Workspace`). Windows open only
        // when you ask: Open in New Window, or the system's New Window.
        WindowGroup(for: MemorWindow.self) { $window in
            WorkspaceView(window: window)
        } defaultValue: {
            MemorWindow()
        }
        .modelContainer(container)
    }
}
