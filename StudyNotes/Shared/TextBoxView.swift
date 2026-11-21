import SwiftData
import UIKit

@MainActor
protocol TextBoxViewDelegate: AnyObject {
    func textBoxViewDidChangeText(_ boxView: TextBoxView)
    func textBoxViewDidEndEditing(_ boxView: TextBoxView)
    func textBoxView(_ boxView: TextBoxView, didMoveFrom oldFrame: CGRect)
    func textBoxViewDidRequestDelete(_ boxView: TextBoxView)
}

/// A text view with its own undo stack. Typing undo stays inside the box, so
/// the shared undo stack never points at a box that was deleted.
final class BoxTextView: UITextView {
    private let ownUndoManager = UndoManager()
    override var undoManager: UndoManager? { ownUndoManager }
}

/// A typed text box on a notebook canvas or a PDF page.
///
/// When you're not typing in it, drag it with a finger to move it, or tap
/// it to edit. While editing, it shows a border, a move handle on the left
/// and a resize strip on the right edge. Its height follows the text. It
/// writes position and text straight into its `TextBox` model; the delegate
/// saves.
final class TextBoxView: UIView {
    static let defaultFont = UIFont.systemFont(ofSize: 18)
    private static let minimumWidth: CGFloat = 80
    private static let handleSize: CGFloat = 40

    let boxID: UUID
    let model: TextBox
    let textView = BoxTextView()
    weak var delegate: TextBoxViewDelegate?

    private let moveHandle = UIImageView(image: UIImage(systemName: "arrow.up.and.down.and.arrow.left.and.right"))
    private let resizeHandle = UIView()
    private let resizeGrip = UIView()
    /// Moves the whole box with a finger while it isn't being edited.
    private let dragPan = UIPanGestureRecognizer()
    private var frameAtGestureStart: CGRect = .zero
    private var renderScale: CGFloat = 0

    var isEmpty: Bool {
        textView.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    init(model: TextBox) {
        self.model = model
        self.boxID = model.id
        super.init(frame: CGRect(x: model.x, y: model.y, width: model.width, height: 44))
        backgroundColor = .clear
        layer.cornerRadius = 6
        layer.borderColor = UIColor.systemBlue.withAlphaComponent(0.6).cgColor

        textView.backgroundColor = .clear
        textView.isScrollEnabled = false
        textView.allowsEditingTextAttributes = true
        textView.textContainerInset = UIEdgeInsets(top: 8, left: 4, bottom: 8, right: 4)
        textView.font = Self.defaultFont
        textView.textColor = .black
        if let data = model.richText, let text = RichText.decode(data) {
            textView.attributedText = text
        } else if !model.plainText.isEmpty {
            textView.text = model.plainText
        }
        if textView.text.isEmpty {
            textView.typingAttributes = [.font: Self.defaultFont, .foregroundColor: UIColor.black]
        }
        textView.delegate = self
        addSubview(textView)

        moveHandle.contentMode = .center
        moveHandle.tintColor = .systemBlue
        moveHandle.backgroundColor = .white
        moveHandle.layer.cornerRadius = Self.handleSize / 2
        moveHandle.layer.borderWidth = 1
        moveHandle.layer.borderColor = UIColor.systemBlue.withAlphaComponent(0.6).cgColor
        moveHandle.isUserInteractionEnabled = true
        moveHandle.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(handleMove(_:))))
        addSubview(moveHandle)

