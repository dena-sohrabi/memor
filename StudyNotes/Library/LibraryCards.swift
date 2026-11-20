import SwiftUI
import UIKit

struct NotebookCard: View {
    let notebook: Notebook

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Color.clear
                .aspectRatio(4 / 3, contentMode: .fit)
                .overlay {
                    ThumbnailView(id: notebook.coverPageID, version: notebook.modifiedAt, placeholderSymbol: "scribble")
                }
                .clipShape(.rect(cornerRadius: 12))
                .overlay {
                    RoundedRectangle(cornerRadius: 12).strokeBorder(.separator, lineWidth: 0.5)
                }
            Text(notebook.title)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .contentShape(.rect)
        .hoverEffect(.highlight)
    }

    private var subtitle: String {
        let edited = "Edited \(notebook.modifiedAt.formatted(.relative(presentation: .named)))"
        let pageCount = notebook.sortedPages.count
        return pageCount > 1 ? "\(pageCount) pages · \(edited)" : edited
    }
}

struct PDFCard: View {
    let pdf: PDFItem

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Color.clear
                .aspectRatio(3 / 4, contentMode: .fit)
                .overlay {
                    ThumbnailView(id: pdf.id, version: pdf.importedAt, pdfFileName: pdf.fileName, placeholderSymbol: "doc.richtext")
                }
                .clipShape(.rect(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8).strokeBorder(.separator, lineWidth: 0.5)
                }
            Text(pdf.title)
                .font(.subheadline.weight(.medium))
                .lineLimit(2)
        }
        .contentShape(.rect)
        .hoverEffect(.highlight)
    }
}

/// The dashed "New notebook" and "Import PDF" tiles at the end of each grid.
struct AddTile: View {
    let title: String
    let systemImage: String
    let aspectRatio: CGFloat
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                Color.clear
                    .aspectRatio(aspectRatio, contentMode: .fit)
                    .overlay {
                        Image(systemName: systemImage)
                            .font(.title)
                            .foregroundStyle(.secondary)
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [6, 4]))
                            .foregroundStyle(.tertiary)
                    }
                Text(title)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
    }
}

/// Loads a cached thumbnail off the main thread. It reloads whenever `id`
/// or `version` changes, which happens after each notebook save.
struct ThumbnailView: View {
    let id: UUID
    let version: Date
    var pdfFileName: String? = nil
    let placeholderSymbol: String

    private struct LoadKey: Hashable {
        let id: UUID
        let version: Date
    }

    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Color(uiColor: .secondarySystemBackground)
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: placeholderSymbol)
                    .font(.largeTitle)
                    .foregroundStyle(.tertiary)
            }
        }
        .task(id: LoadKey(id: id, version: version)) {
            let id = id
            let fileName = pdfFileName
            let data = await Task.detached { Thumbnails.loadData(id: id, pdfFileName: fileName) }.value
            image = data.flatMap { UIImage(data: $0) }
        }
    }
}
