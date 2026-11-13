import UniformTypeIdentifiers
import SwiftUI
import WorkspaceKit
import WorkspaceUI

/// Main window: sidebar tree · scoped dashboard · task inspector.
struct RootView: View {
    static let inspectorWidth: CGFloat = 360
    @Environment(AppModel.self) private var model
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        @Bindable var model = model
        NavigationSplitView(columnVisibility: $model.sidebarVisibility) {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 220, ideal: 250)
        } detail: {
            Group {
                if model.selection == .calendar {
                    CalendarView()
                } else if model.selection == .inbox {
                    InboxView()
                } else {
                    DashboardView(scope: model.selectedScope, store: model.store, weekStart: model.weekStart)
                        .id(model.selectedScope)
                }
            }
                .inspector(isPresented: $model.showMainInspector) { DetailsPanel() }
        }
        .toolbar {
            ToolbarItem { SyncStatusView() }
            #if os(macOS)
            ToolbarItem { OpenCalendarWindowButton() }
            #endif
            ToolbarItem {
                Button { model.showTagManager = true } label: {
                    Label("Tags", systemImage: "tag")
                }
                .help("Manage tags")
            }
            ToolbarItem {
                Button { model.toggleInspector() } label: {
                    Label("Details", systemImage: "sidebar.right")
                }
                .help("Show details (⌘O)")
            }
        }
        .modifier(WindowChrome(kind: .main))
        .overlay(alignment: .bottom) {
            VStack(spacing: WSSpace.s) {
                ToastView()
                if model.selection != .calendar { SelectionBar() }
            }
        }
        .animation(.smooth(duration: 0.25), value: model.toast?.id)
        .animation(.smooth(duration: 0.2), value: model.selectedTaskIds.count > 1)
        #if os(macOS)
        .background(KeyDownCatcher { event in handleTaskKeys(event) })
        #endif
        .onAppear { model.undoManager = undoManager }
        .onChange(of: undoManager) { _, manager in model.undoManager = manager }
        .background {
            // Esc hides the details panel (zero-size button so the shortcut stays active).
            Button("") { model.setInspector(visible: false) }
                .keyboardShortcut(.escape, modifiers: [])
                .disabled(!model.showInspector)
                .opacity(0)
                .frame(width: 0, height: 0)
        }
    }
}

/// The details panel: the selected event or task, at one fixed width so switching
/// never resizes the panel (or the window). Content wraps instead of pushing out.
struct DetailsPanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if let event = model.inspectedEvent {
                EventInspector(event: event)
                    .id(event.key)
            } else if let id = model.selectedTaskId {
                TaskInspector(taskId: id)
            } else {
                ContentUnavailableView("Select a task", systemImage: "sidebar.right",
                                       description: Text("Click any task to see its details."))
            }
        }
        .frame(width: RootView.inspectorWidth)
        .frame(maxHeight: .infinity, alignment: .top)
        .clipped()
        .inspectorColumnWidth(RootView.inspectorWidth)
    }
}

/// Sheets and dialogs for a window. Only the window you're working in shows them
/// (both windows share one model), and they hang off an empty background view so
/// turning them on and off never rebuilds the window's content.
struct WindowChrome: ViewModifier {
    @Environment(AppModel.self) private var model
    #if os(macOS)
    @Environment(\.controlActiveState) private var activeState
    #endif
    @Environment(\.undoManager) private var undoManager
    let kind: AppModel.WindowKind

    func body(content: Content) -> some View {
        @Bindable var model = model
        content
            .background {
                if model.activeWindow == kind {
                    Color.clear
                        .sheet(item: $model.quickAdd) { request in
                            QuickAddView(request: request, scope: model.selectedScope)
                        }
                        .sheet(isPresented: $model.showPalette) { CommandPalette() }
                        .sheet(item: $model.containerEditor) { request in ContainerEditorSheet(request: request) }
                        .sheet(isPresented: $model.showTagManager) { TagManagerView() }
                        .sheet(item: $model.seriesEditor) { request in AssignmentSeriesSheet(request: request) }
                        .modifier(RootDialogs())
                }
            }
            #if os(macOS)
            .onChange(of: activeState, initial: true) { _, state in
                guard state == .key else { return }
                model.activeWindow = kind
                // ⌘Z works on the window you're in, so changes register there.
                if let undoManager { model.undoManager = undoManager }
            }
            .onDisappear { if kind == .calendar { model.activeWindow = .main } }
            #endif
    }
}