        resizeGrip.backgroundColor = .systemBlue
        resizeGrip.layer.cornerRadius = 2
        resizeHandle.addSubview(resizeGrip)
        resizeHandle.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(handleResize(_:))))
        addSubview(resizeHandle)

        // Fingers only: the Pencil keeps writing into the box (Scribble).
        dragPan.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        dragPan.maximumNumberOfTouches = 1
        dragPan.delegate = self
        dragPan.addTarget(self, action: #selector(handleMove(_:)))
        addGestureRecognizer(dragPan)

        setEditingChrome(false)
        fitHeight()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func beginEditing() {
        textView.becomeFirstResponder()
    }

    /// Boxes sit inside a zoomed container, so they're scaled like an image.
    /// Rendering them at the zoom's pixel density keeps the text sharp.
    func setRenderScale(_ scale: CGFloat) {
        renderScale = scale
        applyRenderScale()
    }

    private func applyRenderScale() {
        guard renderScale > 0 else { return }
        func apply(to view: UIView) {
            if view.contentScaleFactor != renderScale { view.contentScaleFactor = renderScale }
            view.subviews.forEach { apply(to: $0) }
        }
        apply(to: self)
    }

    /// Moves or resizes the box (used by undo).
    func apply(origin: CGPoint, width: CGFloat) {
        frame = CGRect(origin: origin, size: CGSize(width: width, height: bounds.height))
        fitHeight()
        writeFrameToModel()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        textView.frame = bounds
        let handle = Self.handleSize
        moveHandle.frame = CGRect(x: -handle - 6, y: 0, width: handle, height: handle)
        resizeHandle.frame = CGRect(x: bounds.width - 12, y: 0, width: 24, height: bounds.height)
        resizeGrip.frame = CGRect(x: 10, y: max(0, bounds.height / 2 - 12), width: 4, height: min(24, bounds.height))
    }

    // The move handle sits outside the box, so widen the touch area while it shows.
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        if !moveHandle.isHidden, moveHandle.frame.insetBy(dx: -8, dy: -8).contains(point) { return true }
        if !resizeHandle.isHidden, resizeHandle.frame.contains(point) { return true }
        return super.point(inside: point, with: event)
    }

    private func fitHeight() {
        let fitting = textView.sizeThatFits(CGSize(width: bounds.width, height: .greatestFiniteMagnitude))
        let height = max(44, ceil(fitting.height))
        if abs(bounds.height - height) > 0.5 {
            frame.size.height = height
        }
    }

    private func writeFrameToModel() {
        model.x = frame.minX
        model.y = frame.minY
        model.width = frame.width
    }

    private func setEditingChrome(_ editing: Bool) {
        layer.borderWidth = editing ? 1 : 0
        moveHandle.isHidden = !editing
        resizeHandle.isHidden = !editing
        // While editing, a drag selects text; the handle moves the box instead.
        dragPan.isEnabled = !editing
    }

    /// A light lift while the box is being dragged.
    private func setLifted(_ lifted: Bool) {
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOffset = CGSize(width: 0, height: 3)
        layer.shadowRadius = 8
        layer.shadowOpacity = lifted ? 0.18 : 0
        backgroundColor = lifted ? UIColor.white.withAlphaComponent(0.6) : .clear
    }

    @objc private func handleMove(_ gesture: UIPanGestureRecognizer) {
        guard let container = superview else { return }
        switch gesture.state {
        case .began:
            frameAtGestureStart = frame
            setLifted(true)
        case .changed:
            let translation = gesture.translation(in: container)
            frame.origin = CGPoint(x: frameAtGestureStart.minX + translation.x, y: frameAtGestureStart.minY + translation.y)
        case .ended:
            setLifted(false)
            writeFrameToModel()
            delegate?.textBoxView(self, didMoveFrom: frameAtGestureStart)
        case .cancelled, .failed:
            setLifted(false)
            frame = frameAtGestureStart
        default:
            break
        }
    }

    @objc private func handleResize(_ gesture: UIPanGestureRecognizer) {
        guard let container = superview else { return }
        switch gesture.state {
        case .began:
            frameAtGestureStart = frame
        case .changed:
            let translation = gesture.translation(in: container)
            frame.size.width = max(Self.minimumWidth, frameAtGestureStart.width + translation.x)
            fitHeight()
        case .ended:
            writeFrameToModel()
            delegate?.textBoxView(self, didMoveFrom: frameAtGestureStart)
        case .cancelled, .failed:
            frame = frameAtGestureStart
            fitHeight()
        default:
            break
        }
    }
}

