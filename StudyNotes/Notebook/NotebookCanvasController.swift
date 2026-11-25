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
    /// Pastes copied text or an image onto the page (Paste menu or ⌘V).
    var onPaste: (() -> Void)?

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        // PencilKit's Select All and Insert Space menu: a tap on the page
        // shows or hides the toolbars instead.
        if action == #selector(selectAll(_:)) || NSStringFromSelector(action).localizedCaseInsensitiveContains("insertSpace") {
            return false
        }
        if action == #selector(paste(_:)), onPaste != nil,
           UIPasteboard.general.hasStrings || UIPasteboard.general.hasImages {
            return true
        }
        return super.canPerformAction(action, withSender: sender)
    }

    override func paste(_ sender: Any?) {
        // Strokes copied with the lasso are PencilKit's to paste.
        let isDrawing = UIPasteboard.general.types.contains { $0.localizedCaseInsensitiveContains("drawing") }
        if !isDrawing, let onPaste, UIPasteboard.general.hasStrings || UIPasteboard.general.hasImages {
            onPaste()
        } else {
            super.paste(sender)
        }
    }

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
    /// A finger tapped empty paper: show or hide the toolbars.
    var onToggleChrome: (() -> Void)?
    /// The zoom changed (1 is 100%).
    var onZoomChanged: ((CGFloat) -> Void)?
    /// Where the pen palette covers the page, in the page's points (null
    /// when it's hidden).
    var onToolPickerFrame: ((CGRect) -> Void)?
    /// Whether the pen palette shows. Off while the toolbars are hidden.
    var showsToolPicker = true
    /// A finger or the Pencil touched the page, so its side of the tab is
    /// the one you're using.
    var onTouched: (@MainActor () -> Void)?
    /// This page is on the side of the tab you're using (always, with one
    /// item on screen). Only that side takes the keyboard and the pen palette.
    private(set) var isInActivePane = true
    /// This page's own undo, so undoing on one side of a tab never undoes
    /// something on the other side.
    private let pageUndoManager = UndoManager()
    /// This open page, for the study pal.
    let palPageID = UUID()
    /// Circle something for the study pal.
    private let askLasso = AskLassoView()
    /// Where things the study pal added beside the same circled area went,
    /// so the next one goes somewhere else, even before it's laid out.
    private var palPlaced: [CGRect] = []
    private var palPlacedNear: CGRect?
    /// Goes up when the page scrolls or zooms to somewhere new, so she
    /// knows to take a fresh look.
    private var viewportVersion = 0
    /// The handwritten words she was last shown, so she can erase or move them.
    private let palHandwriting = PalHandwriting()

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
    /// Where the page's top-left corner was in the window at the last
    /// layout, so the page can stay put when the toolbars or the keyboard
    /// come and go.
    private var lastLayoutOrigin: CGPoint?
    /// When the Pencil last touched the page (or is touching it now:
    /// `.infinity`), so a hand resting on the screen while writing doesn't
    /// count as a tap.
    private var lastPencilUse: CFTimeInterval = 0
    private var isTextMode: Bool
    /// Set once another page is replacing this one.
    private var isLeaving = false
    /// The canvas's undo manager (this page's own), kept so its undo steps
    /// can be cleared after the canvas has left the window.
    private weak var windowUndoManager: UndoManager?
    private lazy var textTap = UITapGestureRecognizer(target: self, action: #selector(handleTextTap(_:)))
    /// A finger tap anywhere else deselects the selected text box.
    private lazy var deselectTap = UITapGestureRecognizer(target: self, action: #selector(handleDeselectTap(_:)))
    /// Press and hold empty paper for the Paste menu.
    private lazy var pastePress = UILongPressGestureRecognizer(target: self, action: #selector(handlePastePress(_:)))
    private lazy var pasteMenu = UIEditMenuInteraction(delegate: self)
    private var pastePoint: CGPoint?
    /// A finger tap on empty paper shows or hides the toolbars.
    private lazy var chromeTap = UITapGestureRecognizer(target: self, action: #selector(handleChromeTap(_:)))
    /// Something was selected when the tap began, so the tap only
    /// deselects it.
    private var hadSelectionAtTap = false

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
            contentChanged: { [weak self] in self?.scheduleSave() },
            dropText: { [weak self] text, point in
                _ = self?.textBoxes.insertBox(at: CGPoint(x: point.x - 8, y: point.y - 22), width: 320, text: text)
            }
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

    /// The canvas, its text boxes and pictures all find this one, up the
    /// responder chain.
    override var undoManager: UndoManager? { pageUndoManager }

    /// Its side of the tab became, or stopped being, the one you're using.
    /// Becoming it, the canvas takes focus back, so the pen palette is for
    /// this page.
    func setInActivePane(_ active: Bool) {
        guard active != isInActivePane else { return }
        isInActivePane = active
        guard active, isViewLoaded, view.window != nil, !isLeaving, textBoxes.editingBox == nil else { return }
        canvasView.becomeFirstResponder()
    }

    // MARK: Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.addGestureRecognizer(TouchObserver { [weak self] in self?.onTouched?() })
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
        // As far out as Figma goes, to see a whole page of notes at once.
        canvasView.minimumZoomScale = 0.02
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
        askLasso.onSelection = { [weak self] rect in self?.finishCircle(in: rect) }
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
        canvasView.onPaste = { [weak self] in self?.pasteFromClipboard() }

        canvasView.addGestureRecognizer(textTap)
        let fingers = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        deselectTap.allowedTouchTypes = fingers
        deselectTap.cancelsTouchesInView = false
        deselectTap.delegate = self
        canvasView.addGestureRecognizer(deselectTap)
        pastePress.allowedTouchTypes = fingers
        pastePress.delegate = self
        canvasView.addGestureRecognizer(pastePress)
        canvasView.addInteraction(pasteMenu)
        chromeTap.allowedTouchTypes = fingers
        chromeTap.delegate = self
        canvasView.addGestureRecognizer(chromeTap)
        applyTextMode(isTextMode)

        // The picker only tells observers about changes, so a new page's
        // canvas starts with whatever pen is selected now.
        canvasView.tool = toolPicker.selectedTool
        toolPicker.addObserver(canvasView)
        toolPicker.addObserver(self)
        toolPicker.setVisible(showsToolPicker, forFirstResponder: canvasView)
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
        let origin = view.window.map { view.convert(CGPoint.zero, to: $0) }
        if !didRestoreViewport {
            didRestoreViewport = true
            restoreViewport()
        } else if lastLayoutSize != .zero, size != lastLayoutSize {
            if size.width != lastLayoutSize.width {
                // The window changed shape (rotation, split view, Stage
                // Manager): keep the same spot centered.
                canvasView.contentOffset.x += (lastLayoutSize.width - size.width) / 2
                canvasView.contentOffset.y += (lastLayoutSize.height - size.height) / 2
            } else {
                // Only the height changed: the toolbars hid or showed (a tap
                // on empty paper), or the keyboard came or went. The page
                // stays where it is on screen and just shows more or less
                // of itself. When the top edge moved, the page moves the
                // other way so nothing on it jumps.
                if let origin, let lastLayoutOrigin {
                    canvasView.contentOffset.y += origin.y - lastLayoutOrigin.y
                }
                if size.height < lastLayoutSize.height { keepEditingBoxInView() }
            }
        }
        lastLayoutSize = size
        lastLayoutOrigin = origin
        updateDots()
        images.updateOverlay()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // With two side by side, the side you aren't using leaves focus
        // (and the pen palette) to the other.
        if isInActivePane { canvasView.becomeFirstResponder() }
        windowUndoManager = canvasView.undoManager
        if !isLeaving { PalWorkspace.shared.register(self) }
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
        PalWorkspace.shared.unregister(self)
        view.endEditing(true)
        saveNow()
        clearUndo()
    }

    /// Called when SwiftUI removes this page's canvas: switching pages,
    /// going back to the grid, or closing the window.
    func tearDown() {
        isLeaving = true
        PalWorkspace.shared.unregister(self)
        if askLasso.isActive { Pal.shared.stopCircling() }
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
        // With the Text tool on, a tap on empty paper makes a text box.
        chromeTap.isEnabled = !on
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

    func setToolPickerVisible(_ visible: Bool) {
        showsToolPicker = visible
        guard isViewLoaded else { return }
        toolPicker.setVisible(visible, forFirstResponder: canvasView)
    }

    // MARK: Zoom

    /// Figma's zoom steps.
    private static let zoomSteps: [CGFloat] = [0.02, 0.05, 0.1, 0.25, 0.5, 0.75, 1, 1.5, 2, 3, 4]

    func zoomIn() {
        let current = canvasView.zoomScale
        let next = Self.zoomSteps.first { $0 > current + 0.01 } ?? canvasView.maximumZoomScale
        zoom(to: next)
    }

    func zoomOut() {
        let current = canvasView.zoomScale
        let next = Self.zoomSteps.last { $0 < current - 0.01 } ?? canvasView.minimumZoomScale
        zoom(to: next)
    }

    /// Zooms around the middle of the screen.
    func zoom(to scale: CGFloat) {
        let target = min(max(scale, canvasView.minimumZoomScale), canvasView.maximumZoomScale)
        let current = canvasView.zoomScale
        let center = CGPoint(x: canvasView.bounds.midX / current, y: canvasView.bounds.midY / current)
        zoom(around: center, scale: target)
    }

    /// Fits everything on the page on screen, up to 200%.
    func zoomToFit() {
        guard let content = contentBounds() else {
            zoom(to: 1)
            return
        }
        let padded = content.insetBy(dx: -60, dy: -60)
        let size = canvasView.bounds.size
        let scale = min(size.width / padded.width, size.height / padded.height)
        zoom(around: CGPoint(x: padded.midX, y: padded.midY), scale: min(max(scale, canvasView.minimumZoomScale), 2))
    }

    /// `center` is in canvas points.
    private func zoom(around center: CGPoint, scale: CGFloat) {
        let size = CGSize(width: canvasView.bounds.width / scale, height: canvasView.bounds.height / scale)
        let rect = CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height)
        canvasView.zoom(to: rect, animated: true)
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(450))
            self?.updateTextSharpness()
            self?.scheduleViewportSave()
        }
    }

    // MARK: Showing and hiding the toolbars

    @objc private func handleChromeTap(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended else { return }
        onToggleChrome?()
    }

    /// Whether a tap is on empty paper: not on a text box, an image, a
    /// marker or a button, and with nothing selected that it should
    /// deselect first.
    private func isEmptyPaperTap(_ gesture: UIGestureRecognizer) -> Bool {
        guard !hadSelectionAtTap else { return false }
        let hit = canvasView.hitTest(gesture.location(in: canvasView), with: nil)
        if hit?.enclosingTextBox != nil || hit is UIControl { return false }
        return !images.hasImage(at: gesture.location(in: imageLayer))
    }

    /// Circling for the study pal: the next loop drawn on the page goes to her.
    private func setCircling(_ on: Bool) {
        if on {
            images.deselect()
            view.endEditing(true)
        }
        askLasso.isActive = on
    }

    /// A loop was drawn: what's inside it goes to the study pal.
    private func finishCircle(in rect: CGRect) {
        askLasso.isActive = false
        guard let image = askLasso.snapshot(of: view, rect: rect),
              let jpeg = image.jpegData(compressionQuality: 0.85) else {
            Pal.shared.stopCircling()
            return
        }
        let area = view.convert(rect, to: textLayer)
        Pal.shared.circled(PalCircle(pageID: palPageID, pageIndex: nil, rect: area, image: jpeg))
    }

    /// The part of the page on screen, in page points.
    private var visibleArea: CGRect {
        canvasView.convert(canvasView.bounds, to: textLayer)
    }

    /// The middle of the screen, in canvas points.
    private var visibleCenter: CGPoint {
        canvasView.convert(CGPoint(x: canvasView.bounds.midX, y: canvasView.bounds.midY), to: textLayer)
    }

    // MARK: Paste

    @objc private func handlePastePress(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began else { return }
        let location = gesture.location(in: canvasView)
        let hit = canvasView.hitTest(location, with: nil)
        guard hit?.enclosingTextBox == nil, !(hit is UIControl) else { return }
        pastePoint = gesture.location(in: textLayer)
        canvasView.becomeFirstResponder()
        pasteMenu.presentEditMenu(with: UIEditMenuConfiguration(identifier: nil, sourcePoint: location))
    }

    private func pasteFromClipboard() {
        let point = pastePoint ?? visibleCenter
        pastePoint = nil
        let pasteboard = UIPasteboard.general
        if pasteboard.hasImages, let data = pasteboard.image?.pngData() {
            Task { await images.importImage(data: data, centeredAt: point) }
        } else if let text = pasteboard.string, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            textBoxes.insertBox(at: CGPoint(x: point.x - 8, y: point.y - 22), width: 320, text: text)
        }
    }

    @objc private func handleDeselectTap(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended else { return }
        if canvasView.hitTest(gesture.location(in: canvasView), with: nil)?.enclosingTextBox == nil {
            textBoxes.clearSelection()
        }
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

    /// Goes up with every change to the page, for `palVersion`.
    private var contentVersion = 0

    private func scheduleSave() {
        contentVersion += 1
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
        // After this layout pass, which may be part of a SwiftUI update.
        Task { [weak self] in self?.onZoomChanged?(zoom) }
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
        viewportVersion += 1
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
        let hit = canvasView.hitTest(location, with: nil)
        if hit?.enclosingTextBox != nil || hit is UIControl { return }
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

    /// The page got shorter (the keyboard came up): if the text box being
    /// typed in is now under the keyboard, scroll just enough to show it.
    private func keepEditingBoxInView() {
        guard let box = textBoxes.editingBox, box.window != nil else { return }
        let frame = box.convert(box.bounds, to: canvasView).insetBy(dx: 0, dy: -16)
        guard !canvasView.bounds.contains(frame) else { return }
        canvasView.scrollRectToVisible(frame, animated: true)
    }

    private func restoreCanvasFocusSoon() {
        // Wait a turn: if another box is taking focus, leave it alone.
        Task { [weak self] in
            // Nor when you went to the other side of the tab, which ended the typing.
            guard let self, !self.isLeaving, self.isInActivePane, self.view.window != nil, self.textBoxes.editingBox == nil else { return }
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
        // Nor hide the toolbars (see `isPalmOrWritingHand`).
        lastPencilUse = .infinity
    }

    func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) {
        lastPencilUse = CACurrentMediaTime()
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
        onZoomChanged?(scrollView.zoomScale)
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

    // Where the pen palette is, so the zoom control stays out from under it.
    func toolPickerFramesObscuredDidChange(_ toolPicker: PKToolPicker) {
        reportToolPickerFrame()
    }

    func toolPickerVisibilityDidChange(_ toolPicker: PKToolPicker) {
        reportToolPickerFrame()
    }

    private func reportToolPickerFrame() {
        onToolPickerFrame?(toolPicker.isVisible ? toolPicker.frameObscured(in: view) : .null)
    }

    private func leaveTextMode() {
        guard isTextMode else { return }
        applyTextMode(false)
        onTextModeEnded?()
    }
}

extension NotebookCanvasController: UIGestureRecognizerDelegate {
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        // The deselect tap and the paste press never block anything else.
        gestureRecognizer === deselectTap || gestureRecognizer === pastePress
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        if gestureRecognizer === chromeTap {
            // Noted before any other tap deselects things.
            hadSelectionAtTap = images.selectedID != nil || textBoxes.hasSelection
            // Only a real finger tap shows or hides the toolbars.
            if isPalmOrWritingHand(touch) { return false }
        }
        return true
    }

    /// A palm, or a hand touching the page while the Pencil writes or
    /// just after, isn't a tap on empty paper, even when it lifts like one.
    private func isPalmOrWritingHand(_ touch: UITouch) -> Bool {
        // A fingertip is about 10 to 20 points across; a palm far more.
        if touch.majorRadius > 30 { return true }
        return CACurrentMediaTime() - lastPencilUse < 0.8
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        gestureRecognizer === chromeTap ? isEmptyPaperTap(gestureRecognizer) : true
    }

    /// Other one-finger taps on the page, PencilKit's among them (it shows
    /// Select All and Insert Space), wait to see if the tap is on empty
    /// paper. If it is, it's ours: the toolbars show or hide, and nothing else.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === chromeTap,
              otherGestureRecognizer !== deselectTap, otherGestureRecognizer !== textTap,
              let tap = otherGestureRecognizer as? UITapGestureRecognizer,
              tap.numberOfTouchesRequired == 1,
              let view = tap.view, view.isDescendant(of: canvasView) else { return false }
        return true
    }
}

