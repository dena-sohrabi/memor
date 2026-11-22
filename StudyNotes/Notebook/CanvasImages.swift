import ImageIO
import SwiftData
import UIKit
import UniformTypeIdentifiers

// MARK: - Importing

/// An image made ready for a notebook page: decoded, turned upright and
/// shrunk to at most 2048 pixels on its longest side.
struct PreparedImage: Sendable {
    let data: Data
    let pixelSize: CGSize
}

enum ImageImport {
    static let maxPixelSize = 2048

    /// Blocking: call it off the main thread.
    static func prepare(_ data: Data) -> PreparedImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }

        let hasAlpha = switch image.alphaInfo {
        case .first, .last, .premultipliedFirst, .premultipliedLast: true
        default: false
        }
        let type = hasAlpha ? UTType.png : UTType.jpeg
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output as CFMutableData, type.identifier as CFString, 1, nil) else { return nil }
        let properties: [CFString: Any] = hasAlpha ? [:] : [kCGImageDestinationLossyCompressionQuality: 0.85]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return PreparedImage(data: output as Data, pixelSize: CGSize(width: image.width, height: image.height))
    }
}

// MARK: - Views

/// One image on the page. Its frame is in canvas points.
final class CanvasImageView: UIImageView {
    let imageID: UUID

