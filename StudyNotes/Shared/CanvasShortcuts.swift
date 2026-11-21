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