extension NotebookCanvasController: UIEditMenuInteractionDelegate {
    func editMenuInteraction(_ interaction: UIEditMenuInteraction, menuFor configuration: UIEditMenuConfiguration, suggestedActions: [UIMenuElement]) -> UIMenu? {
        // Paste comes from the canvas (see `NotebookCanvasView.paste`).
        UIMenu(children: suggestedActions)
    }
}

// MARK: - The study pal

extension NotebookCanvasController: PalPage {
    var palStableID: UUID { page.id }
    var palItemID: UUID { page.notebook?.id ?? page.id }
    var palKind: PalPageKind { .notebook }
    var palItemTitle: String { page.notebook?.title ?? "Untitled Notebook" }

    var palWhere: String {
        let count = page.notebook?.sortedPages.count ?? 1
        return "page “\(page.displayTitle(number: page.number))” (\(page.number) of \(count))"
    }

    var palVersion: Int { contentVersion &* 10_000 &+ viewportVersion }
    var palWindow: UIWindow? { view.window }
    var canAddImages: Bool { true }

    private var textBoxSnapshots: [(frame: CGRect, text: NSAttributedString)] {
        textBoxes.allViews.map { (frame: $0.frame, text: $0.textView.attributedText ?? NSAttributedString()) }
    }

    func palSnapshot() -> PalSnapshot {
        let area = visibleArea
        let hasContent = contentBounds()?.intersects(area) ?? false
        let picture = hasContent
            ? PalRender.notebook(area: area, drawing: canvasView.drawing, textBoxes: textBoxSnapshots, images: images.thumbnailImages)
            : nil
        return PalSnapshot(image: picture?.image, area: area, imageSize: picture?.size ?? .zero, text: palNotes(pageIndex: nil), selection: nil)
    }

