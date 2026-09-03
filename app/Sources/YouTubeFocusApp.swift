// YouTube Full Focus — application entry point.

import SwiftUI

@main
struct YouTubeFocusApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .commands {
            // A single-window utility: drop the menu items that do not apply.
            CommandGroup(replacing: .newItem) {}
        }
    }
}