    init(imageID: UUID, image: UIImage) {
        self.imageID = imageID
        super.init(image: image)
        contentMode = .scaleToFill
        isUserInteractionEnabled = false
        layer.minificationFilter = .trilinear
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

/// The selection around an image: a border, four corner handles and a small
/// toolbar to lock or delete it. Lives above the canvas in screen
/// coordinates, so handles keep their size at any zoom. Only the toolbar
/// takes touches; dragging the image and its handles is handled by the
/// canvas (see `CanvasImageCoordinator`).
final class ImageSelectionOverlay: PassthroughView {
    var onToggleLock: (@MainActor () -> Void)?
    var onDelete: (@MainActor () -> Void)?

    static let handleHitRadius: CGFloat = 28
    private static let handleSize: CGFloat = 14

    private let border = UIView()
    private var handles: [UIView] = []
    private let toolbar = UIVisualEffectView(effect: UIBlurEffect(style: .systemThickMaterial))
    private let stack = UIStackView()
    private let lockButton = UIButton(type: .system)
    private let deleteButton = UIButton(type: .system)

    override init(frame: CGRect) {
        super.init(frame: frame)
        isHidden = true

        border.isUserInteractionEnabled = false
        border.layer.borderWidth = 2
        addSubview(border)

        for _ in 0..<4 {
            let handle = UIView(frame: CGRect(x: 0, y: 0, width: Self.handleSize, height: Self.handleSize))
            handle.isUserInteractionEnabled = false
            handle.backgroundColor = .white
            handle.layer.cornerRadius = Self.handleSize / 2
            handle.layer.borderWidth = 2
            handle.layer.shadowColor = UIColor.black.cgColor
            handle.layer.shadowOpacity = 0.15
            handle.layer.shadowRadius = 2
            handle.layer.shadowOffset = CGSize(width: 0, height: 1)
            handles.append(handle)
            addSubview(handle)
        }

        lockButton.addTarget(self, action: #selector(lockTapped), for: .touchUpInside)
        deleteButton.setImage(UIImage(systemName: "trash"), for: .normal)
        deleteButton.tintColor = .systemRed
        deleteButton.accessibilityLabel = "Delete Image"
        deleteButton.addTarget(self, action: #selector(deleteTapped), for: .touchUpInside)
        for button in [lockButton, deleteButton] {
            button.widthAnchor.constraint(equalToConstant: 44).isActive = true
            button.heightAnchor.constraint(equalToConstant: 36).isActive = true
        }
        stack.axis = .horizontal
        stack.spacing = 2
        stack.addArrangedSubview(lockButton)
        stack.addArrangedSubview(deleteButton)
        stack.translatesAutoresizingMaskIntoConstraints = false
        toolbar.contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: toolbar.contentView.leadingAnchor, constant: 6),
            stack.trailingAnchor.constraint(equalTo: toolbar.contentView.trailingAnchor, constant: -6),
            stack.topAnchor.constraint(equalTo: toolbar.contentView.topAnchor, constant: 2),
            stack.bottomAnchor.constraint(equalTo: toolbar.contentView.bottomAnchor, constant: -2),
        ])
        toolbar.clipsToBounds = true
        toolbar.layer.cornerRadius = 20
        addSubview(toolbar)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Shows the selection around `frame` (in this view's coordinates).
    func show(frame: CGRect, locked: Bool) {
        isHidden = false
        let color = locked ? UIColor.systemGray : tintColor ?? .systemBlue
        border.frame = frame
        border.layer.borderColor = color.cgColor
        for (index, handle) in handles.enumerated() {
            handle.isHidden = locked
            handle.layer.borderColor = color.cgColor
            handle.center = Self.cornerPoint(index, of: frame)
        }

        lockButton.setImage(UIImage(systemName: locked ? "lock.fill" : "lock.open"), for: .normal)
        lockButton.tintColor = locked ? .systemOrange : .label
        lockButton.accessibilityLabel = locked ? "Unlock Image" : "Lock Image"
        deleteButton.isHidden = locked

        let buttonCount: CGFloat = locked ? 1 : 2
        let size = CGSize(width: buttonCount * 44 + (buttonCount - 1) * stack.spacing + 12, height: 40)
        var origin = CGPoint(x: frame.midX - size.width / 2, y: frame.minY - size.height - 14)
        if origin.y < safeAreaInsets.top + 8 {
            origin.y = frame.maxY + 14
        }
        origin.x = min(max(origin.x, 8), max(bounds.width - size.width - 8, 8))
        origin.y = min(max(origin.y, safeAreaInsets.top + 8), max(bounds.height - size.height - 8, 8))
        toolbar.frame = CGRect(origin: origin, size: size)
        toolbar.layer.cornerRadius = size.height / 2
    }

    func hide() {
        isHidden = true
    }

    /// Corners: 0 top-left, 1 top-right, 2 bottom-left, 3 bottom-right.
    static func cornerPoint(_ index: Int, of frame: CGRect) -> CGPoint {
        CGPoint(x: index % 2 == 0 ? frame.minX : frame.maxX, y: index < 2 ? frame.minY : frame.maxY)
    }

    /// The corner of `frame` within reach of `point`, if any.
    static func corner(of frame: CGRect, near point: CGPoint) -> Int? {
        func distance(_ index: Int) -> CGFloat {
            let corner = cornerPoint(index, of: frame)
            return hypot(corner.x - point.x, corner.y - point.y)
        }
        guard let nearest = (0..<4).min(by: { distance($0) < distance($1) }),
              distance(nearest) <= handleHitRadius else { return nil }
        return nearest
    }

    @objc private func lockTapped() { onToggleLock?() }
    @objc private func deleteTapped() { onDelete?() }
}

// MARK: - Coordinator

/// Images on a notebook page: dropping them in, selecting them with a finger
/// tap, moving and resizing them by dragging, locking and deleting, all with
/// undo.
///
/// Image views live in `imageLayer`, which sits behind the ink inside the
/// canvas and is scaled with it, so their frames are in canvas points. The
/// Pencil always draws; image editing is fingers only.
@MainActor
final class CanvasImageCoordinator: NSObject {
    struct Hooks {
        var undoManager: @MainActor () -> UndoManager?
        var contentChanged: @MainActor () -> Void
        /// Text dropped on the page, at a point in canvas points.
        var dropText: @MainActor (String, CGPoint) -> Void
    }

    private enum DragMode {
        case move
        case resize(corner: Int)
    }

    private struct Drag {
        let id: UUID
        let mode: DragMode
        let startFrame: CGRect
    }

    private static let defaultMaxSide: CGFloat = 400
    private static let minimumSide: CGFloat = 32

    private let page: NotebookPage
    private let modelContext: ModelContext
    private let hooks: Hooks
    private weak var canvasView: UIScrollView?
    private let imageLayer: UIView
    private let overlay: ImageSelectionOverlay
    private var views: [UUID: CanvasImageView] = [:]
    private(set) var selectedID: UUID?
    private var pendingMode: DragMode?
    private var drag: Drag?
    private let selectTap = UITapGestureRecognizer()
    private let editPan = UIPanGestureRecognizer()

    /// Off while the Text tool is on.
    var isEnabled = true {
        didSet {
            selectTap.isEnabled = isEnabled
            editPan.isEnabled = isEnabled
            if !isEnabled { deselect() }
        }
    }

    init(page: NotebookPage, modelContext: ModelContext, canvasView: UIScrollView, imageLayer: UIView, overlay: ImageSelectionOverlay, hooks: Hooks) {
        self.page = page
        self.modelContext = modelContext
        self.canvasView = canvasView
        self.imageLayer = imageLayer
        self.overlay = overlay
        self.hooks = hooks
        super.init()

        overlay.onToggleLock = { [weak self] in self?.toggleLockOfSelection() }
        overlay.onDelete = { [weak self] in self?.deleteSelection() }

        let fingers = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        selectTap.allowedTouchTypes = fingers
        selectTap.delegate = self
        selectTap.addTarget(self, action: #selector(handleTap(_:)))
        editPan.allowedTouchTypes = fingers
        editPan.maximumNumberOfTouches = 1
        editPan.delegate = self
        editPan.addTarget(self, action: #selector(handlePan(_:)))
        canvasView.addGestureRecognizer(selectTap)
        canvasView.addGestureRecognizer(editPan)
        // Dragging a selected image moves it instead of scrolling the page.
        canvasView.panGestureRecognizer.require(toFail: editPan)
        canvasView.addInteraction(UIDropInteraction(delegate: self))
    }

    // MARK: Showing

    func showAll() {
        let images = (page.images ?? [])
            .filter { !$0.isDeleted }
            .sorted { ($0.zIndex, $0.createdAt) < ($1.zIndex, $1.createdAt) }
        for image in images {
            addView(for: image)
        }
    }

    /// The images in stacking order, for the page thumbnail.
    var thumbnailImages: [(frame: CGRect, image: UIImage)] {
        imageLayer.subviews.compactMap { view in
            guard let view = view as? CanvasImageView, let image = view.image else { return nil }
            return (frame: view.frame, image: image)
        }
    }

    @discardableResult
    private func addView(for model: CanvasImage) -> CanvasImageView? {
        if let existing = views[model.id] { return existing }
        guard let data = model.imageData, let image = UIImage(data: data) else { return nil }
        let view = CanvasImageView(imageID: model.id, image: image)
        view.frame = model.frame
        imageLayer.addSubview(view)
        views[model.id] = view
        return view
    }

    private func sortViews() {
        let models = (page.images ?? []).filter { !$0.isDeleted }
            .sorted { ($0.zIndex, $0.createdAt) < ($1.zIndex, $1.createdAt) }
        for model in models {
            if let view = views[model.id] { imageLayer.bringSubviewToFront(view) }
        }
    }

    private func model(_ id: UUID) -> CanvasImage? {
        page.images?.first { $0.id == id && !$0.isDeleted }
    }

    /// Whether there's an image at a point, in canvas points.
    func hasImage(at point: CGPoint) -> Bool {
        hitImage(at: point) != nil
    }

    private func hitImage(at point: CGPoint) -> CanvasImageView? {
        imageLayer.subviews.reversed()
            .compactMap { $0 as? CanvasImageView }
            .first { $0.frame.contains(point) }
    }

    // MARK: Selection

    func select(_ id: UUID) {
        selectedID = id
        updateOverlay()
    }

    func deselect() {
        selectedID = nil
        drag = nil
        overlay.hide()
    }

    /// Moves the selection to follow the image. Call after scrolling or zooming.
    func updateOverlay() {
        guard let id = selectedID, let view = views[id], let model = model(id) else {
            overlay.hide()
            return
        }
        overlay.show(frame: imageLayer.convert(view.frame, to: overlay), locked: model.isLocked)
    }

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended, let canvasView else { return }
        // Taps on a text box or a marker belong to them.
        let hit = canvasView.hitTest(gesture.location(in: canvasView), with: nil)
        if hit?.enclosingTextBox != nil || hit is UIControl { return }
        if let hit = hitImage(at: gesture.location(in: imageLayer)) {
            select(hit.imageID)
        } else {
            deselect()
        }
    }

    // MARK: Moving and resizing

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        switch gesture.state {
        case .began:
            guard let id = selectedID, let view = views[id], let mode = pendingMode else { return }
            drag = Drag(id: id, mode: mode, startFrame: view.frame)
        case .changed:
            guard let drag, let view = views[drag.id] else { return }
            let zoom = max(canvasView?.zoomScale ?? 1, 0.01)
            let translation = gesture.translation(in: overlay)
            view.frame = Self.frame(for: drag, delta: CGPoint(x: translation.x / zoom, y: translation.y / zoom))
            updateOverlay()
        case .ended:
            guard let drag, let view = views[drag.id] else { return }
            self.drag = nil
            if view.frame != drag.startFrame {
                setFrame(view.frame, of: drag.id, previous: drag.startFrame)
            }
        case .cancelled, .failed:
            if let drag, let view = views[drag.id] {
                view.frame = drag.startFrame
                updateOverlay()
            }
            drag = nil
        default:
            break
        }
    }

    private static func frame(for drag: Drag, delta: CGPoint) -> CGRect {
        let start = drag.startFrame
        switch drag.mode {
        case .move:
            return start.offsetBy(dx: delta.x, dy: delta.y)
        case .resize(let corner):
            // Keep the aspect ratio, and keep the opposite corner in place.
            let signX: CGFloat = corner % 2 == 0 ? -1 : 1
            let signY: CGFloat = corner < 2 ? -1 : 1
            let scaleX = (start.width + signX * delta.x) / start.width
            let scaleY = (start.height + signY * delta.y) / start.height
            let minimumScale = minimumSide / max(min(start.width, start.height), 1)
            let scale = max(max(scaleX, scaleY), minimumScale)
            let size = CGSize(width: start.width * scale, height: start.height * scale)
            let x = signX > 0 ? start.minX : start.maxX - size.width
            let y = signY > 0 ? start.minY : start.maxY - size.height
            return CGRect(origin: CGPoint(x: x, y: y), size: size)
        }
    }

    private func setFrame(_ frame: CGRect, of id: UUID, previous: CGRect) {
        guard let model = model(id) else { return }
        model.frame = frame
        views[id]?.frame = frame
        if selectedID == id { updateOverlay() }
        hooks.undoManager()?.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated { target.setFrame(previous, of: id, previous: frame) }
        }
        hooks.contentChanged()
    }

    // MARK: Adding, deleting and locking

    /// Prepares the image off the main thread, then puts it on the page,
    /// centered on `center` (canvas points).
    func importImage(data: Data, centeredAt center: CGPoint) async {
        let prepared = await Task.detached(priority: .userInitiated) { ImageImport.prepare(data) }.value
        guard let prepared, page.modelContext != nil, !page.isDeleted else { return }
        add(prepared, centeredAt: center)
    }

    /// Puts a prepared image on the page, selected, with undo.
    @discardableResult
    /// The size a new image gets on the page: its @2x point size, shrunk
    /// to fit a 400-point square.
    static func defaultSize(of prepared: PreparedImage) -> CGSize {
        let natural = CGSize(width: max(prepared.pixelSize.width / 2, 1), height: max(prepared.pixelSize.height / 2, 1))
        let scale = min(1, defaultMaxSide / natural.width, defaultMaxSide / natural.height)
        return CGSize(width: natural.width * scale, height: natural.height * scale)
    }

    func add(_ prepared: PreparedImage, centeredAt center: CGPoint) -> UUID {
        let size = Self.defaultSize(of: prepared)
        let frame = CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height)

        let image = CanvasImage(frame: frame, imageData: prepared.data)
        image.zIndex = ((page.images ?? []).filter { !$0.isDeleted }.map(\.zIndex).max() ?? -1) + 1
        modelContext.insert(image)
        image.page = page
        addView(for: image)
        select(image.id)
        let id = image.id
        hooks.undoManager()?.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated { target.remove(id) }
        }
        hooks.contentChanged()
        return id
    }

