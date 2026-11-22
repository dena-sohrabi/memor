import UIKit

/// The small marker left where you circled something and asked Claude.
/// Tap it to reopen the saved chat. Press and hold to pick it up: drag it
/// somewhere else, or let go without moving for Open Chat and Delete Chat.
final class AskMarkerButton: UIButton, UIGestureRecognizerDelegate, UIEditMenuInteractionDelegate {
    static let size: CGFloat = 30
    let threadID: UUID

    private let onOpen: @MainActor () -> Void
    private let onDelete: @MainActor () -> Void
    /// The marker was dragged; gets the new anchor (the circled area's
    /// top-right corner it now points at).
    private let onMove: @MainActor (CGPoint) -> Void

    private lazy var hold = UILongPressGestureRecognizer(target: self, action: #selector(handleHold(_:)))
    private lazy var editMenu = UIEditMenuInteraction(delegate: self)
    private var grabOffset = CGSize.zero
    private var startCenter = CGPoint.zero

    init(
        threadID: UUID,
        onOpen: @escaping @MainActor () -> Void,
        onDelete: @escaping @MainActor () -> Void,
        onMove: @escaping @MainActor (CGPoint) -> Void
    ) {
        self.threadID = threadID
        self.onOpen = onOpen
        self.onDelete = onDelete
        self.onMove = onMove
        super.init(frame: CGRect(x: 0, y: 0, width: Self.size, height: Self.size))

        var configuration = UIButton.Configuration.filled()
        configuration.image = UIImage(systemName: "sparkles", withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold))
        configuration.baseBackgroundColor = .systemIndigo
        configuration.baseForegroundColor = .white
        configuration.cornerStyle = .capsule
        configuration.contentInsets = .zero
        self.configuration = configuration

        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.2
        layer.shadowRadius = 3
        layer.shadowOffset = CGSize(width: 0, height: 1)
        accessibilityLabel = "Ask Claude chat"
        accessibilityHint = "Opens the saved chat. Touch and hold to move or delete it."

        addAction(UIAction { _ in onOpen() }, for: .primaryActionTriggered)

        hold.minimumPressDuration = 0.3
        // Fingers only: the Pencil writes.
        hold.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        hold.delegate = self
        addGestureRecognizer(hold)
        addInteraction(editMenu)

        accessibilityCustomActions = [
            UIAccessibilityCustomAction(name: "Delete Chat") { _ in
                MainActor.assumeIsolated { onDelete() }
                return true
            },
        ]
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Sits just above and to the right of the circled area's top-right corner.
    func place(at anchor: CGPoint) {
        center = CGPoint(x: anchor.x + 6, y: anchor.y - 6)
    }

    private var anchor: CGPoint {
        CGPoint(x: center.x - 6, y: center.y + 6)
    }

    // MARK: Hold to move

    @objc private func handleHold(_ gesture: UILongPressGestureRecognizer) {
        guard let container = superview else { return }
        let location = gesture.location(in: container)
        switch gesture.state {
        case .began:
            startCenter = center
            grabOffset = CGSize(width: center.x - location.x, height: center.y - location.y)
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            UIView.animate(withDuration: 0.18) {
                self.transform = CGAffineTransform(scaleX: 1.3, y: 1.3)
                self.layer.shadowOpacity = 0.35
                self.layer.shadowRadius = 6
            }
        case .changed:
            var point = CGPoint(x: location.x + grabOffset.width, y: location.y + grabOffset.height)
            // On a PDF page, the marker stays on its page. (A notebook page
            // is practically endless.)
            if container.bounds.width > 0, container.bounds.width < 50_000 {
                point.x = min(max(point.x, 0), container.bounds.width)
                point.y = min(max(point.y, 0), container.bounds.height)
            }
            center = point
        case .ended:
            putDown()
            if hypot(center.x - startCenter.x, center.y - startCenter.y) > 6 {
                onMove(anchor)
            } else {
                editMenu.presentEditMenu(with: UIEditMenuConfiguration(
                    identifier: nil,
                    sourcePoint: CGPoint(x: bounds.midX, y: bounds.minY)
                ))
            }
        case .cancelled, .failed:
            putDown()
            center = startCenter
        default:
            break
        }
    }

    private func putDown() {
        UIView.animate(withDuration: 0.25, delay: 0, usingSpringWithDamping: 0.6, initialSpringVelocity: 0) {
            self.transform = .identity
            self.layer.shadowOpacity = 0.2
            self.layer.shadowRadius = 3
        }
    }

    /// While you hold the marker, the page doesn't scroll under your finger.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        otherGestureRecognizer is UIPanGestureRecognizer
    }

    // MARK: Menu

    func editMenuInteraction(_ interaction: UIEditMenuInteraction, menuFor configuration: UIEditMenuConfiguration, suggestedActions: [UIMenuElement]) -> UIMenu? {
        UIMenu(children: [
            UIAction(title: "Open Chat", image: UIImage(systemName: "bubble.left.and.text.bubble.right")) { [onOpen] _ in onOpen() },
            UIAction(title: "Delete Chat", image: UIImage(systemName: "trash"), attributes: .destructive) { [onDelete] _ in onDelete() },
        ])
    }
}
