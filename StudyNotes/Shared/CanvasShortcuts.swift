import PencilKit
import UIKit

/// Switches back to the last pen after erasing, like Notability: pick the
/// eraser, rub something out, lift the Pencil, and you're back on the pen.
///
/// Call `canvasDidEndUsingTool()` from `canvasViewDidEndUsingTool(_:)`.
@MainActor
final class EraserAutoReturn: NSObject, PKToolPickerObserver {
    private weak var toolPicker: PKToolPicker?
    /// The inking item (pen, pencil, marker…) in use before the eraser.
    private var lastInkingItemIdentifier: String?

    init(toolPicker: PKToolPicker) {
        self.toolPicker = toolPicker
        super.init()
        remember(toolPicker.selectedToolItem)
        toolPicker.addObserver(self)
    }

    func stop() {
        toolPicker?.removeObserver(self)
    }

    func toolPickerSelectedToolItemDidChange(_ toolPicker: PKToolPicker) {
        remember(toolPicker.selectedToolItem)
    }

    func canvasDidEndUsingTool() {
        guard let toolPicker,
              toolPicker.selectedToolItem is PKToolPickerEraserItem,
              let identifier = lastInkingItemIdentifier else { return }
        toolPicker.selectedToolItemIdentifier = identifier
    }

    private func remember(_ item: PKToolPickerItem) {
        if item is PKToolPickerInkingItem {
            lastInkingItemIdentifier = item.identifier
        }
    }
}

/// Keeps the Apple Pencil working with the page when the page lost the
/// keyboard focus (the study pal's chat field took it, say) or its pen
/// palette is hidden with the toolbars.
///
/// PencilKit handles a double-tap or squeeze only while the palette shows
/// for the focused page. Without that, a squeeze brought up the system's
/// text bar (undo and redo) and a double-tap did nothing. Now:
/// - The Pencil hovering over or touching the page gives it the focus back,
///   and its palette with it.
/// - A double-tap does what's set in Settings (eraser, last tool), palette
///   or not.
/// - A squeeze brings the palette back (and the toolbars, if hidden).
@MainActor
final class PencilFocusKeeper: NSObject, UIPencilInteractionDelegate, PKToolPickerObserver, UIGestureRecognizerDelegate {
    private weak var toolPicker: PKToolPicker?
    private weak var view: UIView?
    private let pencil = UIPencilInteraction()
    private lazy var hover = UIHoverGestureRecognizer(target: self, action: #selector(handleHover(_:)))
    /// The page has the focus and its palette shows, so PencilKit handles
    /// the Pencil itself.
    private let isHandledByPalette: @MainActor () -> Bool
    /// Gives the page the focus back, if it should have it now (nothing
    /// else being typed in on it). Returns whether it did.
    private let reclaim: @MainActor () -> Bool
    /// Shows the toolbars and the palette, if they're hidden (a squeeze
    /// asks for the palette). Does nothing when they show.
    private let showToolbars: @MainActor () -> Void
    private var currentItemIdentifier: String?
    private var previousItemIdentifier: String?
    nonisolated(unsafe) private var focusObserver: NSObjectProtocol?

    init(
        on view: UIView,
        toolPicker: PKToolPicker,
        isHandledByPalette: @escaping @MainActor () -> Bool,
        reclaim: @escaping @MainActor () -> Bool,
        showToolbars: @escaping @MainActor () -> Void
    ) {
        self.view = view
        self.toolPicker = toolPicker
        self.isHandledByPalette = isHandledByPalette
        self.reclaim = reclaim
        self.showToolbars = showToolbars
        super.init()
        currentItemIdentifier = toolPicker.selectedToolItemIdentifier
        toolPicker.addObserver(self)
        pencil.delegate = self
        view.addInteraction(pencil)
        hover.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.pencil.rawValue)]
        hover.delegate = self
        view.addGestureRecognizer(hover)
        // Something let go of the focus on purpose (the study pal's chat
        // closed or sent): the page on screen takes it back.
        focusObserver = NotificationCenter.default.addObserver(forName: PageFocus.giveBack, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.view?.window?.isKeyWindow == true else { return }
                _ = self.reclaim()
            }
        }
    }

    deinit {
        if let focusObserver { NotificationCenter.default.removeObserver(focusObserver) }
    }

    func stop() {
        toolPicker?.removeObserver(self)
        if let focusObserver { NotificationCenter.default.removeObserver(focusObserver) }
        focusObserver = nil
        view?.removeInteraction(pencil)
        view?.removeGestureRecognizer(hover)
    }

    /// The Pencil touched the page.
    func pencilTouchedPage() {
        if !isHandledByPalette() { _ = reclaim() }
    }

    @objc private func handleHover(_ gesture: UIHoverGestureRecognizer) {
        guard gesture.state == .began, !isHandledByPalette() else { return }
        _ = reclaim()
    }

    // MARK: Pencil gestures

    func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveTap tap: UIPencilInteraction.Tap) {
        guard !isHandledByPalette(), let toolPicker else { return }
        let before = toolPicker.selectedToolItemIdentifier
        let action = UIPencilInteraction.preferredTapAction
        _ = reclaim()
        // A turn later: if PencilKit did it after all, don't do it twice.
        Task { @MainActor [weak self] in
            guard let self, let toolPicker = self.toolPicker,
                  toolPicker.selectedToolItemIdentifier == before else { return }
            self.perform(action, on: toolPicker)
        }
    }

    func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveSqueeze squeeze: UIPencilInteraction.Squeeze) {
        guard squeeze.phase == .ended, !isHandledByPalette() else { return }
        switch UIPencilInteraction.preferredSqueezeAction {
        case .ignore, .runSystemShortcut:
            return
        case .switchEraser, .switchPrevious:
            _ = reclaim()
            if let toolPicker { perform(UIPencilInteraction.preferredSqueezeAction, on: toolPicker) }
        default:
            // The palette: bring it back where it was.
            if reclaim() { showToolbars() }
        }
    }

    private func perform(_ action: UIPencilPreferredAction, on toolPicker: PKToolPicker) {
        switch action {
        case .switchEraser:
            if toolPicker.selectedToolItem is PKToolPickerEraserItem {
                if let previous = previousItemIdentifier ?? toolPicker.toolItems.first(where: { $0 is PKToolPickerInkingItem })?.identifier {
                    toolPicker.selectedToolItemIdentifier = previous
                }
            } else if let eraser = toolPicker.toolItems.first(where: { $0 is PKToolPickerEraserItem }) {
                toolPicker.selectedToolItemIdentifier = eraser.identifier
            }
        case .switchPrevious:
            if let previousItemIdentifier {
                toolPicker.selectedToolItemIdentifier = previousItemIdentifier
            }
        case .showColorPalette, .showInkAttributes, .showContextualPalette:
            showToolbars()
        default:
            break
        }
    }

    // Only watching: PencilKit's own hover preview keeps working.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        true
    }

    // MARK: PKToolPickerObserver

    func toolPickerSelectedToolItemDidChange(_ toolPicker: PKToolPicker) {
        let identifier = toolPicker.selectedToolItemIdentifier
        guard identifier != currentItemIdentifier else { return }
        previousItemIdentifier = currentItemIdentifier
        currentItemIdentifier = identifier
    }
}