    func palLook(at area: CGRect?, pageIndex: Int?, labelHandwriting: Bool) -> (image: Data, area: CGRect)? {
        guard let area = area ?? contentBounds()?.insetBy(dx: -24, dy: -24) else { return nil }
        let labels = labelHandwriting ? palHandwriting.list(canvasView.drawing, within: area) : []
        guard let picture = PalRender.notebook(area: area, drawing: canvasView.drawing, textBoxes: textBoxSnapshots, images: images.thumbnailImages, labels: labels) else { return nil }
        return (picture.image, area)
    }

    func palStartCircling() { setCircling(true) }
    func palStopCircling() { setCircling(false) }

    func palEraseHandwriting(ids: [String], region: CGRect?, pageIndex: Int?) -> (result: String, isError: Bool) {
        palHandwriting.erase(ids: ids, region: region, on: canvasView)
    }

    func palMoveHandwriting(ids: [String], to origin: CGPoint, pageIndex: Int?) -> (result: String, isError: Bool) {
        palHandwriting.move(ids: ids, to: origin, on: canvasView)
    }

    func palShowArea(_ area: CGRect?, pageIndex: Int?) -> String? {
        guard let area else {
            zoomToFit()
            return nil
        }
        let padded = area.insetBy(dx: -max(area.width * 0.1, 30), dy: -max(area.height * 0.1, 30))
        let size = canvasView.bounds.size
        let scale = min(size.width / max(padded.width, 1), size.height / max(padded.height, 1))
        zoom(around: CGPoint(x: padded.midX, y: padded.midY), scale: min(max(scale, canvasView.minimumZoomScale), canvasView.maximumZoomScale))
        return nil
    }

