import SwiftData
import UIKit

@MainActor
protocol TextBoxViewDelegate: AnyObject {
    func textBoxViewDidChangeText(_ boxView: TextBoxView)
    func textBoxViewDidEndEditing(_ boxView: TextBoxView)
    func textBoxView(_ boxView: TextBoxView, didMoveFrom oldFrame: CGRect)
    func textBoxViewDidRequestDelete(_ boxView: TextBoxView)
    func textBoxViewDidRequestSelect(_ boxView: TextBoxView)
}

/// A text view with its own undo stack. Typing undo stays inside the box, so
/// the shared undo stack never points at a box that was deleted.
final class BoxTextView: UITextView {
    private let ownUndoManager = UndoManager()
    override var undoManager: UndoManager? { ownUndoManager }
}

/// A typed text box on a notebook canvas or a PDF page.
///
/// Tap it once to select it (a border appears) and then drag it with a
/// finger to move it; tap it again to type. An unselected box ignores drags,
/// so the page scrolls as usual, and lets the Pencil write over it. While
/// editing, it shows a move handle on the left and a resize strip on the
/// right edge. Its height follows the text. It writes position and text
/// straight into its `TextBox` model; the delegate saves.
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
    /// Moves the whole box with a finger while it's selected.
    private let dragPan = UIPanGestureRecognizer()
    /// First tap selects, the next one starts typing.
    private let selectTap = UITapGestureRecognizer()
    private var isEditingText = false
    private var frameAtGestureStart: CGRect = .zero

    var isSelected = false {
        didSet { updateChrome() }
    }
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
        // Taps go to the box until it's being edited (see `selectTap`).
        textView.isUserInteractionEnabled = false
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

        selectTap.addTarget(self, action: #selector(handleSelectTap(_:)))
        addGestureRecognizer(selectTap)

        updateChrome()
        fitHeight()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Starts typing, with the cursor at `point` (in the text view) if given.
    func beginEditing(at point: CGPoint? = nil) {
        textView.isUserInteractionEnabled = true
        textView.becomeFirstResponder()
        if let point, let position = textView.closestPosition(to: point) {
            textView.selectedTextRange = textView.textRange(from: position, to: position)
        }
    }

    @objc private func handleSelectTap(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended, !isEditingText else { return }
        if isSelected {
            beginEditing(at: gesture.location(in: textView))
        } else {
            delegate?.textBoxViewDidRequestSelect(self)
        }
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

    /// Shows the model's text again after it was changed from outside.
    func reloadText() {
        if let data = model.richText, let text = RichText.decode(data) {
            textView.attributedText = text
        } else {
            textView.text = model.plainText
        }
        fitHeight()
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

    // The move handle sits outside the box, so widen the touch area while it
    // shows. A Pencil touching a box that isn't being edited passes through,
    // so you can write over typed text.
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        if !isEditingText, event?.allTouches?.contains(where: { $0.type == .pencil && $0.phase == .began }) == true {
            return false
        }
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

    private func updateChrome() {
        let showsFrame = isEditingText || isSelected
        layer.borderWidth = showsFrame ? 1.5 : 0
        moveHandle.isHidden = !isEditingText
        resizeHandle.isHidden = !showsFrame
        // Only a selected box moves by dragging. While editing, a drag selects
        // text and the handle moves the box instead.
        dragPan.isEnabled = isSelected && !isEditingText
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
        isEditingText = true
        updateChrome()
    }

    func textViewDidEndEditing(_ textView: UITextView) {
        isEditingText = false
        textView.isUserInteractionEnabled = false
        isSelected = false
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
        /// Where a box made or dragged at a frame (in its container's
        /// points) ends up instead: on a paper sheet, in a notebook in Pages
        /// mode. Nil leaves boxes where they're put.
        var keepOnPaper: (@MainActor (CGRect) -> CGRect)? = nil
    }

    private let modelContext: ModelContext
    private let hooks: Hooks
    private(set) var views: [UUID: TextBoxView] = [:]
    private var newEmptyBoxes: Set<UUID> = []
    /// The one box that's selected (tapped once), if any.
    private weak var selectedView: TextBoxView?

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

    /// A box is selected (tapped once) or being typed in.
    var hasSelection: Bool {
        selectedView != nil || editingBox != nil
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
        clearSelection()
        let origin = placedOrigin(origin, width: width)
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

    /// Puts a box with ready-made text on the page (from Ask Claude or a
    /// paste) without starting to type in it, in `font` and `color`. Undo
    /// removes it.
    @discardableResult
    func insertBox(
        at origin: CGPoint,
        width: CGFloat,
        text: String,
        pageIndex: Int? = nil,
        font: UIFont = TextBoxView.defaultFont,
        color: UIColor = .black
    ) -> UUID? {
        let origin = placedOrigin(origin, width: width)
        let box = TextBox(x: origin.x, y: origin.y, width: width, pageIndex: pageIndex)
        let attributed = NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: color,
        ])
        box.richText = RichText.encode(attributed)
        box.plainText = text
        modelContext.insert(box)
        hooks.attach(box)
        guard showView(for: box) != nil else {
            modelContext.delete(box)
            return nil
        }
        let id = box.id
        hooks.undoManager()?.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated { target.removeBox(id: id, undoable: true) }
        }
        hooks.contentChanged()
        return id
    }

    /// Where a new box `width` wide goes when it's asked for at `origin`.
    private func placedOrigin(_ origin: CGPoint, width: CGFloat) -> CGPoint {
        guard let keepOnPaper = hooks.keepOnPaper else { return origin }
        return keepOnPaper(CGRect(origin: origin, size: CGSize(width: width, height: 44))).origin
    }

    /// The model for a box, whether or not its view is on screen.
    func box(_ id: UUID) -> TextBox? {
        guard let box = views[id]?.model ?? hooks.lookup(id), !box.isDeleted else { return nil }
        return box
    }

    /// The box's height on screen, or an estimate when its page isn't showing.
    func height(of id: UUID) -> CGFloat {
        views[id]?.bounds.height ?? 44
    }

    /// Moves and/or resizes a box, with undo. Returns false if it's gone.
    @discardableResult
    func setBoxFrame(id: UUID, origin: CGPoint? = nil, width: CGFloat? = nil) -> Bool {
        guard let box = box(id) else { return false }
        let frame = CGRect(
            x: origin?.x ?? CGFloat(box.x),
            y: origin?.y ?? CGFloat(box.y),
            width: max(80, width ?? CGFloat(box.width)),
            height: 0
        )
        setFrame(frame, forBox: id)
        return true
    }

    /// Replaces a box's text, with undo. Returns false if it's gone.
    @discardableResult
    func replaceText(id: UUID, with text: String) -> Bool {
        guard let box = box(id) else { return false }
        // The new text keeps the look of the old.
        let old = box.richText.flatMap(RichText.decode)
        let style = (old?.length ?? 0) > 0 ? old?.attributes(at: 0, effectiveRange: nil) : nil
        let attributed = NSAttributedString(string: text, attributes: [
            .font: style?[.font] as? UIFont ?? TextBoxView.defaultFont,
            .foregroundColor: style?[.foregroundColor] as? UIColor ?? UIColor.black,
        ])
        applyText(id: id, richText: RichText.encode(attributed), plainText: text)
        return true
    }

    /// Colors all of a box's text, with undo. Returns false if it's gone.
    @discardableResult
    func setColor(id: UUID, to color: UIColor) -> Bool {
        guard let box = box(id) else { return false }
        let old = box.richText.flatMap(RichText.decode)
            ?? NSAttributedString(string: box.plainText, attributes: [.font: TextBoxView.defaultFont])
        let colored = NSMutableAttributedString(attributedString: old)
        colored.addAttribute(.foregroundColor, value: color, range: NSRange(location: 0, length: colored.length))
        applyText(id: id, richText: RichText.encode(colored), plainText: box.plainText)
        // What's typed next in it comes out the same color.
        views[id]?.textView.typingAttributes[.foregroundColor] = color
        return true
    }

    /// The color most of a box's text is in (its first letter's).
    func color(of id: UUID) -> UIColor? {
        guard let text = box(id)?.richText.flatMap(RichText.decode), text.length > 0 else { return nil }
        return text.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? UIColor
    }

    private func applyText(id: UUID, richText: Data?, plainText: String) {
        guard let box = box(id) else { return }
        let previousRich = box.richText
        let previousPlain = box.plainText
        box.richText = richText
        box.plainText = plainText
        views[id]?.reloadText()
        hooks.undoManager()?.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated { target.applyText(id: id, richText: previousRich, plainText: previousPlain) }
        }
        hooks.contentChanged()
    }

    func clearSelection() {
        selectedView?.isSelected = false
        selectedView = nil
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
        // Dragged off the paper: it slides back onto the sheet.
        if let keepOnPaper = hooks.keepOnPaper {
            let kept = keepOnPaper(boxView.frame)
            if kept.origin != boxView.frame.origin || kept.width != boxView.frame.width {
                UIView.animate(withDuration: 0.25, delay: 0, options: [.curveEaseOut]) {
                    boxView.apply(origin: kept.origin, width: kept.width)
                }
            }
        }
        hooks.contentChanged()
    }

    func textBoxViewDidRequestSelect(_ boxView: TextBoxView) {
        clearSelection()
        editingBox?.textView.resignFirstResponder()
        boxView.isSelected = true
        selectedView = boxView
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
