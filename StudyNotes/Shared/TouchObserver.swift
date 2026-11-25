import UIKit
import UIKit.UIGestureRecognizerSubclass

/// Notices a finger or Pencil touching a view without taking part: it never
/// recognizes anything, so drawing, scrolling and every other gesture work
/// as before. Each side of a tab uses it to become the side you're using.
final class TouchObserver: UIGestureRecognizer {
    private let onTouch: @MainActor () -> Void

    init(onTouch: @escaping @MainActor () -> Void) {
        self.onTouch = onTouch
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        onTouch()
        state = .failed
    }

    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }
}