    // MARK: Changes asked for by Claude

    /// Every image on the page, for Claude: id, frame and whether it's locked.
    func describeImages() -> [[String: Any]] {
        (page.images ?? []).filter { !$0.isDeleted }
            .sorted { ($0.zIndex, $0.createdAt) < ($1.zIndex, $1.createdAt) }
            .map { image in
                [
                    "id": image.id.uuidString,
                    "kind": "image",
                    "x": image.x.rounded(),
                    "y": image.y.rounded(),
                    "width": image.width.rounded(),
                    "height": image.height.rounded(),
                    "locked": image.isLocked,
                ] as [String: Any]
            }
    }

    func hasImage(_ id: UUID) -> Bool {
        model(id) != nil
    }

    /// Why Claude can't change this image, if it can't.
    func problem(with id: UUID) -> String? {
        guard let model = model(id) else { return "No image with that id." }
        return model.isLocked ? "That image is locked. The user can unlock it from its toolbar." : nil
    }

    /// Moves and/or resizes an image (keeping its shape), with undo.
    /// Returns nil, or why it couldn't.
    func changeImage(_ id: UUID, origin: CGPoint? = nil, width: CGFloat? = nil) -> String? {
        guard let model = model(id) else { return "No image with that id." }
        guard !model.isLocked else { return "That image is locked. The user can unlock it from its toolbar." }
        let previous = model.frame
        let newWidth = max(width ?? previous.width, Self.minimumSide)
        let newHeight = previous.height * newWidth / max(previous.width, 1)
        let frame = CGRect(x: origin?.x ?? previous.minX, y: origin?.y ?? previous.minY, width: newWidth, height: newHeight)
        setFrame(frame, of: id, previous: previous)
        return nil
    }

