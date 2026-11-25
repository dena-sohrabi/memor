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
        // The main window: the library, with notebooks and PDFs opening on
        // top of it (see `AppNavigator`). It always shows the same value, so
        // asking for it again brings it forward instead of a second one.
        // "Open in Memor" from other apps comes here.
        WindowGroup("Memor", id: WindowID.main, for: MainWindow.self) { _ in
            LibraryView()
        } defaultValue: {
            .main
        }
        .modelContainer(container)
        .handlesExternalEvents(matching: ["*"])

        // A notebook or PDF in a window of its own, only when you ask (Open
        // in New Window). Asking again for one that's open brings its window
        // forward.
        WindowGroup("Notebook or PDF", id: WindowID.item, for: OpenTarget.self) { $target in
            ItemWindow(target: target)
        }
        .modelContainer(container)
        .handlesExternalEvents(matching: [])
    }
}
