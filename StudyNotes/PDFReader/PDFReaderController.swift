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
    /// This open PDF, for the study pal.
    let palPageID = UUID()
    /// Circle something for the study pal.
    private let askLasso = AskLassoView()
    /// Where things the study pal added beside the same circled area went,
    /// so the next one goes somewhere else.
    private var palPlaced: [CGRect] = []
    private var palPlacedNear: CGRect?
    /// The handwritten words she was last shown on each page, so she can
    /// erase or move them.
    private var palHandwriting: [Int: PalHandwriting] = [:]

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
        askLasso.onSelection = { [weak self] rect in self?.finishCircle(in: rect) }
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

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        PalWorkspace.shared.register(self)
        // Opened by the study pal at a page: go there once the reader has
        // put you back where you were.
        if let request = PalNavigator.shared.pending(for: item.id), let index = request.pageIndex {
            PalNavigator.shared.done(request)
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(400))
                self?.goToPage(index)
            }
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        saveNow()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if askLasso.isActive { Pal.shared.stopCircling() }
        PalWorkspace.shared.unregister(self)
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

    /// Circling for the study pal: the next loop drawn on a page goes to her.
    private func setCircling(_ on: Bool) {
        if on { view.endEditing(true) }
        askLasso.isActive = on
    }

    /// A loop was drawn: what's inside it goes to the study pal, with the
    /// page it's on and where on it, in page points.
    private func finishCircle(in rect: CGRect) {
        askLasso.isActive = false
        let center = view.convert(CGPoint(x: rect.midX, y: rect.midY), to: pdfView)
        guard let image = askLasso.snapshot(of: view, rect: rect),
              let jpeg = image.jpegData(compressionQuality: 0.85),
              let page = pdfView.page(for: center, nearest: true) else {
            Pal.shared.stopCircling()
            return
        }
        let pageIndex = document.index(for: page)
        let area: CGRect
        if let overlay = overlays[pageIndex] {
            area = view.convert(rect, to: overlay)
        } else {
            // From PDF space (y grows up) to page points from the top-left.
            let box = page.bounds(for: .cropBox)
            let pdfRect = pdfView.convert(view.convert(rect, to: pdfView), to: page)
            area = CGRect(x: pdfRect.minX - box.minX, y: box.maxY - pdfRect.maxY, width: pdfRect.width, height: pdfRect.height)
        }
        Pal.shared.circled(PalCircle(pageID: palPageID, pageIndex: pageIndex, rect: area, image: jpeg))
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

    /// Goes up with every change to the PDF's notes and ink, for `palVersion`.
    private var contentVersion = 0

    private func scheduleSave() {
        contentVersion += 1
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

    /// Turns a text selection into one highlight per page, snapped to lines,
    /// in the color picked in the toolbar (or `color`).
    private func addHighlight(from selection: PDFSelection, color: HighlightColor? = nil) {
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
                color: color ?? editor.highlightColor,
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
        let hit = pdfView.hitTest(location, with: nil)
        if hit?.enclosingTextBox != nil || hit is UIControl { return }
        textBoxes.clearSelection()

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

// MARK: - The study pal

/// On a PDF, the study pal reads the pages, sees your ink and notes on
/// them, and can write, mark and highlight. The PDF file itself and your
/// own ink stay as they are.
extension PDFReaderController: PalPage {
    var palItemID: UUID { item.id }
    var palKind: PalPageKind { .pdf }
    var palItemTitle: String { item.title }
    var palWhere: String { "page \(editor.currentPageIndex + 1) of \(document.pageCount)" }
    /// The page in view counts too: turning to another page is a new page for her.
    var palVersion: Int { contentVersion &* 100_000 &+ editor.currentPageIndex }
    var palWindow: UIWindow? { view.window }
    var canAddImages: Bool { false }

    private func pageIndex(_ index: Int?) -> Int {
        min(max(index ?? editor.currentPageIndex, 0), max(document.pageCount - 1, 0))
    }

    private func pageSize(_ index: Int) -> CGSize {
        document.page(at: index)?.bounds(for: .cropBox).size ?? .zero
    }

    /// A page's ink: from its overlay when it's on screen, or as saved.
    private func ink(on index: Int) -> PKDrawing {
        if let overlay = overlays[index] { return overlay.canvasView.drawing }
        return inkRecord(for: index)?.drawingData.flatMap { try? PKDrawing(data: $0) } ?? PKDrawing()
    }

    func palSnapshot() -> PalSnapshot {
        let index = pageIndex(nil)
        let size = pageSize(index)
        let picture = render(page: index, area: nil)
        var text = "Page \(index + 1) of \(document.pageCount)."
        if let pageText = document.page(at: index)?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !pageText.isEmpty {
            text += "\n\n" + String(pageText.prefix(20_000))
        }
        let notes = palNotes(pageIndex: index)
        if !notes.isEmpty { text += "\n\nTheir typed notes on this page:\n" + notes }
        let selection = pdfView.currentSelection?.string
        return PalSnapshot(image: picture?.image, area: CGRect(origin: .zero, size: size), imageSize: picture?.size ?? .zero, text: text, selection: selection)
    }

    /// The title, the page in view and the two on each side of it, and the
    /// typed notes on the page in view.
    func palVocabularyText() -> String {
        let index = pageIndex(nil)
        let last = document.pageCount - 1
        var parts = [item.title]
        if last >= 0 {
            for page in max(index - 2, 0)...min(index + 2, last) {
                if let text = document.page(at: page)?.string { parts.append(String(text.prefix(12_000))) }
            }
        }
        parts.append(palNotes(pageIndex: index))
        return parts.joined(separator: "\n")
    }

    func palLook(at area: CGRect?, pageIndex index: Int?, labelHandwriting: Bool) -> (image: Data, area: CGRect)? {
        let index = pageIndex(index)
        let full = CGRect(origin: .zero, size: pageSize(index))
        let area = (area ?? full).intersection(full)
        guard !area.isNull else { return nil }
        let labels = labelHandwriting ? handwriting(on: index).list(ink(on: index), within: area) : []
        guard let picture = render(page: index, area: area, labels: labels) else { return nil }
        return (picture.image, area)
    }

    private func handwriting(on index: Int) -> PalHandwriting {
        if let existing = palHandwriting[index] { return existing }
        let made = PalHandwriting()
        palHandwriting[index] = made
        return made
    }

    func palEraseHandwriting(ids: [String], region: CGRect?, pageIndex index: Int?) -> (result: String, isError: Bool) {
        let index = pageIndex(index)
        guard let overlay = overlays[index] else { return ("Page \(index + 1) isn't on screen. Go to it first (go_to_page).", true) }
        return handwriting(on: index).erase(ids: ids, region: region, on: overlay.canvasView)
    }

    func palMoveHandwriting(ids: [String], to origin: CGPoint, pageIndex index: Int?) -> (result: String, isError: Bool) {
        let index = pageIndex(index)
        guard let overlay = overlays[index] else { return ("Page \(index + 1) isn't on screen. Go to it first (go_to_page).", true) }
        return handwriting(on: index).move(ids: ids, to: origin, on: overlay.canvasView)
    }

    func palShowArea(_ area: CGRect?, pageIndex index: Int?) -> String? {
        let index = pageIndex(index)
        guard let page = document.page(at: index) else { return "There's no page \(index + 1)." }
        if let area {
            // From page points (top-left) to PDF space (y grows up).
            let box = page.bounds(for: .cropBox)
            let rect = CGRect(x: box.minX + area.minX, y: box.maxY - area.maxY, width: area.width, height: area.height)
            pdfView.go(to: rect, on: page)
        } else {
            goToPage(index)
        }
        return nil
    }

    func palUndo() -> Bool { undo() }
    func palRedo() -> Bool { redo() }

    func palRemoveHighlights(_ text: String, pageIndex index: Int?) -> String? {
        let index = pageIndex(index)
        let wanted = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches = (item.highlights ?? []).filter { highlight in
            !highlight.isDeleted && highlight.pageIndex == index
                && (wanted.isEmpty || highlight.text.range(of: wanted, options: [.caseInsensitive, .diacriticInsensitive]) != nil)
        }
        guard !matches.isEmpty else { return "No highlight with that text on page \(index + 1)." }
        removeHighlights(matches.map(\.id))
        return nil
    }

    /// A picture of an area of a page (page points from its top-left; nil
    /// for all of it) with the PDF, your highlights, your ink and your typed
    /// notes, as sharp as she can read it, and numbered boxes on `labels`.
    private func render(page index: Int, area: CGRect?, labels: [PalInkGroup] = []) -> (image: Data, size: CGSize)? {
        guard let page = document.page(at: index) else { return nil }
        let box = page.bounds(for: .cropBox)
        let area = area ?? CGRect(origin: .zero, size: box.size)
        guard area.width > 0, area.height > 0 else { return nil }
        let scale = min(PalRender.maxPixels / max(area.width, area.height), 6)
        let size = CGSize(width: (area.width * scale).rounded(), height: (area.height * scale).rounded())
        let drawing = ink(on: index)
        var inkImage: UIImage?
        if drawing.strokes.contains(where: { $0.renderBounds.intersects(area) }) {
            UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
                inkImage = drawing.image(from: area, scale: scale)
            }
        }
        let notes = (item.textBoxes ?? []).filter { !$0.isDeleted && $0.pageIndex == index && !$0.plainText.isEmpty }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let picture = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            let cg = context.cgContext
            // PDF space has y growing up, from the page's bottom-left.
            cg.saveGState()
            cg.translateBy(x: -area.minX * scale, y: (box.height - area.minY) * scale)
            cg.scaleBy(x: scale, y: -scale)
            page.draw(with: .cropBox, to: cg)
            cg.restoreGState()
            // Ink and notes are in page points from the top-left.
            cg.saveGState()
            cg.scaleBy(x: scale, y: scale)
            cg.translateBy(x: -area.minX, y: -area.minY)
            inkImage?.draw(in: area)
            for note in notes {
                let frame = CGRect(x: note.x, y: note.y, width: note.width, height: textBoxes.height(of: note.id))
                guard frame.intersects(area) else { continue }
                let text = note.richText.flatMap(RichText.decode) ?? NSAttributedString(string: note.plainText, attributes: [.font: TextBoxView.defaultFont])
                text.draw(with: frame.insetBy(dx: 6, dy: 8), options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
            }
            cg.restoreGState()
            PalRender.drawLabels(labels, area: area, scale: scale, in: cg)
        }
        guard let data = picture.jpegData(compressionQuality: 0.8) else { return nil }
        return (data, size)
    }

    /// The lines of the PDF's own text on a page, in page points from the
    /// top-left, so nothing she adds covers them.
    private func textLines(on index: Int) -> [CGRect] {
        guard let page = document.page(at: index) else { return [] }
        let box = page.bounds(for: .cropBox)
        guard let all = page.selection(for: box) else { return [] }
        return all.selectionsByLine().map { line in
            let rect = line.bounds(for: page)
            return CGRect(x: rect.minX - box.minX, y: box.maxY - rect.maxY, width: rect.width, height: rect.height)
        }
    }

    func palStartCircling() { setCircling(true) }
    func palStopCircling() { setCircling(false) }

    func palItems(pageIndex index: Int?) -> String {
        let index = pageIndex(index)
        let size = pageSize(index)
        let notes: [[String: Any]] = (item.textBoxes ?? [])
            .filter { !$0.isDeleted && $0.pageIndex == index }
            .sorted { ($0.y, $0.x) < ($1.y, $1.x) }
            .map { box in
                [
                    "id": box.id.uuidString,
                    "kind": "text",
                    "x": box.x.rounded(),
                    "y": box.y.rounded(),
                    "width": box.width.rounded(),
                    "height": textBoxes.height(of: box.id).rounded(),
                    "text": String(box.plainText.prefix(400)),
                ] as [String: Any]
            }
        let words = handwriting(on: index).list(ink(on: index), within: nil).map { word -> [String: Any] in
            ["id": word.id, "line": word.line, "x": word.rect.minX.rounded(), "y": word.rect.minY.rounded(), "width": word.rect.width.rounded(), "height": word.rect.height.rounded()]
        }
        let highlights = (item.highlights ?? []).filter { !$0.isDeleted && $0.pageIndex == index }.map { highlight -> [String: Any] in
            ["text": String(highlight.text.prefix(200)), "color": highlight.color.rawValue]
        }
        let description: [String: Any] = [
            "coordinates": "Points on PDF page \(index + 1), from its top-left corner. x grows to the right, y grows down.",
            "page_size": ["width": size.width.rounded(), "height": size.height.rounded()],
            "items": notes,
            "handwriting": words,
            "highlights": highlights,
            "note": "Items are the student's typed notes. Handwriting is listed word by word with ids for erase_handwriting and move_handwriting; use look_at with label_handwriting to see which is which. The PDF's own text can't be changed, and pictures can't be added to a PDF.",
        ]
        return PalJSON.string(description)
    }

    func palNotes(pageIndex index: Int?) -> String {
        let index = pageIndex(index)
        return (item.textBoxes ?? [])
            .filter { !$0.isDeleted && $0.pageIndex == index && !$0.plainText.isEmpty }
            .sorted { ($0.y, $0.x) < ($1.y, $1.x) }
            .map(\.plainText)
            .joined(separator: "\n\n")
    }

    /// Where to put something new on a page, as its top-left corner: as
    /// close as it can to just right of what was circled (or the top of
    /// the page), covering none of the PDF's text, the ink or the notes.
    private func freeSpot(for size: CGSize, on index: Int, near: CGRect?) -> CGPoint {
        if near != palPlacedNear {
            palPlacedNear = near
            palPlaced = []
        }
        let page = CGRect(origin: .zero, size: pageSize(index))
        var taken = textLines(on: index)
        taken += ink(on: index).strokes.map(\.renderBounds)
        taken += (item.textBoxes ?? []).filter { !$0.isDeleted && $0.pageIndex == index }
            .map { CGRect(x: $0.x, y: $0.y, width: $0.width, height: textBoxes.height(of: $0.id)) }
        taken += palPlaced
        let preferred = near.map { CGPoint(x: $0.maxX + 12, y: $0.minY) } ?? CGPoint(x: 40, y: 60)
        let spot = PalSpot.find(for: size, preferred: preferred, visible: page, taken: taken, below: page.maxY - size.height - 8)
        let kept = clamped(spot, size: size, on: index)
        palPlaced.append(CGRect(origin: kept, size: size))
        return kept
    }

    func palAddText(_ text: String, at origin: CGPoint?, in place: PalPlace) -> UUID? {
        let index = pageIndex(place.pageIndex)
        guard overlays[index] != nil else { return nil }
        let width: CGFloat = 260
        let measured = (text as NSString).boundingRect(
            with: CGSize(width: width - 16, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: TextBoxView.defaultFont],
            context: nil
        )
        let size = CGSize(width: width, height: ceil(measured.height) + 24)
        let spot = origin.map { clamped($0, size: size, on: index) } ?? freeSpot(for: size, on: index, near: place.near)
        return textBoxes.insertBox(at: spot, width: width, text: text, pageIndex: index)
    }

    func palAddImage(_ image: PreparedImage, in place: PalPlace) -> UUID? { nil }

    func palWrite(_ text: String, at origin: CGPoint?, letterHeight: CGFloat?, color: UIColor?, in place: PalPlace) -> (result: String, isError: Bool) {
        let index = pageIndex(place.pageIndex)
        guard let overlay = overlays[index] else {
            return ("Page \(index + 1) isn't on screen. Ask them to go to it, or write on the page they're on.", true)
        }
        let page = pageSize(index)
        // Without handwriting to match, a size that suits the page.
        let style = PalInkReading.style(of: overlay.canvasView.drawing, fallbackHeight: max(page.height / 80, 7))
        let height = min(max(letterHeight ?? style.letterHeight, 5), 80)
        let maxWidth = max(min(page.width * 0.4, height * 40), height * 8)
        let size = PalInk.measure(text, letterHeight: height, maxWidth: maxWidth)
        let spot = origin ?? freeSpot(for: CGSize(width: size.width + 6, height: size.height + 6), on: index, near: place.near)
        let writing = PalInk.handwriting(
            text,
            origin: spot,
            letterHeight: height,
            maxWidth: maxWidth,
            color: color ?? style.color,
            penWidth: style.penWidth * height / max(style.letterHeight, 1),
            seed: UInt64.random(in: 1...UInt64.max)
        )
        guard !writing.strokes.isEmpty else { return ("There was nothing to write.", true) }
        PalInkEditing.add(writing.strokes, to: overlay.canvasView, actionName: "Writing")
        let box = writing.bounds
        return ("Wrote it by hand on page \(index + 1) at x \(Int(box.minX)), y \(Int(box.minY)), width \(Int(box.width)), height \(Int(box.height)).", false)
    }

    func palMark(_ mark: PalInk.Mark, around rect: CGRect, to: CGPoint?, color: UIColor?, in place: PalPlace) -> String? {
        let index = pageIndex(place.pageIndex)
        guard let overlay = overlays[index] else {
            return "Page \(index + 1) isn't on screen. Ask them to go to it."
        }
        let style = PalInkReading.style(of: overlay.canvasView.drawing, fallbackHeight: 10)
        let strokes = PalInk.mark(mark, around: rect, to: to, color: color ?? PalColor.red, penWidth: max(style.penWidth, 1.6), seed: UInt64.random(in: 1...UInt64.max))
        guard !strokes.isEmpty else { return "Couldn't draw that mark." }
        PalInkEditing.add(strokes, to: overlay.canvasView, actionName: "Mark")
        return nil
    }

    func palReadPages(_ pages: ClosedRange<Int>) -> String? {
        let last = document.pageCount - 1
        guard last >= 0 else { return "This PDF has no pages." }
        let lower = max(pages.lowerBound, 0)
        guard lower <= last else { return "This PDF has only \(document.pageCount) pages." }
        let range = lower...min(max(pages.upperBound, lower), last)
        return range.map { index in
            let text = document.page(at: index)?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return "Page \(index + 1):\n" + (text.isEmpty ? "(no text: it may be a scan or a picture; use look_at to see it)" : String(text.prefix(12_000)))
        }
        .joined(separator: "\n\n")
    }

    func palHighlight(_ text: String, pageIndex index: Int?, color: HighlightColor) -> String? {
        let index = pageIndex(index)
        guard let page = document.page(at: index) else { return "There's no page \(index + 1)." }
        // Only this page is searched, so a long PDF doesn't hold things up.
        let pageText = (page.string ?? "") as NSString
        let range = pageText.range(of: text, options: [.caseInsensitive, .diacriticInsensitive])
        guard range.location != NSNotFound, let hit = page.selection(for: range) else {
            return "Couldn't find that text on page \(index + 1). Give it exactly as it appears there, or a shorter part of it."
        }
        addHighlight(from: hit, color: color)
        return nil
    }

    func palMoveItem(_ id: UUID, to origin: CGPoint) -> String? {
        guard let box = textBoxes.box(id), let index = box.pageIndex else { return Self.unknownNote }
        let origin = clamped(origin, size: CGSize(width: box.width, height: 40), on: index)
        UIView.animate(withDuration: 0.35, delay: 0, options: [.curveEaseInOut]) {
            _ = self.textBoxes.setBoxFrame(id: id, origin: origin)
        }
        return nil
    }

    func palResizeItem(_ id: UUID, width: CGFloat) -> String? {
        guard let box = textBoxes.box(id), let index = box.pageIndex else { return Self.unknownNote }
        let width = min(width, max(pageSize(index).width - box.x, 80))
        UIView.animate(withDuration: 0.35, delay: 0, options: [.curveEaseInOut]) {
            _ = self.textBoxes.setBoxFrame(id: id, width: width)
        }
        return nil
    }

    func palEditText(_ id: UUID, text: String) -> String? {
        textBoxes.replaceText(id: id, with: text) ? nil : Self.unknownNote
    }

    func palDeleteItem(_ id: UUID) -> String? {
        guard textBoxes.box(id) != nil else { return Self.unknownNote }
        textBoxes.removeBox(id: id, undoable: true)
        return nil
    }

    private static let unknownNote = "No typed note with that id. Call get_page_items for the current ids."

    /// Keeps something on its page.
    private func clamped(_ origin: CGPoint, size: CGSize, on index: Int) -> CGPoint {
        let page = pageSize(index)
        guard page.width > 0, page.height > 0 else { return origin }
        return CGPoint(
            x: max(4, min(origin.x, page.width - size.width - 4)),
            y: max(4, min(origin.y, page.height - size.height - 4))
        )
    }
}
