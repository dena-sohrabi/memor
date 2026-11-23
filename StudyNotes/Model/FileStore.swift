import Foundation
import PDFKit
import SwiftData
import UIKit

/// Where files live on disk.
///
///     Application Support/PDFs/<id>.pdf     this iPad's copy of each PDF, never modified
///     Caches/Thumbnails/<id>.png             safe to delete, rebuilt as needed
///
/// Neither is the only copy: the PDFs themselves are in the database
/// (`PDFItem.fileData`), which syncs through iCloud.
enum FileStore {
    static var pdfDirectory: URL { directory(in: .applicationSupportDirectory, named: "PDFs") }
    static var thumbnailDirectory: URL { directory(in: .cachesDirectory, named: "Thumbnails") }

    static func pdfURL(fileName: String) -> URL {
        pdfDirectory.appending(path: fileName)
    }

    static func thumbnailURL(for id: UUID) -> URL {
        thumbnailDirectory.appending(path: "\(id.uuidString).png")
    }

    static func removeItem(at url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    /// Moves a file, replacing anything already at `destination`. Does
    /// nothing if there's no file at `source`.
    static func moveItem(at source: URL, to destination: URL) {
        let manager = FileManager.default
        guard manager.fileExists(atPath: source.path(percentEncoded: false)) else { return }
        try? manager.removeItem(at: destination)
        try? manager.moveItem(at: source, to: destination)
    }

    private static func directory(in base: FileManager.SearchPathDirectory, named name: String) -> URL {
        let root = FileManager.default.urls(for: base, in: .userDomainMask)[0]
        let url = root.appending(path: name, directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

struct ImportedPDF: Sendable {
    let id: UUID
    let title: String
    let fileName: String
    let pageCount: Int
    /// The file, for `PDFItem.fileData`.
    let data: Data
}

/// This iPad's copies of the PDFs. The files themselves are in the database
/// (`PDFItem.fileData`), which syncs through iCloud, but PDFKit reads from a
/// file, so each iPad writes a copy to `FileStore.pdfDirectory` the first
/// time it needs one.
enum PDFFiles {
    /// The copy on disk of the PDF with this id, written from the database
    /// first if it's missing (on a new iPad, or after a reinstall). Nil when
    /// the database doesn't have the file either: it was imported on an iPad
    /// that hasn't sent it to iCloud yet. Blocking: call it off the main
    /// thread.
    static func localURL(id: UUID, fileName: String) -> URL? {
        guard !fileName.isEmpty else { return nil }
        let url = FileStore.pdfURL(fileName: fileName)
        if FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) { return url }
        let context = ModelContext(Persistence.container)
        var descriptor = FetchDescriptor<PDFItem>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        guard let data = (try? context.fetch(descriptor))?.first?.fileData else { return nil }
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            Persistence.log.error("Couldn't write a PDF to disk: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    private static let storedKey = "storage.pdfFilesStored"

    /// PDFs imported before iCloud sync have their file only on disk. This
    /// puts those files into the database, so they sync too. Runs in the
    /// background, once per iPad.
    static func storeMissingFiles() {
        guard !UserDefaults.standard.bool(forKey: storedKey) else { return }
        Task.detached(priority: .utility) {
            let context = ModelContext(Persistence.container)
            let pdfs = (try? context.fetch(FetchDescriptor<PDFItem>())) ?? []
            for pdf in pdfs where pdf.fileData == nil {
                let url = FileStore.pdfURL(fileName: pdf.fileName)
                guard !pdf.fileName.isEmpty, let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { continue }
                pdf.fileData = data
            }
            do {
                if context.hasChanges { try context.save() }
                UserDefaults.standard.set(true, forKey: storedKey)
            } catch {
                Persistence.log.error("Couldn't add PDF files to the database: \(String(describing: error), privacy: .public)")
            }
        }
    }
}

enum PDFImportError: LocalizedError {
    case unreadable

    var errorDescription: String? {
        "This file isn't a PDF the app can read."
    }
}

enum PDFImporter {
    static let thumbnailSize = CGSize(width: 360, height: 480)

    /// Copies a PDF into the library and renders its first-page thumbnail.
    /// Blocking: call it off the main thread.
    static func importFile(at source: URL) throws -> ImportedPDF {
        let isScoped = source.startAccessingSecurityScopedResource()
        defer { if isScoped { source.stopAccessingSecurityScopedResource() } }

        let id = UUID()
        let fileName = "\(id.uuidString).pdf"
        let destination = FileStore.pdfURL(fileName: fileName)

        // Coordinated read, so files in iCloud Drive download first.
        var coordinationError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: source, options: .withoutChanges, error: &coordinationError) { readableURL in
            do {
                try FileManager.default.copyItem(at: readableURL, to: destination)
            } catch {
                copyError = error
            }
        }
        if let error = coordinationError ?? copyError { throw error }

        guard let document = PDFDocument(url: destination) else {
            FileStore.removeItem(at: destination)
            throw PDFImportError.unreadable
        }
        if let page = document.page(at: 0) {
            let image = page.thumbnail(of: thumbnailSize, for: .cropBox)
            try? image.pngData()?.write(to: FileStore.thumbnailURL(for: id), options: .atomic)
        }

        let data: Data
        do {
            data = try Data(contentsOf: destination, options: .mappedIfSafe)
        } catch {
            FileStore.removeItem(at: destination)
            throw error
        }

        let name = source.deletingPathExtension().lastPathComponent
        return ImportedPDF(
            id: id,
            title: name.isEmpty ? "Untitled PDF" : name,
            fileName: fileName,
            pageCount: document.pageCount,
            data: data
        )
    }
}
