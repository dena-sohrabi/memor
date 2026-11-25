import SwiftUI

/// A notebook or PDF in a window of its own, opened with Open in New Window.
/// Put it beside the main window (or another one) to see both at once. The
/// study pal sits on top while it's the window you're using.
struct ItemWindow: View {
    let target: OpenTarget?
    @Environment(\.openWindow) private var openWindow
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            if let target {
                ItemScreen(target: target)
            } else {
                DeletedItemView(kind: "item")
            }
        }
        .environment(\.isInItemWindow, true)
        .overlay { PalOverlay() }
        .onAppear {
            AppNavigator.shared.openWindow = openWindow
            if let target { AppNavigator.shared.itemWindowAppeared(target) }
        }
        .onDisappear {
            if let target { AppNavigator.shared.itemWindowDisappeared(target) }
        }
        // The window you're using opens windows (another may have closed).
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { AppNavigator.shared.openWindow = openWindow }
        }
    }
}
