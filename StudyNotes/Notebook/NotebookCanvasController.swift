import PencilKit
import SwiftData
import UIKit

/// A `PKCanvasView` that keeps the image layer behind the ink and the
/// text-box layer on top, and reports typed characters, so typing on a
/// hardware keyboard with nothing focused starts a new text box.
final class NotebookCanvasView: PKCanvasView {
    weak var imageLayer: UIView?
    weak var textLayer: UIView?
    var onTypedCharacters: ((String) -> Bool)?

    override func layoutSubviews() {
        super.layoutSubviews()
        if let imageLayer, subviews.first !== imageLayer {
            sendSubviewToBack(imageLayer)
        }
        if let textLayer, subviews.last !== textLayer {
            bringSubviewToFront(textLayer)
        }
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses {
            guard let key = press.key, Self.isPlainTyping(key) else { continue }
            if onTypedCharacters?(key.characters) == true { return }
        }
        super.pressesBegan(presses, with: event)
    }

    /// Letters, digits, punctuation and spaces. Not shortcuts, arrows,
    /// function keys or Return.
    private static func isPlainTyping(_ key: UIKey) -> Bool {
        let characters = key.characters
        guard key.modifierFlags.isDisjoint(with: [.command, .control, .alternate]),
              characters.count == 1,
              !characters.hasPrefix("UIKeyInput") else { return false }
        return characters.unicodeScalars.allSatisfy { scalar in
            !CharacterSet.controlCharacters.contains(scalar) && scalar.properties.generalCategory != .privateUse
        }
    }
}

/// One notebook page: an infinite canvas of PencilKit ink, images and typed
/// text boxes, on dotted paper.
///
/// The canvas is a 100,000-point square and a new page starts in the
/// middle, so there's room in every direction (about 85 screens each way at
/// 100%). Images live in `imageLayer` (behind the ink) and text boxes in
/// `textLayer` (in front); both are subviews of the canvas scaled to match
/// its zoom, so their frames are in canvas points. The canvas itself is
/// transparent, with the dots drawn by `DotGridView` behind it.
///
/// Switching pages replaces this controller with a new one.
final class NotebookCanvasController: UIViewController {
    static let canvasExtent: CGFloat = 100_000

    let page: NotebookPage
    let modelContext: ModelContext
    var onTextModeEnded: (() -> Void)?
    /// Gets a picture of the area circled with the Ask tool.
    var onAskSelection: ((UIImage) -> Void)?
    private let askLasso = AskLassoView()

