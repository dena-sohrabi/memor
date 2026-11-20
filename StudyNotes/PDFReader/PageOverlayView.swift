import PDFKit
import PencilKit
import UIKit

/// PDFView that adds "Highlight" to the menu shown for selected text.
final class StudyPDFView: PDFView {
    var onHighlightSelection: (() -> Void)?

    override func buildMenu(with builder: any UIMenuBuilder) {
        super.buildMenu(with: builder)
        guard builder.system == .context,
              let text = currentSelection?.string,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              builder.menu(for: .standardEdit) != nil else { return }
        let highlight = UIAction(title: "Highlight", image: UIImage(systemName: "highlighter")) { [weak self] _ in
            self?.onHighlightSelection?()
        }
        builder.insertSibling(UIMenu(options: .displayInline, children: [highlight]), beforeMenu: .standardEdit)
    }
}

/// Sits on top of one PDF page: a transparent PencilKit canvas for ink and
/// a layer for typed notes. Its coordinates are page points with a top-left
/// origin, which is how ink and text notes are stored.
final class PageOverlayView: UIView {
    let pageIndex: Int
    let canvasView = PKCanvasView()
    let textLayer = PassthroughView()

    /// When off, touches outside text notes fall through to the page, so
    /// you can select text and highlight.
    var inkEnabled = false {
        didSet {
            canvasView.isUserInteractionEnabled = inkEnabled
            canvasView.drawingGestureRecognizer.isEnabled = inkEnabled
        }
    }

    init(pageIndex: Int) {
        self.pageIndex = pageIndex
        super.init(frame: .zero)
        backgroundColor = .clear
        isOpaque = false
        // PDF pages are white, so keep ink and notes in light colors.
        overrideUserInterfaceStyle = .light

        canvasView.backgroundColor = .clear
        canvasView.isOpaque = false
        // Fingers always scroll the PDF. Only the Pencil writes on it.
        canvasView.drawingPolicy = .pencilOnly
        canvasView.isScrollEnabled = false
        canvasView.minimumZoomScale = 1
        canvasView.maximumZoomScale = 1
        canvasView.contentInsetAdjustmentBehavior = .never
        canvasView.isUserInteractionEnabled = false
        canvasView.drawingGestureRecognizer.isEnabled = false
        addSubview(canvasView)
        addSubview(textLayer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layoutSubviews() {
        super.layoutSubviews()
        canvasView.frame = bounds
        canvasView.contentSize = bounds.size
        textLayer.frame = bounds
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        if let hit = textLayer.hitTest(convert(point, to: textLayer), with: event) {
            return hit
        }
        return inkEnabled ? super.hitTest(point, with: event) : nil
    }
}