extension TextBoxView: UIGestureRecognizerDelegate {
    /// A drag that starts on a box moves the box, not the page under it.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        gestureRecognizer === dragPan && otherGestureRecognizer.view is UIScrollView && otherGestureRecognizer is UIPanGestureRecognizer
    }
}

extension TextBoxView: UITextViewDelegate {
    func textViewDidBeginEditing(_ textView: UITextView) {
        setEditingChrome(true)
    }

    func textViewDidEndEditing(_ textView: UITextView) {
        setEditingChrome(false)
        delegate?.textBoxViewDidEndEditing(self)
    }

    func textViewDidChange(_ textView: UITextView) {
        fitHeight()
        model.richText = RichText.encode(textView.attributedText)
        model.plainText = textView.text
        delegate?.textBoxViewDidChangeText(self)
        // New lines of text get new views; give them the zoom's density too.
        if renderScale > 0 {
            Task { [weak self] in self?.applyRenderScale() }
        }
    }

    func textView(_ textView: UITextView, editMenuForTextIn range: NSRange, suggestedActions: [UIMenuElement]) -> UIMenu? {
        let delete = UIAction(title: "Delete Text Box", image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in
            guard let self else { return }
            self.delegate?.textBoxViewDidRequestDelete(self)
        }
        return UIMenu(children: suggestedActions + [delete])
    }
}

// MARK: - Coordinator

/// Text-box bookkeeping shared by notebooks and PDFs: creating, deleting and
/// moving boxes, with undo. A new box only gets an undo step once you type
/// in it, so an empty box that disappears leaves nothing behind.
@MainActor
final class TextBoxCoordinator: TextBoxViewDelegate {
    struct Hooks {
        /// The window's shared undo manager.
        var undoManager: @MainActor () -> UndoManager?
        /// Connects a new box to its notebook or PDF.
        var attach: @MainActor (TextBox) -> Void
        /// Finds a live box by id (for undo when its view isn't on screen).
        var lookup: @MainActor (UUID) -> TextBox?
        /// The view a box goes in, or nil when its page isn't on screen.
        var container: @MainActor (TextBox) -> UIView?
        var contentChanged: @MainActor () -> Void
        var editingEnded: @MainActor () -> Void
    }

    private let modelContext: ModelContext
    private let hooks: Hooks
    private(set) var views: [UUID: TextBoxView] = [:]
    private var newEmptyBoxes: Set<UUID> = []

    /// Pixel density for box contents (zoom × screen scale), so text stays
    /// sharp when the container is zoomed in.
    var renderScale: CGFloat = 0 {
        didSet {
            guard abs(renderScale - oldValue) > 0.01 else { return }
            for boxView in views.values { boxView.setRenderScale(renderScale) }
        }
    }

    init(modelContext: ModelContext, hooks: Hooks) {
        self.modelContext = modelContext
        self.hooks = hooks
    }

    /// Render scale for a container zoomed by `zoom`. Never below the
    /// screen's own scale, and capped to keep memory in check.
    static func scale(forZoom zoom: CGFloat, displayScale: CGFloat) -> CGFloat {
        min(max(zoom, 1) * displayScale, 8)
    }

    var editingBox: TextBoxView? {
        views.values.first { $0.textView.isFirstResponder }
    }

    var allViews: [TextBoxView] { Array(views.values) }

    @discardableResult
    func showView(for box: TextBox) -> TextBoxView? {
        if let existing = views[box.id] { return existing }
        guard let container = hooks.container(box) else { return nil }
        let boxView = TextBoxView(model: box)
        boxView.delegate = self
        container.addSubview(boxView)
        if renderScale > 0 { boxView.setRenderScale(renderScale) }
        views[box.id] = boxView
        return boxView
    }

    /// Drops the views inside a container that is going away (a PDF page
    /// scrolled off screen). The models stay.
    func forgetViews(in container: UIView) {
        for case let boxView as TextBoxView in container.subviews {
            if boxView.textView.isFirstResponder { boxView.textView.resignFirstResponder() }
            views[boxView.boxID] = nil
        }
    }