    /// Deletes an image, with undo. Returns nil, or why it couldn't.
    func deleteImage(_ id: UUID) -> String? {
        guard let model = model(id) else { return "No image with that id." }
        guard !model.isLocked else { return "That image is locked. The user can unlock it from its toolbar." }
        remove(id)
        return nil
    }

    private func remove(_ id: UUID) {
        guard let model = model(id) else { return }
        let snapshot = CanvasImageSnapshot(model)
        if selectedID == id { deselect() }
        views.removeValue(forKey: id)?.removeFromSuperview()
        modelContext.delete(model)
        hooks.undoManager()?.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated { target.restore(snapshot) }
        }
        hooks.contentChanged()
    }

    private func restore(_ snapshot: CanvasImageSnapshot) {
        let image = snapshot.makeModel()
        modelContext.insert(image)
        image.page = page
        addView(for: image)
        sortViews()
        let id = snapshot.id
        hooks.undoManager()?.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated { target.remove(id) }
        }
        hooks.contentChanged()
    }

    private func deleteSelection() {
        guard let id = selectedID, let model = model(id), !model.isLocked else { return }
        remove(id)
    }

    private func toggleLockOfSelection() {
        guard let id = selectedID, let model = model(id) else { return }
        setLocked(!model.isLocked, for: id)
    }

    private func setLocked(_ locked: Bool, for id: UUID) {
        guard let model = model(id) else { return }
        model.isLocked = locked
        if selectedID == id { updateOverlay() }
        hooks.undoManager()?.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated { target.setLocked(!locked, for: id) }
        }
        hooks.contentChanged()
    }
}