/// Handing the keyboard focus back to the page on screen.
enum PageFocus {
    static let giveBack = Notification.Name("StudyNotes.PageFocus.giveBack")

    /// Something (the study pal's chat) is done with the focus: the page in
    /// the key window takes it back, so the Pencil's palette, double-tap and
    /// squeeze work again. Waits a moment for the field to let go.
    @MainActor
    static func returnToPage() {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            NotificationCenter.default.post(name: giveBack, object: nil)
        }
    }
}

/// Procreate's shortcuts: tap with two fingers to undo, three to redo.
@MainActor
final class UndoTapGestures: NSObject {
    private let undoTap = UITapGestureRecognizer()
    private let redoTap = UITapGestureRecognizer()
    private let undo: @MainActor () -> Bool
    private let redo: @MainActor () -> Bool
    private weak var toastHost: UIView?

    /// `undo` and `redo` return whether there was anything to undo or redo.
    init(on view: UIView, toastHost: UIView, undo: @escaping @MainActor () -> Bool, redo: @escaping @MainActor () -> Bool) {
        self.undo = undo
        self.redo = redo
        self.toastHost = toastHost
        super.init()
        let fingers = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        undoTap.numberOfTouchesRequired = 2
        undoTap.allowedTouchTypes = fingers
        undoTap.addTarget(self, action: #selector(handleUndo(_:)))
        redoTap.numberOfTouchesRequired = 3
        redoTap.allowedTouchTypes = fingers
        redoTap.addTarget(self, action: #selector(handleRedo(_:)))
        view.addGestureRecognizer(undoTap)
        view.addGestureRecognizer(redoTap)
    }

    @objc private func handleUndo(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended, undo(), let toastHost else { return }
        ShortcutToast.show("Undo", in: toastHost)
    }

    @objc private func handleRedo(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended, redo(), let toastHost else { return }
        ShortcutToast.show("Redo", in: toastHost)
    }
}

/// A small pill near the top of the screen that fades out, for "Undo" and "Redo".
@MainActor
enum ShortcutToast {
    private static let tag = 0x7057

    static func show(_ text: String, in host: UIView) {
        host.viewWithTag(tag)?.removeFromSuperview()

        let label = UILabel()
        label.text = text
        label.font = .systemFont(ofSize: 15, weight: .semibold)
        label.textColor = .white
        label.sizeToFit()

        let pill = UIView(frame: CGRect(x: 0, y: 0, width: label.bounds.width + 32, height: label.bounds.height + 14))
        pill.tag = tag
        pill.isUserInteractionEnabled = false
        pill.backgroundColor = UIColor.black.withAlphaComponent(0.72)
        pill.layer.cornerRadius = pill.bounds.height / 2
        label.center = CGPoint(x: pill.bounds.midX, y: pill.bounds.midY)
        pill.addSubview(label)
        pill.center = CGPoint(x: host.bounds.midX, y: host.safeAreaInsets.top + 36)
        pill.alpha = 0
        host.addSubview(pill)

        UIView.animate(withDuration: 0.15, animations: {
            pill.alpha = 1
        }, completion: { _ in
            UIView.animate(withDuration: 0.3, delay: 0.6, options: [], animations: {
                pill.alpha = 0
            }, completion: { _ in
                pill.removeFromSuperview()
            })
        })
    }
}
