import SwiftUI
import WorkspaceKit
import WorkspaceUI

@main
struct WorkspaceApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .preferredColorScheme(.dark)
        }
        #if os(macOS)
        .defaultSize(width: 1200, height: 780)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Sync Now") { Task { await model.syncNow() } }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
            }
            CommandMenu("Debug") {
                Button("Load Sample Data") { model.loadSampleData() }
            }
        }
        #endif
    }
}
