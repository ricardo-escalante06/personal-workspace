import GRDB
import SwiftUI
import UserNotifications
import WorkspaceKit
import WorkspaceUI
#if canImport(WidgetKit)
import WidgetKit
#endif

/// Due-date and work-block alerts, rebuilt from the local data whenever it changes.
/// On by default on iPhone, off on the Mac (so you don't get every alert twice).
@MainActor
final class NotificationScheduler: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationScheduler()
    weak var model: AppModel?
    private var pending: Task<Void, Never>?
    private var observer: AnyDatabaseCancellable?

    static let categoryId = "workspace.task"
    static let doneAction = "workspace.done"

    var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "notificationsEnabled") as? Bool ?? (Platform.deviceName == "iPhone") }
        set {
            UserDefaults.standard.set(newValue, forKey: "notificationsEnabled")
            if newValue { Task { await requestAuthorization() } }
            schedule(after: .zero)
        }
    }

    var settings: ReminderPlanner.Settings {
        get {
            (UserDefaults.standard.data(forKey: "notificationSettings"))
                .flatMap { try? JSONDecoder().decode(ReminderPlanner.Settings.self, from: $0) } ?? .init()
        }
        set {
            UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: "notificationSettings")
            schedule(after: .zero)
        }
    }

    func start(model: AppModel) {
        self.model = model
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.setNotificationCategories([UNNotificationCategory(
            identifier: Self.categoryId,
            actions: [UNNotificationAction(identifier: Self.doneAction, title: "Mark Done")],
            intentIdentifiers: []
        )])
        if isEnabled { Task { await requestAuthorization() } }
        // Any change to tasks, blocks or overrides: rebuild alerts and refresh widgets.
        observer = DatabaseRegionObservation(tracking: Table("tasks"), Table("task_schedule_blocks"),
                                             Table("task_occurrence_overrides"), Table("categories"))
            .start(in: model.store.db, onError: { _ in }, onChange: { [weak self] _ in
                Task { @MainActor in self?.schedule(after: .seconds(2)) }
            })
        schedule(after: .seconds(1))
    }

    func requestAuthorization() async {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
    }

    /// Debounced: bursts of edits (and sync pulls) rebuild once.
    func schedule(after delay: Duration) {
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            await self.rebuild()
            #if canImport(WidgetKit) && os(iOS)
            self.model?.writeWidgetCalendar()
            WidgetCenter.shared.reloadAllTimelines()
            #endif
        }
    }

    private func rebuild() async {
        guard let store = model?.store else { return }
        let center = UNUserNotificationCenter.current()
        let existing = await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix("ws-") }
        center.removePendingNotificationRequests(withIdentifiers: existing)
        guard isEnabled else { return }
        let settings = self.settings
        guard let reminders = try? await store.db.read({ try ReminderPlanner.plan($0, settings: settings) }) else { return }
        for r in reminders {
            let content = UNMutableNotificationContent()
            content.title = r.title
            content.body = r.body
            content.sound = .default
            content.categoryIdentifier = Self.categoryId
            var info: [String: String] = ["taskId": r.taskId.uuidString]
            if let s = r.seriesId, let k = r.occurrenceKey { info["seriesId"] = s.uuidString; info["key"] = k }
            content.userInfo = info
            let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: r.date)
            let request = UNNotificationRequest(identifier: "ws-" + r.id, content: content,
                                                trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: false))
            try? await center.add(request)
        }
    }

    // MARK: Delegate

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification)
        async -> UNNotificationPresentationOptions { [.banner, .sound] }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        let taskId = (info["taskId"] as? String).flatMap(UUID.init(uuidString:))
        let seriesId = (info["seriesId"] as? String).flatMap(UUID.init(uuidString:))
        let key = info["key"] as? String
        let action = response.actionIdentifier
        await MainActor.run {
            guard let model, let taskId else { return }
            // Occurrence ids are computed; make sure this one resolves in this launch.
            let id = seriesId.flatMap { s in key.map { OccurrenceRegistry.id(series: s, key: $0) } } ?? taskId
            if action == Self.doneAction {
                model.perform { try model.store.setStatus(id, .done) }
            } else {
                model.openDetails(id)
            }
        }
    }
}

/// Alerts on/off and timing (Settings on iPhone; Mac Settings).
struct NotificationSettingsSection: View {
    @State private var enabled = NotificationScheduler.shared.isEnabled
    @State private var settings = NotificationScheduler.shared.settings

    var body: some View {
        Section {
            Toggle("Alerts for due dates", isOn: $enabled)
                .onChange(of: enabled) { _, on in NotificationScheduler.shared.isEnabled = on }
            if enabled {
                Picker("Timed deadlines", selection: $settings.minutesBeforeTimed) {
                    Text("At the time").tag(0)
                    Text("15 min before").tag(15)
                    Text("1 hour before").tag(60)
                    Text("3 hours before").tag(180)
                }
                Picker("All-day deadlines", selection: $settings.morningHour) {
                    ForEach([7, 8, 9, 10, 12], id: \.self) { h in Text("\(h % 12 == 0 ? 12 : h % 12) \(h < 12 ? "AM" : "PM") that day").tag(h) }
                }
                Toggle("Starred: also the day before", isOn: $settings.dayBeforeStarred)
                Toggle("When a work block starts", isOn: $settings.workBlocks)
            }
        } header: {
            Text("Alerts")
        } footer: {
            Text("Covers the next 7 days and updates as tasks change.")
        }
        .onChange(of: settings) { _, s in NotificationScheduler.shared.settings = s }
    }
}

#if os(iOS)
extension AppModel {
    /// Saves today + tomorrow for the Calendar widget and refreshes it. Called when
    /// tasks or calendars change (debounced by the callers).
    func writeWidgetCalendar() {
        let tz = TimeZone.current
        let start = LocalDate(Date()).startOfDay(in: tz)
        let end = LocalDate(Date()).adding(days: 2).startOfDay(in: tz)
        let events = calendarSource.events(from: start, to: end)
        var options = CalendarQuery.Options()
        options.hiddenCalendars = calendarSource.effectiveHiddenCalendarIds
        guard let items = try? store.db.read({ try CalendarQuery.items($0, scope: nil, from: start, to: end, events: events, options: options) })
        else { return }
        let out = items.compactMap { item -> WidgetCalendarItem? in
            let kind: WidgetCalendarItem.Kind
            switch item.source {
            case .event: kind = .event
            case .block: kind = .block
            case .deadline:
                guard !item.isAllDay else { return nil }   // date-only deadlines are the Today widget's job
                kind = .deadline
            }
            let colorName = container(item.containerId)?.color
            return WidgetCalendarItem(id: item.id, kind: kind, title: item.title, start: item.start, end: item.end,
                                      isAllDay: item.isAllDay, colorName: colorName, hex: item.event?.calendarColor ?? 0x8A8A8A,
                                      location: item.event?.location, isDone: item.isDone)
        }
        WidgetCalendarFile.write(out)
        WidgetCenter.shared.reloadTimelines(ofKind: "workspace.calendar")
    }

    /// Re-save the widget's calendar whenever the calendar sources change.
    func watchCalendarForWidget() {
        withObservationTracking {
            _ = calendarSource.revision
        } onChange: { [weak self] in
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1))
                self?.writeWidgetCalendar()
                self?.watchCalendarForWidget()
            }
        }
    }
}
#endif