#if os(macOS)
/// "Open the calendar in its own window" (toolbar and View menu, ⇧⌘K).
struct OpenCalendarWindowButton: View {
    @Environment(\.openWindow) private var openWindow
    var menuItem = false

    var body: some View {
        if menuItem {
            Button("Open Calendar in New Window", action: open)
                .keyboardShortcut("k", modifiers: [.command, .shift])
        } else {
            Button(action: open) { label }
            .help("Open the calendar in its own window (⇧⌘K)")
        }
    }

    private var label: some View {
        Label("Calendar Window", systemImage: "macwindow.badge.plus")
    }

    /// One calendar window: bring it forward if it's already open.
    private func open() {
        if let existing = NSApp.windows.first(where: {
            $0.isVisible && $0.identifier?.rawValue.hasPrefix(CalendarWindow.id) == true
        }) {
            existing.makeKeyAndOrderFront(nil)
        } else {
            openWindow(id: CalendarWindow.id)
        }
    }
}

/// The calendar on its own, so you can schedule with the dashboard open beside it.
struct CalendarWindow: View {
    static let id = "calendar"
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        CalendarView()
            .inspector(isPresented: $model.showCalendarInspector) { DetailsPanel() }
            .toolbar {
                ToolbarItem { SyncStatusView() }
                ToolbarItem {
                    Button { model.showCalendarInspector.toggle() } label: {
                        Label("Details", systemImage: "sidebar.right")
                    }
                    .help("Show details (⌘O)")
                }
            }
            .navigationTitle("Calendar")
            .overlay(alignment: .bottom) { ToastView().padding(.bottom, WSSpace.s) }
            .modifier(WindowChrome(kind: .calendar))
            .frame(minWidth: 640, minHeight: 480)
    }
}

#endif

#if os(macOS)
extension RootView {
    /// Outside the calendar (which has its own keys): ⌫ deletes the selected tasks
    /// (⌘Z brings them back), Esc clears a multi-selection.
    func handleTaskKeys(_ event: NSEvent) -> Bool {
        guard model.selection != .calendar, model.quickAdd == nil, !model.showPalette else { return false }
        switch event.keyCode {
        case 51, 117:  // delete, forward delete
            let ids = Array(model.selectedTaskIds)
            guard !ids.isEmpty else { return false }
            model.deleteTasks(ids)
            return true
        case 53:  // escape
            guard model.selectedTaskIds.count > 1 else { return false }
            model.clearSelection()
            return true
        default:
            return false
        }
    }
}
#endif

/// Alerts and confirmations for the main window (split out to keep RootView's body
/// small enough for the type checker).
private struct RootDialogs: ViewModifier {
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        content
            .modifier(EventDialogs())
            .modifier(CalendarDialogs())
            .modifier(TagDialogs())
            .alert("Something went wrong", isPresented: .constant(model.errorMessage != nil)) {
                Button("OK") { model.errorMessage = nil }
            } message: {
                Text(model.errorMessage ?? "")
            }
            .alert("Done", isPresented: .constant(model.notice != nil)) {
                Button("OK") { model.notice = nil }
            } message: {
                Text(model.notice ?? "")
            }
    }
}

private struct TagDialogs: ViewModifier {
    @Environment(AppModel.self) private var model
    @State private var name = ""

    func body(content: Content) -> some View {
        content
            .alert("Rename Tag", isPresented: Binding(get: { model.renamingTag != nil },
                                                      set: { if !$0 { model.renamingTag = nil } })) {
                TextField("Name", text: $name)
                Button("Rename") { if let t = model.renamingTag { model.renameTag(t.id, to: name) } }
                Button("Cancel", role: .cancel) {}
            }
            .onChange(of: model.renamingTag?.id) { name = model.renamingTag?.name ?? "" }
    }
}

