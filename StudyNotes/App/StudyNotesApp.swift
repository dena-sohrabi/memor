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
        // One window: the library, with notebooks and PDFs opening on top
        // of it (see `AppNavigator`).
        WindowGroup {
            LibraryView()
        }
        .modelContainer(container)
    }
}
