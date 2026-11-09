import SwiftUI
import WorkspaceKit
import WorkspaceUI

@main
struct WorkspaceApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .preferredColorScheme(.dark)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { model.appBecameActive() }
        }
        #if os(macOS)
        .defaultSize(width: 1200, height: 780)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Task…") { model.quickAdd = QuickAddRequest() }
                    .keyboardShortcut("n")
                Button("Go to…") { model.showPalette = true }
                    .keyboardShortcut("k")
                Divider()
                Button("Sync Now") { Task { await model.syncNow() } }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
            }
            CommandGroup(after: .sidebar) {
                Button(model.showInspector ? "Hide Details" : "Show Details") { model.toggleInspector() }
                    .keyboardShortcut("i")
                Divider()
                Button("Previous Week") { model.shiftWeek(-1) }
                    .keyboardShortcut("[")
                Button("Next Week") { model.shiftWeek(1) }
                    .keyboardShortcut("]")
                Button("This Week") { model.goToThisWeek() }
                    .keyboardShortcut("t")
            }
            CommandMenu("Debug") {
                Button("Load Sample Data") { model.loadSampleData() }
            }
        }
        #endif
    }
}
