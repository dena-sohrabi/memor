import PDFKit
import PencilKit
import SwiftData
import UIKit

/// The PDF reader: continuous scrolling, resume where you left off,
/// highlights, Pencil ink and typed notes.
///
/// The PDF file is never written to. Highlights become `PDFAnnotation`s
/// that are rebuilt from the database each time the PDF opens. Ink and text
/// notes live in a per-page overlay (`PageOverlayView`).
final class PDFReaderController: UIViewController {
    let document: PDFDocument
    let item: PDFItem
    let editor: PDFEditor
    let modelContext: ModelContext

    private let pdfView = StudyPDFView()
    private let thumbnailView = PDFThumbnailView()
    private var thumbnailWidth: NSLayoutConstraint?
    private let toolPicker = PKToolPicker()
    private lazy var editMenu = UIEditMenuInteraction(delegate: self)
    private lazy var highlightPan = UIPanGestureRecognizer(target: self, action: #selector(handleHighlightPan(_:)))
    private lazy var tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))

    private var tool: PDFTool = .select
    private var overlays: [Int: PageOverlayView] = [:]
    private var dirtyInkPages: Set<Int> = []
    private var highlightAnnotations: [UUID: [PDFAnnotation]] = [:]
    private var menuHighlightID: UUID?
    private var panStart: (page: PDFPage, point: CGPoint)?
    private var defaultScrollTouchTypes: [NSNumber]?
    private var didRestorePosition = false
    private let saveDebouncer = Debouncer()
    private let positionDebouncer = Debouncer()
    private var eraserReturn: EraserAutoReturn?
    private var undoTaps: UndoTapGestures?
    /// Gets a picture of the area circled with the Ask tool.
    var onAskSelection: ((UIImage) -> Void)?
    private let askLasso = AskLassoView()

    private lazy var textBoxes = TextBoxCoordinator(modelContext: modelContext, hooks: .init(
        undoManager: { [weak self] in self?.undoManager },
        attach: { [weak self] box in box.pdf = self?.item },
        lookup: { [weak self] id in self?.item.textBoxes?.first { $0.id == id && !$0.isDeleted } },
        container: { [weak self] box in
            guard let pageIndex = box.pageIndex else { return nil }
            return self?.overlays[pageIndex]?.textLayer
        },
        contentChanged: { [weak self] in self?.scheduleSave() },
        editingEnded: { [weak self] in self?.restoreFocusSoon() }
    ))

    init(document: PDFDocument, item: PDFItem, editor: PDFEditor, modelContext: ModelContext) {
        self.document = document
        self.item = item
        self.editor = editor
        self.modelContext = modelContext
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var canBecomeFirstResponder: Bool { true }

    // MARK: Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .secondarySystemBackground

        // The overlay provider has to be set before the document.
        pdfView.pageOverlayViewProvider = self
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.autoScales = true
        pdfView.pageShadowsEnabled = true
        pdfView.backgroundColor = .secondarySystemBackground
        pdfView.document = document
        pdfView.onHighlightSelection = { [weak self] in self?.highlightCurrentSelection() }
        pdfView.translatesAutoresizingMaskIntoConstraints = false

        thumbnailView.pdfView = pdfView
        thumbnailView.layoutMode = .vertical
        thumbnailView.thumbnailSize = CGSize(width: 64, height: 84)
        thumbnailView.backgroundColor = .secondarySystemBackground
        thumbnailView.isHidden = true
        thumbnailView.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(thumbnailView)
        view.addSubview(pdfView)
        let width = thumbnailView.widthAnchor.constraint(equalToConstant: 0)
        thumbnailWidth = width
        NSLayoutConstraint.activate([
            thumbnailView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            thumbnailView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            thumbnailView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            width,
            pdfView.leadingAnchor.constraint(equalTo: thumbnailView.trailingAnchor),
            pdfView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            pdfView.topAnchor.constraint(equalTo: view.topAnchor),
            pdfView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        for highlight in item.highlights ?? [] {
            addAnnotations(for: highlight)
        }

        // Highlighter: swipe the Pencil across text. Fingers keep scrolling.
        highlightPan.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.pencil.rawValue)]
        highlightPan.isEnabled = false
        highlightPan.delegate = self
        pdfView.addGestureRecognizer(highlightPan)

        tap.delegate = self
        pdfView.addGestureRecognizer(tap)
        pdfView.addInteraction(editMenu)

        eraserReturn = EraserAutoReturn(toolPicker: toolPicker)
        undoTaps = UndoTapGestures(
            on: pdfView,
            toastHost: view,
            undo: { [weak self] in self?.undo() ?? false },
            redo: { [weak self] in self?.redo() ?? false }
        )

        askLasso.frame = view.bounds
        askLasso.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        askLasso.onSelection = { [weak self] rect in self?.finishAsk(in: rect) }
        view.addSubview(askLasso)

        NotificationCenter.default.addObserver(self, selector: #selector(pageChanged), name: .PDFViewPageChanged, object: pdfView)
        NotificationCenter.default.addObserver(self, selector: #selector(scaleChanged), name: .PDFViewScaleChanged, object: pdfView)

        editor.pageCount = document.pageCount
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard !didRestorePosition, pdfView.bounds.height > 0 else { return }
        didRestorePosition = true
        // Wait a turn so PDFView has finished its own layout.
        Task { [weak self] in self?.restorePosition() }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        saveNow()
    }

    // MARK: Toolbar actions

    func apply(tool newTool: PDFTool) {
        tool = newTool
        let inking = newTool == .ink
        pdfView.isInMarkupMode = inking
        highlightPan.isEnabled = newTool == .highlight
        tap.isEnabled = !inking
        for overlay in overlays.values {
            overlay.inkEnabled = inking
        }
        // While highlighting, the Pencil highlights and only fingers scroll.
        if let scrollView = pdfView.firstSubview(ofType: UIScrollView.self) {
            if defaultScrollTouchTypes == nil {
                defaultScrollTouchTypes = scrollView.panGestureRecognizer.allowedTouchTypes
            }
            if newTool == .highlight {
                scrollView.panGestureRecognizer.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
            } else if let defaultScrollTouchTypes {
                scrollView.panGestureRecognizer.allowedTouchTypes = defaultScrollTouchTypes
            }
        }
        if newTool != .select { pdfView.clearSelection() }
        if newTool != .text { view.endEditing(true) }
        if inking {
            becomeFirstResponder()
            toolPicker.setVisible(true, forFirstResponder: self)
        } else {
            toolPicker.setVisible(false, forFirstResponder: self)
        }
    }

    /// The Ask tool: circle part of a page to ask Claude about it.
    func setAskMode(_ on: Bool) {
        if on { view.endEditing(true) }
        askLasso.isActive = on
    }

    private func finishAsk(in rect: CGRect) {
        guard let image = askLasso.snapshot(of: view, rect: rect) else { return }
        askLasso.isActive = false
        onAskSelection?(image)
    }

    func setPageSidebarVisible(_ visible: Bool) {
        thumbnailView.isHidden = !visible
        thumbnailWidth?.constant = visible ? 96 : 0
        UIView.animate(withDuration: 0.25) { self.view.layoutIfNeeded() }
    }

    func goToPage(_ index: Int) {
        guard document.pageCount > 0,
              let page = document.page(at: min(max(index, 0), document.pageCount - 1)) else { return }
        pdfView.go(to: page)
    }

    /// Returns whether there was anything to undo.
    @discardableResult
    func undo() -> Bool {
        let manager = textBoxes.editingBox?.textView.undoManager ?? undoManager
        guard let manager, manager.canUndo else { return false }
        manager.undo()
        return true
    }

    /// Returns whether there was anything to redo.
    @discardableResult
    func redo() -> Bool {
        let manager = textBoxes.editingBox?.textView.undoManager ?? undoManager
        guard let manager, manager.canRedo else { return false }
        manager.redo()
        return true
    }

    private func restoreFocusSoon() {
        Task { [weak self] in
            guard let self, self.tool == .ink, self.view.window != nil, self.textBoxes.editingBox == nil else { return }
            self.becomeFirstResponder()
        }
    }

    // MARK: Reading position

    private func restorePosition() {
        defer {
            updatePageIndicator()
            updateTextSharpness()
        }
        guard let position = item.readingPosition,
              let page = document.page(at: position.pageIndex) else { return }
        if abs(position.scale - pdfView.scaleFactorForSizeToFit) > 0.01 {
            pdfView.scaleFactor = position.scale
        }
        pdfView.go(to: PDFDestination(page: page, at: CGPoint(x: position.x, y: position.y)))
    }

    private func currentPosition() -> ReadingPosition? {
        let topLeft = CGPoint(x: pdfView.bounds.minX + 1, y: pdfView.bounds.minY + pdfView.safeAreaInsets.top + 1)
        guard let page = pdfView.page(for: topLeft, nearest: true) else { return nil }
        let point = pdfView.convert(topLeft, to: page)
        return ReadingPosition(pageIndex: document.index(for: page), x: point.x, y: point.y, scale: pdfView.scaleFactor)
    }

    @objc private func pageChanged() {
        updatePageIndicator()
        schedulePositionSave()
    }

    @objc private func scaleChanged() {
        updateTextSharpness()
        schedulePositionSave()
    }

    private func updateTextSharpness() {
        textBoxes.renderScale = TextBoxCoordinator.scale(forZoom: pdfView.scaleFactor, displayScale: traitCollection.displayScale)
    }

    private func updatePageIndicator() {
        if let page = pdfView.currentPage {
            editor.currentPageIndex = document.index(for: page)
        }
    }

    private func schedulePositionSave() {
        positionDebouncer.schedule(after: .milliseconds(600)) { [weak self] in self?.savePosition() }
    }

    private func savePosition() {
        guard didRestorePosition, isModelAlive, let position = currentPosition() else { return }
        item.readingPosition = position
        try? modelContext.save()
    }

    // MARK: Saving

    private var isModelAlive: Bool {
        item.modelContext != nil && !item.isDeleted
    }

    private func scheduleSave() {
        saveDebouncer.schedule { [weak self] in self?.save() }
    }

    private func save() {
        guard isModelAlive else { return }
        for pageIndex in dirtyInkPages {
            if let overlay = overlays[pageIndex] { writeInk(from: overlay) }
        }
        dirtyInkPages.removeAll()
        item.modifiedAt = .now
        try? modelContext.save()
    }

    func saveNow() {
        saveDebouncer.flush()
        positionDebouncer.cancel()
        savePosition()
    }

    // MARK: Ink

    private func inkRecord(for pageIndex: Int) -> PageInk? {
        item.pageInk?.first { $0.pageIndex == pageIndex && !$0.isDeleted }
    }

    private func writeInk(from overlay: PageOverlayView) {
        let drawing = overlay.canvasView.drawing
        if let record = inkRecord(for: overlay.pageIndex) {
            if drawing.strokes.isEmpty {
                modelContext.delete(record)
            } else {
                record.drawingData = drawing.dataRepresentation()
            }
        } else if !drawing.strokes.isEmpty {
            let record = PageInk(pageIndex: overlay.pageIndex, drawingData: drawing.dataRepresentation())
            modelContext.insert(record)
            record.pdf = item
        }
    }

    // MARK: Highlights

    private func highlightCurrentSelection() {
        guard let selection = pdfView.currentSelection else { return }
        addHighlight(from: selection)
        pdfView.clearSelection()
    }

    /// Turns a text selection into one highlight per page, snapped to lines.
    private func addHighlight(from selection: PDFSelection) {
        var rectsByPage: [Int: [CGRect]] = [:]
        var textByPage: [Int: [String]] = [:]
        for line in selection.selectionsByLine() {
            for page in line.pages {
                let rect = line.bounds(for: page)
                guard rect.width > 0.5, rect.height > 0.5 else { continue }
                let pageIndex = document.index(for: page)
                rectsByPage[pageIndex, default: []].append(rect)
                if let text = line.string { textByPage[pageIndex, default: []].append(text) }
            }
        }
        guard !rectsByPage.isEmpty else { return }

        var createdIDs: [UUID] = []
        for (pageIndex, rects) in rectsByPage.sorted(by: { $0.key < $1.key }) {
            let highlight = Highlight(
                pageIndex: pageIndex,
                color: editor.highlightColor,
                rects: rects.map(CodableRect.init),
                text: (textByPage[pageIndex] ?? []).joined(separator: " ")
            )
            modelContext.insert(highlight)
            highlight.pdf = item
            addAnnotations(for: highlight)
            createdIDs.append(highlight.id)
        }
        registerUndoRemovingHighlights(createdIDs)
        scheduleSave()
    }

    private func addAnnotations(for highlight: Highlight) {
        guard let page = document.page(at: highlight.pageIndex) else { return }
        let color = highlight.color.uiColor
        let annotations = highlight.rects.map { rect in
            let annotation = PDFAnnotation(bounds: rect.cgRect, forType: .highlight, withProperties: nil)
            annotation.color = color
            annotation.userName = highlight.id.uuidString
            page.addAnnotation(annotation)
            return annotation
        }
        highlightAnnotations[highlight.id] = annotations
    }

    private func highlightModel(id: UUID) -> Highlight? {
        item.highlights?.first { $0.id == id && !$0.isDeleted }
    }

    private func removeHighlights(_ ids: [UUID]) {
        var snapshots: [HighlightSnapshot] = []
        for id in ids {
            guard let highlight = highlightModel(id: id) else { continue }
            snapshots.append(HighlightSnapshot(highlight))
            for annotation in highlightAnnotations.removeValue(forKey: id) ?? [] {
                annotation.page?.removeAnnotation(annotation)
            }
            modelContext.delete(highlight)
        }
        guard !snapshots.isEmpty else { return }
        undoManager?.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated { target.restoreHighlights(snapshots) }
        }
        scheduleSave()
    }

    private func restoreHighlights(_ snapshots: [HighlightSnapshot]) {
        for snapshot in snapshots {
            let highlight = snapshot.makeModel()
            modelContext.insert(highlight)
            highlight.pdf = item
            addAnnotations(for: highlight)
        }
        registerUndoRemovingHighlights(snapshots.map(\.id))
        scheduleSave()
    }

    private func registerUndoRemovingHighlights(_ ids: [UUID]) {
        undoManager?.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated { target.removeHighlights(ids) }
        }
    }

    private func setColor(_ color: HighlightColor, forHighlight id: UUID) {
        guard let highlight = highlightModel(id: id) else { return }
        let previous = highlight.color
        highlight.color = color
        for annotation in highlightAnnotations[id] ?? [] {
            annotation.color = color.uiColor
        }
        undoManager?.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated { target.setColor(previous, forHighlight: id) }
        }
        scheduleSave()
    }

    // MARK: Gestures

    @objc private func handleHighlightPan(_ gesture: UIPanGestureRecognizer) {
        let location = gesture.location(in: pdfView)
        switch gesture.state {
        case .began:
            // The pan starts after a little movement; use where the Pencil first landed.
            let translation = gesture.translation(in: pdfView)
            let start = CGPoint(x: location.x - translation.x, y: location.y - translation.y)
            guard let page = pdfView.page(for: start, nearest: true) else { return }
            panStart = (page, pdfView.convert(start, to: page))
            updateHighlightPreview(to: location)
        case .changed:
            updateHighlightPreview(to: location)
        case .ended:
            let selection = selectionForPan(to: location)
            pdfView.highlightedSelections = nil
            panStart = nil
            if let selection { addHighlight(from: selection) }
        default:
            pdfView.highlightedSelections = nil
            panStart = nil
        }
    }

    private func selectionForPan(to location: CGPoint) -> PDFSelection? {
        guard let start = panStart, let page = pdfView.page(for: location, nearest: true) else { return nil }
        let end = pdfView.convert(location, to: page)
        guard let selection = document.selection(from: start.page, at: start.point, to: page, at: end),
              let text = selection.string,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return selection
    }

    private func updateHighlightPreview(to location: CGPoint) {
        guard let selection = selectionForPan(to: location) else {
            pdfView.highlightedSelections = nil
            return
        }
        selection.color = editor.highlightColor.uiColor
        pdfView.highlightedSelections = [selection]
    }

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        let location = gesture.location(in: pdfView)
        if pdfView.hitTest(location, with: nil)?.enclosingTextBox != nil { return }

        switch tool {
        case .text:
            // First tap on empty space just finishes the note being edited.
            if textBoxes.editingBox != nil {
                view.endEditing(true)
                return
            }
            guard let page = pdfView.page(for: location, nearest: false),
                  let overlay = overlays[document.index(for: page)] else { return }
            let point = pdfView.convert(location, to: overlay.textLayer)
            textBoxes.createBox(at: CGPoint(x: point.x - 8, y: point.y - 22), width: 220, pageIndex: overlay.pageIndex)
        case .select, .highlight:
            guard let page = pdfView.page(for: location, nearest: false) else { return }
            let pagePoint = pdfView.convert(location, to: page)
            guard let annotation = page.annotation(at: pagePoint),
                  let rawID = annotation.userName,
                  let id = UUID(uuidString: rawID),
                  highlightAnnotations[id] != nil else { return }
            menuHighlightID = id
            editMenu.presentEditMenu(with: UIEditMenuConfiguration(identifier: nil, sourcePoint: location))
        case .ink:
            break
        }
    }
}