    func palUndo() -> Bool { undo() }
    func palRedo() -> Bool { redo() }

    func palRemoveHighlights(_ text: String, pageIndex: Int?) -> String? {
        "Notebook pages have no PDF highlights. To remove highlighter ink, use erase_handwriting with a region."
    }

    func palItems(pageIndex: Int?) -> String {
        let visible = visibleArea
        var items: [[String: Any]] = (page.textBoxes ?? []).filter { !$0.isDeleted }.map { box in
            [
                "id": box.id.uuidString,
                "kind": "text",
                "x": box.x.rounded(),
                "y": box.y.rounded(),
                "width": box.width.rounded(),
                "height": textBoxes.height(of: box.id).rounded(),
                "text": String(box.plainText.prefix(400)),
                "color": textBoxes.color(of: box.id).map(PalColor.name) ?? "black",
            ] as [String: Any]
        }
        items += images.describeImages()
        // The handwriting around the screen, word by word.
        let words = palHandwriting.list(canvasView.drawing, within: visible.insetBy(dx: -visible.width / 2, dy: -visible.height / 2))
        let ink: [[String: Any]] = words.map { word in
            ["id": word.id, "line": word.line, "x": word.rect.minX.rounded(), "y": word.rect.minY.rounded(), "width": word.rect.width.rounded(), "height": word.rect.height.rounded()]
        }
        let description: [String: Any] = [
            "coordinates": "Page points. x grows to the right, y grows down.",
            "visible_area": [
                "x": visible.minX.rounded(), "y": visible.minY.rounded(),
                "width": visible.width.rounded(), "height": visible.height.rounded(),
            ],
            "items": items,
            "handwriting": ink,
            "note": "Handwriting is listed word by word (around the screen) with ids for erase_handwriting and move_handwriting. To see which word is which, use look_at with label_handwriting.",
        ]
        return PalJSON.string(description)
    }