private struct EventDialogs: ViewModifier {
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        content
            .modifier(GuestNoticeDialog())
            .confirmationDialog(
                "Change this repeating event?",
                isPresented: Binding(get: { model.pendingEventEdit != nil }, set: { if !$0 { model.pendingEventEdit = nil } }),
                titleVisibility: .visible
            ) {
                Button("Only This Event") { model.confirmEventEdit(wholeSeries: false) }
                Button("All Events") { model.confirmEventEdit(wholeSeries: true) }
                Button("Cancel", role: .cancel) { model.pendingEventEdit = nil }
            }
            .confirmationDialog(
                model.pendingEventMove?.title ?? "Move event?",
                isPresented: Binding(get: { model.pendingEventMove != nil }, set: { if !$0 { model.cancelEventMove() } }),
                titleVisibility: .visible
            ) {
                Button("Only This Event") { model.confirmEventMove(.one) }
                Button("This and Following Events") { model.confirmEventMove(.following) }
                Button("All Events") { model.confirmEventMove(.all) }
                Button("Cancel", role: .cancel) { model.cancelEventMove() }
            } message: {
                Text("Change just this one, this one and the ones after it, or every time it repeats?")
            }
            .confirmationDialog(
                deleteTitle,
                isPresented: Binding(get: { !model.pendingEventDelete.isEmpty }, set: { if !$0 { model.pendingEventDelete = [] } }),
                titleVisibility: .visible
            ) {
                if model.pendingEventDelete.contains(where: \.isRecurring) {
                    Button("Delete Only This Event", role: .destructive) { model.confirmEventDelete(.one) }
                    Button("Delete This and Following", role: .destructive) { model.confirmEventDelete(.following) }
                    Button("Delete All Events", role: .destructive) { model.confirmEventDelete(.all) }
                } else {
                    Button(model.pendingEventDelete.count == 1 ? "Delete Event" : "Delete Events", role: .destructive) {
                        model.confirmEventDelete()
                    }
                }
                Button("Cancel", role: .cancel) { model.pendingEventDelete = [] }
            } message: {
                Text("This removes them from \(deleteCalendars) for everyone who can see them.")
            }
    }

    private var deleteTitle: String {
        model.pendingEventDelete.count == 1
            ? "Delete “\(model.pendingEventDelete[0].title)”?"
            : "Delete \(model.pendingEventDelete.count) events?"
    }

    private var deleteCalendars: String {
        Set(model.pendingEventDelete.map(\.calendarTitle)).sorted().joined(separator: ", ")
    }
}

/// "Email guests about this change?" (Mac and iPhone).
struct GuestNoticeDialog: ViewModifier {
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        content.confirmationDialog(
            "Email guests about this change?",
            isPresented: Binding(get: { model.pendingGuestNotice != nil },
                                 set: { if !$0 { model.answerGuestNotice(nil) } }),
            titleVisibility: .visible
        ) {
            Button("Send") { model.answerGuestNotice(true) }
            Button("Don't Send") { model.answerGuestNotice(false) }
            Button("Cancel", role: .cancel) { model.answerGuestNotice(nil) }
        } message: {
            let n = model.pendingGuestNotice?.guestCount ?? 0
            Text("Google Calendar will email \(n == 1 ? "1 guest" : "\(n) guests") an update. You can change this in Settings.")
        }
    }
}

private struct CalendarDialogs: ViewModifier {
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        content
            .alert("New Calendar", isPresented: Binding(get: { model.newCalendarAccount != nil },
                                                        set: { if !$0 { model.newCalendarAccount = nil } })) {
                NewCalendarField()
            } message: {
                Text("In \(model.newCalendarAccount ?? "")")
            }
            .confirmationDialog(
                title,
                isPresented: Binding(get: { model.pendingCalendarDelete != nil }, set: { if !$0 { model.pendingCalendarDelete = nil } }),
                titleVisibility: .visible
            ) {
                if let cal = model.pendingCalendarDelete {
                    Button("\(model.calendarSource.deleteKind(cal).verb) Calendar", role: .destructive) {
                        model.deleteCalendar(cal)
                    }
                }
                Button("Cancel", role: .cancel) { model.pendingCalendarDelete = nil }
            } message: {
                Text(model.pendingCalendarDelete.map { model.calendarSource.deleteKind($0).detail } ?? "")
            }
    }

    private var title: String {
        guard let cal = model.pendingCalendarDelete else { return "" }
        return "\(model.calendarSource.deleteKind(cal).verb) “\(cal.title)”?"
    }
}

