import SwiftData
import SwiftUI

@main
struct StudyNotesApp: App {
    private let container = Persistence.makeContainer()

    var body: some Scene {
        // The library. It always presents the same value, so opening it
        // again brings the existing window forward instead of a second one.
        WindowGroup("Library", id: WindowID.library, for: LibraryWindow.self) { _ in
            LibraryView()
        } defaultValue: {
            .main
        }
        .modelContainer(container)
        .handlesExternalEvents(matching: ["*"])

        // One window per open notebook or PDF. Opening an item that's
        // already open brings its window to the front.
        WindowGroup("Item", id: WindowID.item, for: OpenTarget.self) { $target in
            ItemWindow(target: target)
        }
        .modelContainer(container)
        .handlesExternalEvents(matching: [])
    }
}
