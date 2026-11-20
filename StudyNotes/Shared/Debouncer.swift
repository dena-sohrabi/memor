import Foundation

/// Runs the latest scheduled action once things have been quiet for a moment.
/// Used for autosave: edits schedule a save, and `flush()` runs it right away
/// when a window goes to the background or closes.
@MainActor
final class Debouncer {
    private var task: Task<Void, Never>?
    private var pending: (@MainActor () -> Void)?

    func schedule(after delay: Duration = .seconds(1), _ action: @escaping @MainActor () -> Void) {
        pending = action
        task?.cancel()
        task = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    /// Runs the pending action now, if there is one.
    func flush() {
        task?.cancel()
        task = nil
        let action = pending
        pending = nil
        action?()
    }

    func cancel() {
        task?.cancel()
        task = nil
        pending = nil
    }
}