    func createBox(at origin: CGPoint, width: CGFloat, pageIndex: Int? = nil, initialText: String? = nil) {
        let box = TextBox(x: origin.x, y: origin.y, width: width, pageIndex: pageIndex)
        modelContext.insert(box)
        hooks.attach(box)
        guard let boxView = showView(for: box) else { return }
        newEmptyBoxes.insert(box.id)
        boxView.beginEditing()
        if let initialText {
            boxView.textView.insertText(initialText)
        }
    }

    func removeBox(id: UUID, undoable: Bool) {
        guard let box = views[id]?.model ?? hooks.lookup(id), !box.isDeleted else { return }
        let snapshot = TextBoxSnapshot(box)
        if let boxView = views.removeValue(forKey: id) {
            boxView.textView.resignFirstResponder()
            boxView.removeFromSuperview()
        }
        modelContext.delete(box)
        if undoable {
            hooks.undoManager()?.registerUndo(withTarget: self) { target in
                MainActor.assumeIsolated { target.restore(snapshot) }
            }
        }
        hooks.contentChanged()
    }

    private func restore(_ snapshot: TextBoxSnapshot) {
        let box = snapshot.makeModel()
        modelContext.insert(box)
        hooks.attach(box)
        showView(for: box)
        let id = snapshot.id
        hooks.undoManager()?.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated { target.removeBox(id: id, undoable: true) }
        }
        hooks.contentChanged()
    }

    private func registerFrameUndo(id: UUID, frame: CGRect) {
        hooks.undoManager()?.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated { target.setFrame(frame, forBox: id) }
        }
    }

    private func setFrame(_ frame: CGRect, forBox id: UUID) {
        guard let box = views[id]?.model ?? hooks.lookup(id), !box.isDeleted else { return }
        registerFrameUndo(id: id, frame: CGRect(x: box.x, y: box.y, width: box.width, height: 0))
        if let boxView = views[id] {
            boxView.apply(origin: frame.origin, width: frame.width)
        } else {
            box.x = frame.minX
            box.y = frame.minY
            box.width = frame.width
        }
        hooks.contentChanged()
    }

    // MARK: TextBoxViewDelegate

    func textBoxViewDidChangeText(_ boxView: TextBoxView) {
        if newEmptyBoxes.remove(boxView.boxID) != nil {
            let id = boxView.boxID
            hooks.undoManager()?.registerUndo(withTarget: self) { target in
                MainActor.assumeIsolated { target.removeBox(id: id, undoable: true) }
            }
        }
        hooks.contentChanged()
    }

    func textBoxViewDidEndEditing(_ boxView: TextBoxView) {
        guard views[boxView.boxID] === boxView else { return }
        if boxView.isEmpty {
            let wasNew = newEmptyBoxes.remove(boxView.boxID) != nil
            removeBox(id: boxView.boxID, undoable: !wasNew)
        }
        hooks.editingEnded()
    }

    func textBoxView(_ boxView: TextBoxView, didMoveFrom oldFrame: CGRect) {
        registerFrameUndo(id: boxView.boxID, frame: oldFrame)
        hooks.contentChanged()
    }

    func textBoxViewDidRequestDelete(_ boxView: TextBoxView) {
        let wasNew = newEmptyBoxes.remove(boxView.boxID) != nil
        removeBox(id: boxView.boxID, undoable: !wasNew)
    }
}

// MARK: - Helpers

/// A container that only takes touches that land on one of its subviews.
class PassthroughView: UIView {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit === self ? nil : hit
    }
}

extension UIView {
    /// The text box this view belongs to, if any.
    var enclosingTextBox: TextBoxView? {
        var view: UIView? = self
        while let current = view {
            if let box = current as? TextBoxView { return box }
            view = current.superview
        }
        return nil
    }

    func firstSubview<T: UIView>(ofType type: T.Type) -> T? {
        for subview in subviews {
            if let match = subview as? T { return match }
            if let match = subview.firstSubview(ofType: type) { return match }
        }
        return nil
    }
}
