import SwiftUI
import WorkspaceKit
import WorkspaceUI

/// Settings (⌘,): calendar accounts.
struct SettingsView: View {
    var body: some View {
        TabView {
            AccountsSettings()
                .tabItem { Label("Accounts", systemImage: "person.crop.circle") }
        }
        .frame(width: 520, height: 380)
    }
}

private struct AccountsSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let source = model.calendarSource
        Form {
            Section("Google Calendar") {
                if let google = source.google {
                    if google.accounts.isEmpty {
                        Text("Not connected. Connect for invites, RSVP, guests and Meet links, with changes in seconds.")
                            .foregroundStyle(WSColor.textSecondary)
                    }
                    ForEach(google.accounts) { account in
                        HStack {
                            Image(systemName: "person.crop.circle.fill").foregroundStyle(WSColor.textSecondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(account.email)
                                Group {
                                    if let error = account.error {
                                        Text(error).foregroundStyle(WSColor.now)
                                    } else if let last = account.lastSync {
                                        Text("\(account.calendars.count) calendars · synced \(last.formatted(date: .omitted, time: .shortened))")
                                    } else {
                                        Text("Syncing…")
                                    }
                                }
                                .font(.caption)
                                .foregroundStyle(WSColor.textTertiary)
                            }
                            Spacer()
                            Button("Disconnect") { Task { await google.disconnect(account.email) } }
                        }
                    }
                    Button(google.accounts.isEmpty ? "Connect Google Calendar…" : "Add Another Google Account…") {
                        model.connectGoogle()
                    }
                } else {
                    Text("Add GOOGLE_CLIENT_ID to Config/Secrets.xcconfig and rebuild to enable Google Calendar.")
                        .foregroundStyle(WSColor.textSecondary)
                }
            }
            Section("Other calendars on this Mac") {
                switch source.access {
                case .granted:
                    Text("iCloud and other accounts from System Settings › Internet Accounts are shown. Google accounts connected above replace their Mac copies.")
                        .foregroundStyle(WSColor.textSecondary)
                case .denied:
                    Text("Access is off. Turn it on in System Settings › Privacy & Security › Calendars.")
                        .foregroundStyle(WSColor.textSecondary)
                default:
                    Button("Allow Access to Mac Calendars") { Task { await source.requestAccess() } }
                }
            }
        }
        .formStyle(.grouped)
    }
}
