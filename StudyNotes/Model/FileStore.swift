import Foundation
import PDFKit
import UIKit

/// Where files live on disk.
///
///     Application Support/PDFs/<id>.pdf     imported copies, never modified
///     Caches/Thumbnails/<id>.png             safe to delete, rebuilt as needed
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

        let name = source.deletingPathExtension().lastPathComponent
        return ImportedPDF(
            id: id,
            title: name.isEmpty ? "Untitled PDF" : name,
            fileName: fileName,
            pageCount: document.pageCount
        )
    }
}