// MARK: - Page overlays

extension PDFReaderController: @preconcurrency PDFPageOverlayViewProvider {
    func pdfView(_ view: PDFView, overlayViewFor page: PDFPage) -> UIView? {
        let pageIndex = document.index(for: page)
        if let existing = overlays[pageIndex] { return existing }

        let overlay = PageOverlayView(pageIndex: pageIndex)
        if let data = inkRecord(for: pageIndex)?.drawingData, let drawing = try? PKDrawing(data: data) {
            overlay.canvasView.drawing = drawing
        }
        // Set after loading, so loading doesn't count as an edit.
        overlay.canvasView.delegate = self
        overlay.canvasView.tool = toolPicker.selectedTool
        toolPicker.addObserver(overlay.canvasView)
        overlay.inkEnabled = tool == .ink
        overlays[pageIndex] = overlay

        for box in item.textBoxes ?? [] where box.pageIndex == pageIndex && !box.isDeleted {
            textBoxes.showView(for: box)
        }
        return overlay
    }

    func pdfView(_ pdfView: PDFView, willEndDisplayingOverlayView overlayView: UIView, for page: PDFPage) {
        guard let overlay = overlayView as? PageOverlayView else { return }
        if dirtyInkPages.remove(overlay.pageIndex) != nil, isModelAlive {
            writeInk(from: overlay)
            scheduleSave()
        }
        textBoxes.forgetViews(in: overlay.textLayer)
        toolPicker.removeObserver(overlay.canvasView)
        if overlays[overlay.pageIndex] === overlay {
            overlays[overlay.pageIndex] = nil
        }
    }
}

