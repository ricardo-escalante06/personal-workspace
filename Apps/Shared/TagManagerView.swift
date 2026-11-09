import GRDB
import SwiftUI
import WorkspaceKit
import WorkspaceUI

/// Every tag in one place: rename, recolor, auto-star, delete, and how many open
/// tasks use each one (so a stray tag like a typo is easy to spot and remove).
struct TagManagerView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var counts: [UUID: (open: Int, all: Int)] = [:]
    @State private var newName = ""
    @State private var confirmDelete: TaskCategory?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Tags").font(.system(size: 15, weight: .semibold))
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(WSSpace.l)
            Text("Tags are shared by every list, class and project. A list only shows the tags its tasks use.")
                .font(.system(size: 12)).foregroundStyle(WSColor.textSecondary)
                .padding(.horizontal, WSSpace.l).padding(.bottom, WSSpace.m)
            Divider()
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(model.categories) { tag in
                        TagManagerRow(tag: tag, open: counts[tag.id]?.open ?? 0, all: counts[tag.id]?.all ?? 0) {
                            if (counts[tag.id]?.all ?? 0) == 0 { model.deleteTag(tag.id) } else { confirmDelete = tag }
                        }
                        Divider().padding(.leading, WSSpace.l)
                    }
                }
            }
            Divider()
            HStack {
                TextField("New tag", text: $newName)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(add)
                Button("Add", action: add).disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(WSSpace.l)
        }
        .frame(width: 460, height: 520)
        .confirmationDialog("Delete “\(confirmDelete?.name ?? "")”?", isPresented: Binding(
            get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }), titleVisibility: .visible) {
            Button("Delete Tag", role: .destructive) { if let t = confirmDelete { model.deleteTag(t.id) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            let n = confirmDelete.flatMap { counts[$0.id]?.all } ?? 0
            Text("\(n) task\(n == 1 ? "" : "s") will lose this tag. The tasks themselves stay.")
        }
        .task {
            struct Count: Sendable { var id: UUID; var all: Int; var open: Int }
            let observation = ValueObservation.tracking { db -> [Count] in
                try Row.fetchAll(db, sql: """
                    SELECT category_id, COUNT(*) AS n,
                           SUM(CASE WHEN status IN ('done', 'cancelled') THEN 0 ELSE 1 END) AS open
                    FROM tasks WHERE deleted_at IS NULL AND category_id IS NOT NULL GROUP BY category_id
                    """).compactMap { r in
                    (r["category_id"] as UUID?).map { Count(id: $0, all: r["n"] ?? 0, open: r["open"] ?? 0) }
                }
            }
            do {
                for try await rows in observation.values(in: model.store.db) {
                    counts = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, (open: $0.open, all: $0.all)) })
                }
            } catch {}
        }
    }

    private func add() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        model.perform { _ = try model.store.tag(named: name) }
        newName = ""
    }
}

private struct TagManagerRow: View {
    @Environment(AppModel.self) private var model
    let tag: TaskCategory
    let open: Int
    let all: Int
    let delete: () -> Void
    @State private var name = ""

    var body: some View {
        HStack(spacing: WSSpace.s) {
            Menu {
                ForEach(ContainerColor.allCases) { c in
                    Button { model.setTagColor(tag.id, c.rawValue) } label: {
                        Label { Text(c.displayName) } icon: { ColorSwatchImage.image(for: c) }
                    }
                }
            } label: {
                // Menus draw only text and images in their label, so the dot is an image.
                ColorSwatchImage.image(for: ContainerColor(named: tag.color ?? "grey"))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Color")

            TextField("Name", text: $name)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .onSubmit { model.renameTag(tag.id, to: name) }
                .onAppear { name = tag.name }
                .onChange(of: tag.name) { _, new in name = new }

            Text(all == 0 ? "unused" : "\(open) open" + (all > open ? " · \(all - open) done" : ""))
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(all == 0 ? WSColor.now.opacity(0.8) : WSColor.textTertiary)

            Toggle(isOn: Binding(get: { tag.autoStar }, set: { model.setAutoStar(tag.id, $0) })) {
                Image(systemName: "star.fill").font(.system(size: 10))
            }
            .checkboxToggleStyle()
            .help("Star tasks with this tag automatically (shows them at the top of Due soon)")

            Button(action: delete) { Image(systemName: "trash") }
                .buttonStyle(.borderless)
                .foregroundStyle(WSColor.textTertiary)
                .help("Delete tag")
        }
        .padding(.horizontal, WSSpace.l)
        .padding(.vertical, 7)
    }
}