    func palNotes(pageIndex: Int?) -> String {
        (page.textBoxes ?? [])
            .filter { !$0.isDeleted && !$0.plainText.isEmpty }
            .sorted { ($0.y, $0.x) < ($1.y, $1.x) }
            .map(\.plainText)
            .joined(separator: "\n\n")
    }

    func palAddText(_ text: String, at origin: CGPoint?, color: UIColor?, in place: PalPlace) -> UUID? {
        let style = pageTextStyle()
        let measured = (text as NSString).boundingRect(
            with: CGSize(width: style.width - 16, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: style.font],
            context: nil
        )
        let size = CGSize(width: style.width, height: ceil(measured.height) + 24)
        let spot = origin ?? freeSpot(for: size, near: place.near)
        return textBoxes.insertBox(at: spot, width: style.width, text: text, font: style.font, color: color ?? style.color)
    }

    func palWrite(_ text: String, at origin: CGPoint?, letterHeight: CGFloat?, color: UIColor?, in place: PalPlace) -> (result: String, isError: Bool) {
        let visible = visibleArea
        // Without handwriting to match, a size that reads well on screen.
        let style = PalInkReading.style(of: canvasView.drawing, fallbackHeight: 20 / max(canvasView.zoomScale, 0.05))
        let height = min(max(letterHeight ?? style.letterHeight, 6), 200)
        let maxWidth = max(min(visible.width * 0.45, height * 40), height * 10)
        let size = PalInk.measure(text, letterHeight: height, maxWidth: maxWidth)
        let spot = origin ?? freeSpot(for: CGSize(width: size.width + 8, height: size.height + 8), near: place.near)
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
        PalInkEditing.add(writing.strokes, to: canvasView, actionName: "Writing")
        let box = writing.bounds
        return ("Wrote it by hand at x \(Int(box.minX)), y \(Int(box.minY)), width \(Int(box.width)), height \(Int(box.height)).", false)
    }

