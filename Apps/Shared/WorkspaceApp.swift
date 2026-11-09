import SwiftUI
import WorkspaceKit
import WorkspaceUI

@main
struct WorkspaceApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            Group {
                #if os(iOS)
                PhoneRootView()
                #else
                RootView()
                #endif
            }
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
                Button("Manage Tags…") { model.showTagManager = true }
                    .keyboardShortcut("t", modifiers: [.command, .shift])
                Divider()
                Button("Sync Now") { Task { await model.syncNow() } }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
            }
            CommandGroup(after: .sidebar) {
                Button(model.showInspector ? "Hide Details" : "Show Details") { model.toggleInspector() }
                    .keyboardShortcut("i")
                Divider()
                Button("Previous") { model.shiftWeek(-1) }
                    .keyboardShortcut("[")
                Button("Next") { model.shiftWeek(1) }
                    .keyboardShortcut("]")
                Button("Today") { model.goToThisWeek() }
                    .keyboardShortcut("t")
                Divider()
                Button("All Workspace") { model.selection = .allWorkspace }
                    .keyboardShortcut("1")
                Button("Inbox") { model.selection = .inbox }
                    .keyboardShortcut("2")
                Button("Calendar") { model.selection = .calendar }
                    .keyboardShortcut("3")
                Divider()
                Button("Day View") { model.calendarMode = .day; model.selection = .calendar }
                    .keyboardShortcut("1", modifiers: [.command, .control])
                Button("Week View") {
                    model.calendarMode = .week
                    model.calendarAnchor = Dashboard.weekStart(containing: model.calendarAnchor)
                    model.selection = .calendar
                }
                .keyboardShortcut("2", modifiers: [.command, .control])
                Button("Month View") { model.calendarMode = .month; model.selection = .calendar }
                    .keyboardShortcut("3", modifiers: [.command, .control])
            }
            CommandMenu("Debug") {
                Button("Load Sample Data") { model.loadSampleData() }
                Divider()
                Button("Read Apple Reminders") { model.exportReminders() }
                Button("Apply Setup Plan") { model.applySetupPlan() }
            }
        }
        #endif
        #if os(macOS)
        Settings {
            SettingsView()
                .environment(model)
                .preferredColorScheme(.dark)
        }
        #endif
    }
}