extension PDFReaderController: PKCanvasViewDelegate {
    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        guard let overlay = canvasView.superview as? PageOverlayView else { return }
        dirtyInkPages.insert(overlay.pageIndex)
        scheduleSave()
    }

    func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) {
        eraserReturn?.canvasDidEndUsingTool()
    }
}

// MARK: - Menus and gesture rules

extension PDFReaderController: UIEditMenuInteractionDelegate {
    /// The menu for a tapped highlight: color, copy, delete.
    func editMenuInteraction(_ interaction: UIEditMenuInteraction, menuFor configuration: UIEditMenuConfiguration, suggestedActions: [UIMenuElement]) -> UIMenu? {
        guard let id = menuHighlightID, let highlight = highlightModel(id: id) else { return nil }
        let current = highlight.color
        let text = highlight.text
        let colors = HighlightColor.allCases.map { color in
            UIAction(title: color.title, image: color.swatchImage, state: color == current ? .on : .off) { [weak self] _ in
                self?.setColor(color, forHighlight: id)
            }
        }
        let copy = UIAction(title: "Copy Text", image: UIImage(systemName: "doc.on.doc")) { _ in
            UIPasteboard.general.string = text
        }
        let delete = UIAction(title: "Delete Highlight", image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in
            self?.removeHighlights([id])
        }
        return UIMenu(children: [UIMenu(title: "Color", options: .displayInline, children: colors), copy, delete])
    }
}

extension PDFReaderController: UIGestureRecognizerDelegate {
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        // Our tap runs alongside PDFView's own taps (deselecting text etc.).
        gestureRecognizer === tap
    }
}