    func palMark(_ mark: PalInk.Mark, around rect: CGRect, to: CGPoint?, color: UIColor?, in place: PalPlace) -> String? {
        let style = PalInkReading.style(of: canvasView.drawing, fallbackHeight: 20 / max(canvasView.zoomScale, 0.05))
        let strokes = PalInk.mark(mark, around: rect, to: to, color: color ?? PalColor.red, penWidth: max(style.penWidth, 2), seed: UInt64.random(in: 1...UInt64.max))
        guard !strokes.isEmpty else { return "Couldn't draw that mark." }
        PalInkEditing.add(strokes, to: canvasView, actionName: "Mark")
        return nil
    }

    func palReadPages(_ pages: ClosedRange<Int>) -> String? { nil }

    func palHighlight(_ text: String, pageIndex: Int?, color: HighlightColor) -> String? {
        "Highlighting works on PDFs. On a notebook page, use mark to underline or circle it."
    }

    /// How typed text looks on this page, so what the study pal writes matches it:
    /// the font, color and width most of its text boxes use. With no typed
    /// text yet, the color most of the handwriting is in.
    private func pageTextStyle() -> (font: UIFont, color: UIColor, width: CGFloat) {
        var fonts: [String: (font: UIFont, count: Int)] = [:]
        var colors: [String: (color: UIColor, count: Int)] = [:]
        var widths: [CGFloat] = []
        func count(_ color: UIColor) {
            let key = Self.colorKey(color)
            colors[key] = (color, (colors[key]?.count ?? 0) + 1)
        }
        for box in page.textBoxes ?? [] where !box.isDeleted && !box.plainText.isEmpty {
            widths.append(CGFloat(box.width))
            guard let data = box.richText, let text = RichText.decode(data), text.length > 0 else { continue }
            let attributes = text.attributes(at: 0, effectiveRange: nil)
            if let font = attributes[.font] as? UIFont {
                let key = "\(font.fontName) \(font.pointSize)"
                fonts[key] = (font, (fonts[key]?.count ?? 0) + 1)
            }
            if let color = attributes[.foregroundColor] as? UIColor { count(color) }
        }
        if colors.isEmpty {
            // Highlighters aren't writing.
            for stroke in canvasView.drawing.strokes.suffix(150) where stroke.ink.inkType != .marker {
                count(stroke.ink.color)
            }
        }
        let font = fonts.values.max { $0.count < $1.count }?.font ?? TextBoxView.defaultFont
        var color = colors.values.max { $0.count < $1.count }?.color ?? .black
        // A pale pen color would be hard to read as text.
        if Self.lightness(of: color) > 0.8 { color = .black }
        let width = widths.isEmpty ? 360 : min(max(widths.sorted()[widths.count / 2], 220), 520)
        return (font, color, width)
    }