    private let canvasView = NotebookCanvasView()
    private let dotGrid = DotGridView()
    private let imageLayer = UIView()
    private let imageOverlay = ImageSelectionOverlay()
    private let textLayer = PassthroughView()
    private var eraserReturn: EraserAutoReturn?
    private var undoTaps: UndoTapGestures?
    private var quickLine: QuickLine?
    /// Shared by every page in the window, so the chosen pen stays.
    private let toolPicker: PKToolPicker
    private let saveDebouncer = Debouncer()
    private let viewportDebouncer = Debouncer()
    private var didRestoreViewport = false
    private var lastLayoutSize: CGSize = .zero
    private var isTextMode: Bool
    /// Set once another page is replacing this one.
    private var isLeaving = false
    /// The window's undo manager, kept so this page's undo steps can be
    /// cleared after the canvas has left the window.
    private weak var windowUndoManager: UndoManager?
    private lazy var textTap = UITapGestureRecognizer(target: self, action: #selector(handleTextTap(_:)))

    private lazy var textBoxes = TextBoxCoordinator(modelContext: modelContext, hooks: .init(
        undoManager: { [weak self] in self?.canvasView.undoManager },
        attach: { [weak self] box in box.notebookPage = self?.page },
        lookup: { [weak self] id in self?.page.textBoxes?.first { $0.id == id && !$0.isDeleted } },
        container: { [weak self] _ in self?.textLayer },
        contentChanged: { [weak self] in self?.scheduleSave() },
        editingEnded: { [weak self] in self?.restoreCanvasFocusSoon() }
    ))

    private lazy var images = CanvasImageCoordinator(
        page: page,
        modelContext: modelContext,
        canvasView: canvasView,
        imageLayer: imageLayer,
        overlay: imageOverlay,
        hooks: .init(
            undoManager: { [weak self] in self?.canvasView.undoManager },
            contentChanged: { [weak self] in self?.scheduleSave() }
        )
    )

    init(page: NotebookPage, modelContext: ModelContext, toolPicker: PKToolPicker, isTextMode: Bool) {
        self.page = page
        self.modelContext = modelContext
        self.toolPicker = toolPicker
        self.isTextMode = isTextMode
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        // Paper stays light in dark mode, so ink colors and text match the thumbnails.
        view.overrideUserInterfaceStyle = .light
        view.backgroundColor = Paper.color
        view.addSubview(dotGrid)

        canvasView.frame = view.bounds
        canvasView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        canvasView.backgroundColor = .clear
        canvasView.isOpaque = false
        // Only the Pencil draws. Fingers scroll, zoom and select images,
        // whatever the system's "Only Draw with Apple Pencil" setting says.
        canvasView.drawingPolicy = .pencilOnly
        canvasView.minimumZoomScale = 0.25
        canvasView.maximumZoomScale = 4
        canvasView.contentInsetAdjustmentBehavior = .never
        canvasView.showsHorizontalScrollIndicator = false
        canvasView.showsVerticalScrollIndicator = false
        if let data = page.drawingData, let drawing = try? PKDrawing(data: data) {
            canvasView.drawing = drawing
        }
        canvasView.contentSize = CGSize(width: Self.canvasExtent, height: Self.canvasExtent)
        view.addSubview(canvasView)

        for layer in [imageLayer, textLayer] {
            layer.layer.anchorPoint = .zero
            layer.bounds = CGRect(x: 0, y: 0, width: Self.canvasExtent, height: Self.canvasExtent)
            layer.layer.position = .zero
        }
        imageLayer.isUserInteractionEnabled = false
        canvasView.insertSubview(imageLayer, at: 0)
        canvasView.imageLayer = imageLayer
        canvasView.addSubview(textLayer)
        canvasView.textLayer = textLayer

        imageOverlay.frame = view.bounds
        imageOverlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(imageOverlay)

        askLasso.frame = view.bounds
        askLasso.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        askLasso.onSelection = { [weak self] rect in self?.finishAsk(in: rect) }
        view.addSubview(askLasso)

        images.showAll()
        for box in page.textBoxes ?? [] where !box.isDeleted {
            textBoxes.showView(for: box)
        }

        // Set after loading, so loading doesn't count as an edit.
        canvasView.delegate = self
        canvasView.onTypedCharacters = { [weak self] characters in
            self?.startTypingInNewBox(characters) ?? false
        }

        canvasView.addGestureRecognizer(textTap)
        applyTextMode(isTextMode)

        // The picker only tells observers about changes, so a new page's
        // canvas starts with whatever pen is selected now.
        canvasView.tool = toolPicker.selectedTool
        toolPicker.addObserver(canvasView)
        toolPicker.addObserver(self)
        toolPicker.setVisible(true, forFirstResponder: canvasView)
        eraserReturn = EraserAutoReturn(toolPicker: toolPicker)
        quickLine = QuickLine(canvasView: canvasView, previewHost: view)

        undoTaps = UndoTapGestures(
            on: canvasView,
            toastHost: view,
            undo: { [weak self] in self?.undo() ?? false },
            redo: { [weak self] in self?.redo() ?? false }
        )
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // Wait for a real size: restoring against a provisional zero height
        // puts the saved spot half a screen off.
        let size = canvasView.bounds.size
        guard size.width > 0, size.height > 0 else { return }
        if !didRestoreViewport {
            didRestoreViewport = true
            restoreViewport()
        } else if lastLayoutSize != .zero, size != lastLayoutSize {
            // Rotation, split view or the toolbar hiding: keep the same spot centered.
            canvasView.contentOffset.x += (lastLayoutSize.width - size.width) / 2
            canvasView.contentOffset.y += (lastLayoutSize.height - size.height) / 2
        }
        lastLayoutSize = size
        updateDots()
        images.updateOverlay()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        canvasView.becomeFirstResponder()
        windowUndoManager = canvasView.undoManager
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        saveNow()
    }

    /// Called just before another page replaces this one. Finishes any
    /// typing, saves, and clears the window's undo steps, which point at
    /// this page's canvas and boxes.
    func prepareToLeave() {
        isLeaving = true
        view.endEditing(true)
        saveNow()
        clearUndo()
    }

    /// Called when SwiftUI removes this page's canvas: switching pages,
    /// going back to the grid, or closing the window.
    func tearDown() {
        isLeaving = true
        view.endEditing(true)
        images.deselect()
        saveNow()
        clearUndo()
        toolPicker.removeObserver(canvasView)
        toolPicker.removeObserver(self)
        eraserReturn?.stop()
    }

    /// The undo steps point at this canvas and its boxes, which are going away.
    private func clearUndo() {
        (canvasView.undoManager ?? windowUndoManager)?.removeAllActions()
    }

    // MARK: Toolbar actions

    func applyTextMode(_ on: Bool) {
        isTextMode = on
        textTap.isEnabled = on
        canvasView.drawingGestureRecognizer.isEnabled = !on
        images.isEnabled = !on
        if !on { view.endEditing(true) }
    }

    /// Returns whether there was anything to undo.
    @discardableResult
    func undo() -> Bool {
        let manager = textBoxes.editingBox?.textView.undoManager ?? canvasView.undoManager
        guard let manager, manager.canUndo else { return false }
        manager.undo()
        return true
    }

    /// Returns whether there was anything to redo.
    @discardableResult
    func redo() -> Bool {
        let manager = textBoxes.editingBox?.textView.undoManager ?? canvasView.undoManager
        guard let manager, manager.canRedo else { return false }
        manager.redo()
        return true
    }

    /// The Ask tool: circle something on the page to ask Claude about it.
    func setAskMode(_ on: Bool) {
        if on {
            images.deselect()
            view.endEditing(true)
        }
        askLasso.isActive = on
    }

    private func finishAsk(in rect: CGRect) {
        guard let image = askLasso.snapshot(of: view, rect: rect) else { return }
        askLasso.isActive = false
        onAskSelection?(image)
    }

    /// Puts an image (from the Photos picker) in the middle of the screen.
    func addImage(data: Data) {
        let visibleCenter = CGPoint(x: canvasView.bounds.midX, y: canvasView.bounds.midY)
        let center = canvasView.convert(visibleCenter, to: imageLayer)
        Task { await images.importImage(data: data, centeredAt: center) }
    }

    // MARK: Saving

    private var isModelAlive: Bool {
        page.modelContext != nil && !page.isDeleted
    }

    private func scheduleSave() {
        saveDebouncer.schedule { [weak self] in self?.save() }
    }

    private func save() {
        guard isModelAlive else { return }
        let drawing = canvasView.drawing
        page.drawingData = drawing.dataRepresentation()
        let boxes = textBoxes.allViews.map { (frame: $0.frame, text: $0.textView.attributedText ?? NSAttributedString()) }
        Thumbnails.writeNotebookThumbnail(id: page.id, drawing: drawing, textBoxes: boxes, images: images.thumbnailImages)
        // Bumped after the thumbnail is written, because the page list and
        // the library card reload their thumbnails when these change.
        page.modifiedAt = .now
        page.notebook?.modifiedAt = .now
        try? modelContext.save()
    }

    func saveNow() {
        saveDebouncer.flush()
        viewportDebouncer.cancel()
        saveViewport()
    }

    // MARK: Viewport

    private func restoreViewport() {
        let size = canvasView.bounds.size
        let start = Self.canvasExtent / 2
        let viewport = page.viewport
            ?? Viewport(centerX: start + size.width / 2, centerY: start + size.height / 2, zoom: 1)
        let zoom = min(max(viewport.zoom, canvasView.minimumZoomScale), canvasView.maximumZoomScale)
        var center = CGPoint(x: viewport.centerX, y: viewport.centerY)

        // Safety net: never open on empty paper when the page has something on it.
        let visible = CGRect(
            x: center.x - size.width / zoom / 2,
            y: center.y - size.height / zoom / 2,
            width: size.width / zoom,
            height: size.height / zoom
        )
        if let content = contentBounds(), !visible.intersects(content) {
            center = CGPoint(x: content.midX, y: content.midY)
        }

        canvasView.zoomScale = zoom
        canvasView.contentOffset = CGPoint(
            x: center.x * zoom - size.width / 2,
            y: center.y * zoom - size.height / 2
        )
        updateTextLayerScale()
        updateTextSharpness()
    }

    /// Everything on the page (ink, text, images), in canvas points.
    private func contentBounds() -> CGRect? {
        var bounds = canvasView.drawing.strokes.isEmpty ? CGRect.null : canvasView.drawing.bounds
        for box in page.textBoxes ?? [] where !box.isDeleted {
            bounds = bounds.union(CGRect(x: box.x, y: box.y, width: box.width, height: 44))
        }
        for image in page.images ?? [] where !image.isDeleted {
            bounds = bounds.union(image.frame)
        }
        return bounds.isNull ? nil : bounds
    }

    private func currentViewport() -> Viewport {
        let zoom = canvasView.zoomScale
        let visible = canvasView.bounds
        return Viewport(centerX: visible.midX / zoom, centerY: visible.midY / zoom, zoom: zoom)
    }

    private func scheduleViewportSave() {
        viewportDebouncer.schedule { [weak self] in self?.saveViewport() }
    }

    private func saveViewport() {
        // Only while the canvas is on screen with a real size; a canvas being
        // torn down can report a size that would save the wrong spot.
        guard isModelAlive, didRestoreViewport, canvasView.window != nil,
              canvasView.bounds.width > 0, canvasView.bounds.height > 0 else { return }
        page.viewport = currentViewport()
        try? modelContext.save()
    }

    private func updateTextLayerScale() {
        let zoom = canvasView.zoomScale
        let scale = CGAffineTransform(scaleX: zoom, y: zoom)
        textLayer.transform = scale
        imageLayer.transform = scale
    }

    private func updateTextSharpness() {
        textBoxes.renderScale = TextBoxCoordinator.scale(forZoom: canvasView.zoomScale, displayScale: traitCollection.displayScale)
    }

    private func updateDots() {
        dotGrid.update(contentOffset: canvasView.contentOffset, zoom: canvasView.zoomScale, viewportSize: canvasView.bounds.size)
    }

    // MARK: Text boxes

    @objc private func handleTextTap(_ gesture: UITapGestureRecognizer) {
        let location = gesture.location(in: canvasView)
        if canvasView.hitTest(location, with: nil)?.enclosingTextBox != nil { return }
        // First tap on empty space just finishes the box being edited.
        if textBoxes.editingBox != nil {
            view.endEditing(true)
            return
        }
        let point = gesture.location(in: textLayer)
        textBoxes.createBox(at: CGPoint(x: point.x - 8, y: point.y - 22), width: 280)
    }

    private func startTypingInNewBox(_ characters: String) -> Bool {
        guard presentedViewController == nil, textBoxes.editingBox == nil else { return false }
        let visibleCenter = CGPoint(x: canvasView.bounds.midX, y: canvasView.bounds.midY)
        let center = canvasView.convert(visibleCenter, to: textLayer)
        textBoxes.createBox(at: CGPoint(x: center.x - 140, y: center.y - 22), width: 280, initialText: characters)
        return true
    }

    private func restoreCanvasFocusSoon() {
        // Wait a turn: if another box is taking focus, leave it alone.
        Task { [weak self] in
            guard let self, !self.isLeaving, self.view.window != nil, self.textBoxes.editingBox == nil else { return }
            self.canvasView.becomeFirstResponder()
        }
    }
}

extension NotebookCanvasController: PKCanvasViewDelegate {
    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        quickLine?.drawingDidChange()
        scheduleSave()
    }

    func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) {
        // Writing with the Pencil ends image editing.
        images.deselect()
        // A hand resting on the screen while writing mustn't scroll the page.
        canvasView.isScrollEnabled = false
    }

    func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) {
        canvasView.isScrollEnabled = true
        eraserReturn?.canvasDidEndUsingTool()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        updateDots()
        images.updateOverlay()
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        updateTextLayerScale()
        updateDots()
        images.updateOverlay()
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { scheduleViewportSave() }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        scheduleViewportSave()
    }

    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        updateTextSharpness()
        scheduleViewportSave()
    }
}

extension NotebookCanvasController: PKToolPickerObserver {
    // Picking an ink tool while the Text tool is on switches back to drawing.
    func toolPickerSelectedToolItemDidChange(_ toolPicker: PKToolPicker) {
        leaveTextMode()
    }

    func toolPickerSelectedToolDidChange(_ toolPicker: PKToolPicker) {
        leaveTextMode()
    }

    private func leaveTextMode() {
        guard isTextMode else { return }
        applyTextMode(false)
        onTextModeEnded?()
    }
}