// MARK: - Sidebar

private struct Sidebar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        List(selection: $model.selection) {
            Label("All Workspace", systemImage: "square.grid.2x2")
                .tag(SidebarItem.allWorkspace)
                .dropDestination(for: String.self) { ids, _ in
                    moveToTop(ids)
                }
            HStack {
                Label("Inbox", systemImage: "tray")
                Spacer()
                if model.inboxCount > 0 {
                    Text("\(model.inboxCount)")
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(WSColor.textTertiary)
                }
            }
            .tag(SidebarItem.inbox)
            .dropDestination(for: String.self) { ids, _ in
                guard let payload = ids.first, payload.hasPrefix("due-"),
                      let taskId = UUID(uuidString: String(payload.dropFirst(4))) else { return false }
                model.editTasks(model.targets(for: taskId), "Move to Inbox") { $0.containerId = nil }
                return true
            }
            Label("Calendar", systemImage: "calendar")
                .tag(SidebarItem.calendar)

            Section("Workspace") {
                if model.tree.isEmpty {
                    Button("Load sample data") { model.loadSampleData() }
                        .buttonStyle(.borderless)
                        .foregroundStyle(WSColor.action)
                }
                OutlineGroup(model.tree, children: \.childrenOrNil) { node in
                    SidebarRow(container: node.container, inheritedHidden: isUnderHidden(node.container))
                        .tag(SidebarItem.container(node.id))
                        .contextMenu { ContainerMenu(container: node.container) }
                        .draggable("container-\(node.id.uuidString)")
                }
            }

            CalendarListSection()
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) { AccountFooter() }
        .contextMenu { NewContainerMenu(parent: nil) }
    }

    /// True when an ancestor is hidden (the row is shown dimmed, without its own eye).
    private func isUnderHidden(_ c: Container) -> Bool {
        c.path.split(separator: "/").dropLast()
            .compactMap { UUID(uuidString: String($0)) }
            .contains { model.container($0)?.archivedAt != nil }
    }

    private func containerId(from payload: String) -> UUID? {
        guard payload.hasPrefix("container-") else { return nil }
        return UUID(uuidString: String(payload.dropFirst("container-".count)))
    }

    private func drop(_ payloads: [String], onto target: Container) -> Bool {
        guard let payload = payloads.first else { return false }
        if let id = containerId(from: payload) {
            return model.dropContainer(id, onto: target.id)
        }
        // A task dragged from the dashboard onto a list/class/project moves it there.
        if payload.hasPrefix("due-"), let taskId = UUID(uuidString: String(payload.dropFirst(4))), target.kind.holdsTasks {
            model.editTasks(model.targets(for: taskId), "Move to \(target.name)") { $0.containerId = target.id }
            return true
        }
        return false
    }

    private func moveToTop(_ payloads: [String]) -> Bool {
        guard let id = payloads.first.flatMap(containerId(from:)) else { return false }
        return model.dropContainer(id, onto: nil)
    }
}

/// Sidebar row with an eye toggle on the right: hover to see it, click to hide
/// the container (and everything in it) from dashboards and the calendar.
private struct SidebarRow: View {
    @Environment(AppModel.self) private var model
    let container: Container
    let inheritedHidden: Bool
    @State private var hovering = false
    @State private var rowHeight: CGFloat = 22
    @State private var dropPlacement: AppModel.DropPlacement?

    private var isHidden: Bool { container.archivedAt != nil }

