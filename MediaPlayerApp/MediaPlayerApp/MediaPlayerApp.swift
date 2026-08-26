import SwiftUI

@main
struct MediaPlayerApp: App {

    // One instance of each, owned by the app and injected downward. The previous
    // version created a fresh `AudioManager()` here *and* exposed an unused
    // `AudioManager.shared`, so there were two engines and it was ambiguous
    // which one any given call site was talking to.
    @StateObject private var engine = PlayerEngine()
    @StateObject private var library = Library()
    @StateObject private var registry = SourceRegistry.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(engine)
                .environmentObject(library)
                .environmentObject(registry)
                .tint(.accentColor)
        }
    }
}
