import SwiftUI

/// The page's zoom in the corner, as in Figma: − and + step through the
/// zoom levels, and the percentage opens a menu (100%, fit everything,
/// 50%, 200%). It shows only while you zoom, and fades a couple of seconds
/// after you stop; using it keeps it up.
struct ZoomControl: View {
    let editor: NotebookEditor

    @State private var isVisible = false
    @State private var hideTask: Task<Void, Never>?
    /// The page's first zoom, as it opens, isn't you zooming.
    @State private var hasSeenFirstZoom = false

    var body: some View {
        HStack(spacing: 0) {
            Button { editor.zoomOut() } label: {
                Image(systemName: "minus")
                    .frame(width: 36, height: 36)
                    .contentShape(.rect)
            }
            .accessibilityLabel("Zoom Out")
            Menu {
                Button("Zoom to 100%") { editor.zoom(to: 1) }
                Button("Zoom to Fit") { editor.zoomToFit() }
                Divider()
                Button("Zoom to 50%") { editor.zoom(to: 0.5) }
                Button("Zoom to 200%") { editor.zoom(to: 2) }
            } label: {
                Text(percent)
                    .font(.subheadline.weight(.medium))
                    .monospacedDigit()
                    .frame(minWidth: 52, minHeight: 36)
                    .contentShape(.rect)
            }
            .accessibilityLabel("Zoom \(percent)")
            Button { editor.zoomIn() } label: {
                Image(systemName: "plus")
                    .frame(width: 36, height: 36)
                    .contentShape(.rect)
            }
            .accessibilityLabel("Zoom In")
        }
        .buttonStyle(.plain)
        .font(.subheadline.weight(.semibold))
        .padding(.horizontal, 4)
        .glassEffect(.regular, in: .capsule)
        .opacity(isVisible ? 1 : 0)
        .allowsHitTesting(isVisible)
        .animation(.easeInOut(duration: 0.25), value: isVisible)
        .onChange(of: editor.zoomScale) {
            guard hasSeenFirstZoom else {
                hasSeenFirstZoom = true
                return
            }
            show()
        }
        // A touch on it (opening the menu, say) keeps it up too.
        .simultaneousGesture(TapGesture().onEnded { show() })
    }

    private var percent: String {
        "\(Int((editor.zoomScale * 100).rounded()))%"
    }

    /// Shows it, and hides it once the zoom has been still for a moment.
    private func show() {
        isVisible = true
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            isVisible = false
        }
    }
}
