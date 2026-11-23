import Foundation
import os
import SwiftData

/// The library database: notebooks, pages, images, typed notes, Ask chats,
/// PDFs (the files themselves too) and everything on them.
///
/// It's a database on the iPad that SwiftData mirrors to your private iCloud
/// database, so it's on every iPad signed in to your Apple Account and comes
/// back after deleting and reinstalling the app. Without iCloud (signed out,
/// or iCloud full) it keeps working on the iPad and syncs once it can.
enum Persistence {
    /// Must match `Config/StudyNotes.entitlements`.
    static let cloudContainerID = "iCloud.com.denasohrabi.memor"

    /// One container shared by every window, so an edit in one window shows
    /// up in the others (and in the library) right away.
    static let container: ModelContainer = makeContainer()

    static let log = Logger(subsystem: "com.denasohrabi.memor", category: "storage")

    private static let modelTypes: [any PersistentModel.Type] = [Notebook.self, NotebookPage.self, CanvasImage.self, AskThread.self, PDFItem.self, Highlight.self, PageInk.self, TextBox.self]

    private static func makeContainer() -> ModelContainer {
        let schema = Schema(modelTypes)
        let synced = ModelConfiguration(schema: schema, cloudKitDatabase: .private(cloudContainerID))
        // Same database file without iCloud.
        let local = ModelConfiguration(schema: schema, cloudKitDatabase: .none)
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "InitCloudKitSchema") {
            initializeCloudKitSchema()
            // The library stays off iCloud for this launch, so your notes
            // aren't copied to Development, which only debug builds use.
            if let container = try? ModelContainer(for: schema, configurations: [local]) { return container }
        }
        #endif
        do {
            return try ModelContainer(for: schema, configurations: [synced])
        } catch {
            // The library still opens, just without iCloud.
            log.error("iCloud sync is off: \(String(describing: error), privacy: .public)")
        }
        do {
            return try ModelContainer(for: schema, configurations: [local])
        } catch {
            fatalError("Couldn't open the library database: \(error)")
        }
    }
}

#if DEBUG
import CoreData

extension Persistence {
    /// TestFlight and App Store builds sync through CloudKit's Production
    /// environment, which only has the record types and fields deployed to
    /// it from Development. Debug builds add them to Development as they
    /// save, but only for values they've saved, so this creates all of them
    /// at once: launch a debug build signed in to iCloud with the argument
    /// `-InitCloudKitSchema YES`, then deploy the schema to Production in
    /// the CloudKit Console. Apple's recommended way; it uploads a sample
    /// record of each type and deletes it again. It uses an empty, throwaway
    /// store, so the library isn't touched.
    fileprivate static func initializeCloudKitSchema() {
        guard let model = NSManagedObjectModel.makeManagedObjectModel(for: modelTypes) else {
            log.error("CloudKit schema: couldn't make the model.")
            return
        }
        let storeURL = URL.temporaryDirectory.appending(path: "CloudKitSchema.store")
        let storeFiles = ["", "-shm", "-wal"].map { URL(filePath: storeURL.path(percentEncoded: false) + $0) }
        storeFiles.forEach { try? FileManager.default.removeItem(at: $0) }
        defer { storeFiles.forEach { try? FileManager.default.removeItem(at: $0) } }
        do {
            // Let go of this container before the library opens.
            try autoreleasepool {
                let description = NSPersistentStoreDescription(url: storeURL)
                description.cloudKitContainerOptions = NSPersistentCloudKitContainerOptions(containerIdentifier: cloudContainerID)
                description.shouldAddStoreAsynchronously = false
                let container = NSPersistentCloudKitContainer(name: "Memor", managedObjectModel: model)
                container.persistentStoreDescriptions = [description]
                container.loadPersistentStores { _, error in
                    if let error { Persistence.log.error("CloudKit schema: couldn't open the store: \(String(describing: error), privacy: .public)") }
                }
                guard let store = container.persistentStoreCoordinator.persistentStores.first else { return }
                try container.initializeCloudKitSchema()
                try container.persistentStoreCoordinator.remove(store)
                log.notice("CloudKit schema created in Development. Deploy it to Production in the CloudKit Console.")
            }
        } catch {
            log.error("CloudKit schema: \(String(describing: error), privacy: .public)")
        }
    }
}
#endif
