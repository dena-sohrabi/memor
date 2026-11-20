import SwiftData

enum Persistence {
    /// One container shared by every window, so an edit in one window shows
    /// up in the others (and in the library) right away.
    static func makeContainer() -> ModelContainer {
        let schema = Schema([Notebook.self, NotebookPage.self, PDFItem.self, Highlight.self, PageInk.self, TextBox.self])
        let configuration = ModelConfiguration(schema: schema, cloudKitDatabase: .none)
        do {
            return try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            fatalError("Couldn't open the library database: \(error)")
        }
    }
}