    private static func colorKey(_ color: UIColor) -> String {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return String(format: "%.2f %.2f %.2f", red, green, blue)
    }

    private static func lightness(of color: UIColor) -> CGFloat {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return 0.2126 * red + 0.7152 * green + 0.0722 * blue
    }

    func palAddImage(_ image: PreparedImage, in place: PalPlace) -> UUID? {
        let size = CanvasImageCoordinator.defaultSize(of: image)
        let origin = freeSpot(for: size, near: place.near)
        return images.add(image, centeredAt: CGPoint(x: origin.x + size.width / 2, y: origin.y + size.height / 2))
    }

    /// Where to put something new from the study pal, as its top-left
    /// corner: a free spot that covers no ink, text or image.
    /// - With an area circled: as close as it can to just right of it.
    /// - Otherwise: as close as it can to the middle of the screen.
    private func freeSpot(for size: CGSize, near: CGRect?) -> CGPoint {
        if near != palPlacedNear {
            palPlacedNear = near
            palPlaced = []
        }
        let visible = visibleArea
        var taken = canvasView.drawing.strokes.map(\.renderBounds)
        taken += textBoxes.allViews.map(\.frame)
        taken += (page.images ?? []).filter { !$0.isDeleted }.map(\.frame)
        taken += palPlaced
        let preferred = near.map { CGPoint(x: $0.maxX + 20, y: $0.minY) }
            ?? CGPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2)
        let spot = PalSpot.find(for: size, preferred: preferred, visible: visible, taken: taken, below: contentBounds()?.maxY ?? preferred.y)
        palPlaced.append(CGRect(origin: spot, size: size))
        return spot
    }

    func palMoveItem(_ id: UUID, to origin: CGPoint) -> String? {
        change(id) { kind in
            switch kind {
            case .text: _ = self.textBoxes.setBoxFrame(id: id, origin: origin)
            case .image: _ = self.images.changeImage(id, origin: origin)
            }
        }
    }

    func palResizeItem(_ id: UUID, width: CGFloat) -> String? {
        change(id) { kind in
            switch kind {
            case .text: _ = self.textBoxes.setBoxFrame(id: id, width: width)
            case .image: _ = self.images.changeImage(id, width: width)
            }
        }
    }

    func palEditText(_ id: UUID, text: String) -> String? {
        guard textBoxes.box(id) != nil else {
            return images.hasImage(id) ? "Images can't be edited, only moved, resized or deleted." : Self.unknownItem
        }
        textBoxes.replaceText(id: id, with: text)
        return nil
    }

    func palDeleteItem(_ id: UUID) -> String? {
        if textBoxes.box(id) != nil {
            textBoxes.removeBox(id: id, undoable: true)
            return nil
        }
        return images.hasImage(id) ? images.deleteImage(id) : Self.unknownItem
    }

    func palHasItem(_ id: UUID) -> Bool {
        textBoxes.box(id) != nil || images.hasImage(id)
    }

    func palRecolor(notes: [UUID], ink: [String], region: CGRect?, color: UIColor, pageIndex: Int?) -> (result: String, isError: Bool) {
        var done: [String] = []
        var problems: [String] = []
        let colored = notes.filter { textBoxes.setColor(id: $0, to: color) }
        if !colored.isEmpty { done.append("Colored \(colored.count) typed note\(colored.count == 1 ? "" : "s").") }
        for id in notes where !colored.contains(id) {
            problems.append(images.hasImage(id) ? "Pictures keep their own colors." : "No typed note with id \(id.uuidString) on this page.")
        }
        if !ink.isEmpty || region != nil {
            let inked = palHandwriting.recolor(ids: ink, region: region, to: color, on: canvasView)
            if inked.isError { problems.append(inked.result) } else { done.append(inked.result) }
        }
        guard !done.isEmpty else { return (problems.joined(separator: " "), true) }
        return ((done + problems).joined(separator: " "), false)
    }

    private enum ItemKind { case text, image }
    private static let unknownItem = "No typed note or picture with that id on this page. Call get_page_items for the current ids."

    /// Runs a change on a text box or an unlocked image, animated so you can
    /// see what moved. Returns nil, or why it couldn't.
    private func change(_ id: UUID, _ apply: @escaping @MainActor @Sendable (ItemKind) -> Void) -> String? {
        let kind: ItemKind
        if textBoxes.box(id) != nil {
            kind = .text
        } else if images.hasImage(id) {
            if let problem = images.problem(with: id) { return problem }
            kind = .image
        } else {
            return Self.unknownItem
        }
        UIView.animate(withDuration: 0.35, delay: 0, options: [.curveEaseInOut]) {
            apply(kind)
        }
        return nil
    }
}