    var body: some View {
        HStack(spacing: 0) {
            Label {
                Text(container.name).lineLimit(1)
            } icon: {
                Image(systemName: container.kind.symbol)
                    .foregroundStyle(ContainerColor(named: container.color).accent)
            }
            .opacity(isHidden || inheritedHidden ? 0.4 : 1)
            Spacer(minLength: 4)
            if !inheritedHidden && (hovering || isHidden) {
                EyeToggle(isHidden: isHidden) { model.setHidden(container.id, !isHidden) }
                    .help(isHidden ? "Show \(container.name)" : "Hide \(container.name) from dashboards and the calendar")
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { rowHeight = $0 }
        .overlay(alignment: dropPlacement == .after ? .bottom : .top) {
            if dropPlacement == .before || dropPlacement == .after {
                Rectangle().fill(WSColor.action).frame(height: 2).offset(y: dropPlacement == .after ? 3 : -3)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 5)
                .strokeBorder(WSColor.action, lineWidth: dropPlacement == .inside ? 1.5 : 0)
                .padding(-2)
        )
        .onDrop(of: [.plainText], delegate: SidebarDropDelegate(
            target: container, rowHeight: rowHeight, model: model, placement: $dropPlacement
        ))
    }
}

/// Top third → before, bottom third → after, middle → inside (when the kinds allow).
private struct SidebarDropDelegate: DropDelegate {
    let target: Container
    let rowHeight: CGFloat
    let model: AppModel
    @Binding var placement: AppModel.DropPlacement?

    private func placement(for info: DropInfo) -> AppModel.DropPlacement {
        let y = info.location.y
        if y < rowHeight * 0.3 { return .before }
        if y > rowHeight * 0.7 { return .after }
        return .inside
    }

    func dropEntered(info: DropInfo) { placement = placement(for: info) }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        placement = placement(for: info)
        return DropProposal(operation: .move)
    }
    func dropExited(info: DropInfo) { placement = nil }

    func performDrop(info: DropInfo) -> Bool {
        let where_ = placement(for: info)
        placement = nil
        guard let provider = info.itemProviders(for: [.plainText]).first else { return false }
        let model = model, target = target
        // @Sendable: called on a background queue; hop to the main actor inside.
        _ = provider.loadTransferable(type: String.self) { @Sendable result in
            guard case .success(let payload) = result else { return }
            Task { @MainActor in
                if payload.hasPrefix("container-"), let id = UUID(uuidString: String(payload.dropFirst(10))) {
                    model.placeContainer(id, relativeTo: target, where_)
                } else if payload.hasPrefix("due-"), let taskId = UUID(uuidString: String(payload.dropFirst(4))),
                          target.kind.holdsTasks {
                    model.editTasks(model.targets(for: taskId), "Move to \(target.name)") { $0.containerId = target.id }
                }
            }
        }
        return true
    }
}

struct EyeToggle: View {
    let isHidden: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: isHidden ? "eye.slash" : "eye")
                .font(.system(size: 11))
                .foregroundStyle(WSColor.textTertiary)
                .frame(width: 18, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Calendars grouped by account (like Notion Calendar's sidebar). Account headers
/// have an eye (hide every calendar in the account) and a menu; each calendar has
/// an eye, a color dot and a "…" menu.
private struct CalendarListSection: View {
    @Environment(AppModel.self) private var model
    /// Accounts start folded up; the ones you open stay open (newline-separated).
    @AppStorage("expandedCalendarAccounts") private var expandedRaw = ""

    private func expanded(_ account: String) -> Binding<Bool> {
        Binding(
            get: { expandedRaw.split(separator: "\n").contains { $0 == account } },
            set: { open in
                var set = Set(expandedRaw.split(separator: "\n").map(String.init))
                if open { set.insert(account) } else { set.remove(account) }
                expandedRaw = set.sorted().joined(separator: "\n")
            }
        )
    }

    var body: some View {
        let source = model.calendarSource
        // Google accounts first (in connection order), then system accounts.
        let googleAccounts = source.google?.accounts.map(\.email) ?? []
        let groups = Dictionary(grouping: source.calendars, by: \.account).sorted { a, b in
            let ia = googleAccounts.firstIndex(of: a.key) ?? Int.max, ib = googleAccounts.firstIndex(of: b.key) ?? Int.max
            return ia != ib ? ia < ib : a.key < b.key
        }
        ForEach(groups, id: \.key) { account, calendars in
            Section(isExpanded: expanded(account)) {
                ForEach(calendars) { cal in
                    CalendarRow(calendar: cal, accountHidden: source.hiddenAccounts.contains(account))
                }
            } header: {
                AccountHeader(account: account, isGoogle: googleAccounts.contains(account))
            }
        }
        if source.isGoogleAvailable {
            Section {
                Button {
                    model.connectGoogle()
                } label: {
                    Label(source.isGoogleConnected ? "Add Google account" : "Connect Google Calendar",
                          systemImage: "plus.circle")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(WSColor.textSecondary)
                if let error = source.google?.accounts.compactMap(\.error).first {
                    Text(error).font(.system(size: 10.5)).foregroundStyle(WSColor.now).lineLimit(3)
                }
            }
        } else if source.access != .granted {
            Section {
                Button("Allow calendar access") { Task { await source.requestAccess() } }
                    .buttonStyle(.borderless)
                    .foregroundStyle(WSColor.textSecondary)
            }
        }
    }
}

private struct AccountHeader: View {
    @Environment(AppModel.self) private var model
    let account: String
    let isGoogle: Bool
    @State private var hovering = false

    var body: some View {
        let source = model.calendarSource
        let hidden = source.hiddenAccounts.contains(account)
        HStack(spacing: 4) {
            Text(account.isEmpty ? "Calendars" : account)
                .lineLimit(1)
                .opacity(hidden ? 0.45 : 1)
            Spacer(minLength: 4)
            if hovering || hidden {
                Menu {
                    if source.canCreateCalendars(in: account) {
                        Button("New Calendar…") { model.newCalendarAccount = account }
                    }
                    Button("Sync Now") { source.refresh() }
                    Button(hidden ? "Show Account" : "Hide Account") { toggle() }
                    if isGoogle, let google = source.google {
                        Divider()
                        Button("Disconnect \(account)", role: .destructive) {
                            Task { await google.disconnect(account) }
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 11))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                EyeToggle(isHidden: hidden, action: toggle)
                    .help(hidden ? "Show every \(account) calendar" : "Hide every \(account) calendar")
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }

    private func toggle() {
        let source = model.calendarSource
        if source.hiddenAccounts.contains(account) { source.hiddenAccounts.remove(account) }
        else { source.hiddenAccounts.insert(account) }
    }
}

private struct CalendarRow: View {
    @Environment(AppModel.self) private var model
    let calendar: CalendarSource.CalendarInfo
    let accountHidden: Bool
    @State private var hovering = false

    var body: some View {
        let source = model.calendarSource
        let hidden = source.hiddenCalendarIds.contains(calendar.id)
        let isDefault = source.defaultCalendarId == calendar.id
        let color = source.color(forCalendar: calendar.id, fallback: calendar.color)
        HStack(spacing: 7) {
            RoundedRectangle(cornerRadius: 3)
                .fill(Color(hex: color))
                .frame(width: 11, height: 11)
            Text(calendar.title)
                .lineLimit(1)
            if isDefault {
                Text("default")
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(WSColor.textTertiary)
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .overlay(Capsule().strokeBorder(WSColor.hairline))
                    .help("New events go here")
            }
            if !calendar.isWritable {
                Image(systemName: "lock").font(.system(size: 9)).foregroundStyle(WSColor.textTertiary)
            }
            Spacer(minLength: 4)
            if hovering {
                Menu { CalendarMenu(calendar: calendar) } label: {
                    Image(systemName: "ellipsis").font(.system(size: 11))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
            if !accountHidden && (hovering || hidden) {
                EyeToggle(isHidden: hidden) {
                    if hidden { source.hiddenCalendarIds.remove(calendar.id) } else { source.hiddenCalendarIds.insert(calendar.id) }
                }
                .help(hidden ? "Show \(calendar.title)" : "Hide \(calendar.title)")
            }
        }
        .opacity(hidden || accountHidden ? 0.4 : 1)
        .font(.system(size: 12.5))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu { CalendarMenu(calendar: calendar) }
    }
}

/// Color · default · Google settings · remove/delete (Notion Calendar-style).
private struct CalendarMenu: View {
    @Environment(AppModel.self) private var model
    let calendar: CalendarSource.CalendarInfo

    var body: some View {
        let source = model.calendarSource
        let current = source.colorOverrides[calendar.id]
        Menu("Color") {
            ForEach(ContainerColor.allCases) { option in
                Button {
                    source.colorOverrides[calendar.id] = option.hex
                } label: {
                    Label { Text(option.displayName + (current == option.hex ? "  ✓" : "")) } icon: { ColorSwatchImage.image(for: option) }
                }
            }
            Divider()
            Button("Calendar's Own Color" + (current == nil ? "  ✓" : "")) { source.colorOverrides[calendar.id] = nil }
        }
        if calendar.isWritable {
            Button(source.defaultCalendarId == calendar.id ? "Default Calendar ✓" : "Make Default Calendar") {
                source.preferredDefaultCalendarId = calendar.id
            }
            .disabled(source.defaultCalendarId == calendar.id)
        }
        Button(source.hiddenCalendarIds.contains(calendar.id) ? "Show Calendar" : "Hide Calendar") {
            if source.hiddenCalendarIds.contains(calendar.id) { source.hiddenCalendarIds.remove(calendar.id) }
            else { source.hiddenCalendarIds.insert(calendar.id) }
        }
        if let url = source.googleSettingsURL(for: calendar) {
            Divider()
            Link("Google Calendar Settings ↗", destination: url)
        }
        Divider()
        Button("\(source.deleteKind(calendar).verb) Calendar…", role: .destructive) {
            model.pendingCalendarDelete = calendar
        }
    }
}

private struct NewContainerMenu: View {
    @Environment(AppModel.self) private var model
    let parent: Container?

    var body: some View {
        let kinds = ContainerKind.allCases.filter { parent?.kind.canContain($0) ?? true }
        ForEach(kinds, id: \.self) { kind in
            Button("New \(kind.displayName)") { model.createContainer(kind, under: parent?.id) }
        }
    }
}

private struct ContainerMenu: View {
    @Environment(AppModel.self) private var model
    let container: Container

    var body: some View {
        NewContainerMenu(parent: container)
        Divider()
        Button("Edit…") { model.editContainer(container) }
        if container.kind == .class {
            Button("New Assignment Series…") { model.seriesEditor = SeriesEditorRequest(classId: container.id) }
        }
        Menu("Color") {
            ForEach(ContainerColor.allCases) { color in
                Button {
                    model.setColor(container.id, color.rawValue)
                } label: {
                    Label {
                        Text(color.displayName + (container.color == color.rawValue ? "  ✓" : ""))
                    } icon: {
                        ColorSwatchImage.image(for: color)
                    }
                }
            }
        }
        if container.parentId != nil {
            Button("Move to Top Level") { _ = model.dropContainer(container.id, onto: nil) }
        }
        Divider()
        Button("Delete \(container.name)", role: .destructive) { model.delete(container.id) }
    }
}

private struct NewCalendarField: View {
    @Environment(AppModel.self) private var model
    @State private var name = ""

    var body: some View {
        TextField("Calendar name", text: $name)
        Button("Create") {
            if let account = model.newCalendarAccount, !name.trimmingCharacters(in: .whitespaces).isEmpty {
                model.createCalendar(named: name.trimmingCharacters(in: .whitespaces), in: account)
            }
            model.newCalendarAccount = nil
        }
        Button("Cancel", role: .cancel) { model.newCalendarAccount = nil }
    }
}

// MARK: - Toast

private struct ToastView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let toast = model.toast {
            HStack(spacing: WSSpace.m) {
                Text(toast.message)
                    .foregroundStyle(WSColor.textPrimary)
                    .lineLimit(1)
                Button("Undo") { model.undoToast() }
                    .buttonStyle(.plain)
                    .fontWeight(.semibold)
                    .foregroundStyle(WSColor.action)
            }
            .font(.system(size: 13))
            .padding(.horizontal, WSSpace.l).padding(.vertical, WSSpace.s + 2)
            .background(RoundedRectangle(cornerRadius: WSRadius.popover).fill(WSColor.raised))
            .overlay(RoundedRectangle(cornerRadius: WSRadius.popover).strokeBorder(WSColor.hairline))
            .padding(.bottom, WSSpace.xl)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .id(toast.id)
        }
    }
}
