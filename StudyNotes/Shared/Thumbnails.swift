import PDFKit
import PencilKit
import UIKit

enum Thumbnails {
    static let notebookSize = CGSize(width: 480, height: 360)

    /// Renders a notebook thumbnail and writes it to the cache.
    @MainActor
    static func writeNotebookThumbnail(
        id: UUID,
        drawing: PKDrawing,
        textBoxes: [(frame: CGRect, text: NSAttributedString)],
        images: [(frame: CGRect, image: UIImage)] = []
    ) {
        let image = renderNotebook(drawing: drawing, textBoxes: textBoxes, images: images)
        try? image.pngData()?.write(to: FileStore.thumbnailURL(for: id), options: .atomic)
    }

    /// The thumbnail of a new, empty page: dots only.
    @MainActor
    static func writeBlankNotebookThumbnail(id: UUID) {
        writeNotebookThumbnail(id: id, drawing: PKDrawing(), textBoxes: [])
    }

    @MainActor
    private static func renderNotebook(
        drawing: PKDrawing,
        textBoxes: [(frame: CGRect, text: NSAttributedString)],
        images: [(frame: CGRect, image: UIImage)]
    ) -> UIImage {
        var content = drawing.strokes.isEmpty ? CGRect.null : drawing.bounds
        for box in textBoxes {
            content = content.union(box.frame)
        }
        for image in images {
            content = content.union(image.frame)
        }
        let size = notebookSize
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: size, format: format)

        // The canvas area to show and its scale. A blank page shows its
        // dots at 100%.
        let frame: CGRect
        let scale: CGFloat
        if content.isNull || content.width <= 0 || content.height <= 0 {
            frame = CGRect(origin: .zero, size: size)
            scale = 1
        } else {
            frame = content.insetBy(dx: -32, dy: -32)
            // Fit everything, but never blow small content up past 100%.
            scale = min(size.width / frame.width, size.height / frame.height, 1)
        }
        var inkImage: UIImage?
        if !drawing.strokes.isEmpty {
            UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
                inkImage = drawing.image(from: frame, scale: scale * 2)
            }
        }

        return renderer.image { context in
            Paper.color.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            let cg = context.cgContext
            cg.translateBy(x: (size.width - frame.width * scale) / 2, y: (size.height - frame.height * scale) / 2)
            cg.scaleBy(x: scale, y: scale)
            cg.translateBy(x: -frame.minX, y: -frame.minY)

            // The whole thumbnail in canvas points (wider or taller than
            // `frame` when the content doesn't match its shape). Thumbnails
            // are shown at about half size, so dots are kept further apart
            // and a bit bigger than on the page.
            let visible = CGRect(
                x: frame.midX - size.width / scale / 2,
                y: frame.midY - size.height / scale / 2,
                width: size.width / scale,
                height: size.height / scale
            )
            let cell = DotGrid.cellSize(forZoom: scale, minimum: 20) / scale
            let radius = max(DotGrid.radius * scale, 1.2) / scale
            DotGrid.fill(in: cg, rect: visible, origin: .zero, cell: cell, radius: radius)

            // Same order as the page: images, then ink, then text.
            for image in images {
                image.image.draw(in: image.frame)
            }
            inkImage?.draw(in: frame)
            for box in textBoxes {
                box.text.draw(with: box.frame.insetBy(dx: 6, dy: 8), options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
            }
        }
    }

    /// PNG data for a cached thumbnail. If the cache was purged, PDF
    /// thumbnails are rebuilt from the file. Blocking: call it off the main
    /// thread.
    static func loadData(id: UUID, pdfFileName: String?) -> Data? {
        let url = FileStore.thumbnailURL(for: id)
        if let data = try? Data(contentsOf: url) { return data }
        guard let pdfFileName,
              let document = PDFDocument(url: FileStore.pdfURL(fileName: pdfFileName)),
              let page = document.page(at: 0) else { return nil }
        let data = page.thumbnail(of: PDFImporter.thumbnailSize, for: .cropBox).pngData()
        if let data { try? data.write(to: url, options: .atomic) }
        return data
    }
}