extension CanvasImageCoordinator: UIGestureRecognizerDelegate {
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === editPan else { return true }
        pendingMode = nil
        guard let id = selectedID, let view = views[id], let model = model(id), !model.isLocked else { return false }
        // Where the finger went down, not where it is now.
        let location = editPan.location(in: overlay)
        let translation = editPan.translation(in: overlay)
        let start = CGPoint(x: location.x - translation.x, y: location.y - translation.y)
        let frame = imageLayer.convert(view.frame, to: overlay)
        if let corner = ImageSelectionOverlay.corner(of: frame, near: start) {
            pendingMode = .resize(corner: corner)
        } else if frame.contains(start) {
            pendingMode = .move
        }
        return pendingMode != nil
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        // A tap to select shouldn't stop anything else.
        gestureRecognizer === selectTap
    }
}

extension CanvasImageCoordinator: UIDropInteractionDelegate {
    func dropInteraction(_ interaction: UIDropInteraction, canHandle session: UIDropSession) -> Bool {
        session.hasItemsConforming(toTypeIdentifiers: [UTType.image.identifier, UTType.plainText.identifier])
    }

    func dropInteraction(_ interaction: UIDropInteraction, sessionDidUpdate session: UIDropSession) -> UIDropProposal {
        UIDropProposal(operation: .copy)
    }

    func dropInteraction(_ interaction: UIDropInteraction, performDrop session: UIDropSession) {
        let point = session.location(in: imageLayer)
        let providers = session.items.map(\.itemProvider)
            .filter { $0.hasItemConformingToTypeIdentifier(UTType.image.identifier) }
        if providers.isEmpty {
            dropText(from: session, at: point)
            return
        }
        for (index, provider) in providers.enumerated() {
            // Several images land in a small cascade.
            let center = CGPoint(x: point.x + CGFloat(index) * 24, y: point.y + CGFloat(index) * 24)
            _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { [weak self] data, _ in
                guard let data else { return }
                Task { @MainActor [weak self] in
                    await self?.importImage(data: data, centeredAt: center)
                }
            }
        }
    }
}

extension CanvasImageCoordinator {
    /// Dropped text (for example, selected in the Ask Claude panel) becomes a text box.
    fileprivate func dropText(from session: UIDropSession, at point: CGPoint) {
        let providers = session.items.map(\.itemProvider)
            .filter { $0.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) }
        for (index, provider) in providers.enumerated() {
            let spot = CGPoint(x: point.x, y: point.y + CGFloat(index) * 40)
            _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.plainText.identifier) { [weak self] data, _ in
                guard let data, let text = String(data: data, encoding: .utf8),
                      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                Task { @MainActor [weak self] in
                    self?.hooks.dropText(text, spot)
                }
            }
        }
    }
}
