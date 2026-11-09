import GRDB
import SwiftUI
import WorkspaceKit
import WorkspaceUI

/// ⌘N quick add. Type naturally; recognized pieces show as chips below and are
/// removed from the title: `HW 5 cs61b fri 11:59pm #hw !2`.
struct QuickAddView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let request: QuickAddRequest
    let scope: UUID?

    @State private var text = ""
    @FocusState private var focused: Bool

    private var parser: QuickAddParser {
        QuickAddParser(
            containers: model.containers.map { .init(id: $0.id, name: $0.name, holdsTasks: $0.kind.holdsTasks) },
            categories: model.categories.map { .init(id: $0.id, name: $0.name) },
            today: LocalDate(Date())
        )
    }

    private var parsed: QuickAddParser.Result {
        var r = parser.parse(text)
        if r.dueDate == nil, let preset = request.presetDue { r.dueDate = preset }
        return r
    }

    var body: some View {
        let result = parsed
        VStack(alignment: .leading, spacing: WSSpace.m) {
            HStack(spacing: WSSpace.s) {
                Image(systemName: "plus.circle")
                    .foregroundStyle(WSColor.textTertiary)
                TextField("New task — try “HW 5 cs61b fri 11:59pm #hw”", text: $text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 16))
                    .focused($focused)
                    .onSubmit(submit)
            }

            HStack(spacing: WSSpace.xs) {
                TokenChip(symbol: "tray", text: destinationLabel(result), color: destinationColor(result))
                if let date = result.dueDate {
                    TokenChip(symbol: "flag", text: WSFormat.relativeDay(date, today: LocalDate(Date()))
                                + (result.dueTime.map { " " + WSFormat.time($0) } ?? ""))
                }
                if let tag = model.tagStyle(result.categoryId) {
                    TagPill(tag)
                } else if let name = result.newTagName {
                    TokenChip(symbol: "tag", text: "New tag “\(name)”")
                }
                if let m = request.presetMilestone.flatMap(milestoneTitle) {
                    TokenChip(symbol: "diamond", text: m)
                }
                if let p = result.priority {
                    TokenChip(symbol: "exclamationmark", text: "P\(p)")
                }
                Spacer()
                Text("↩ to add · esc to cancel")
                    .font(.system(size: 11))
                    .foregroundStyle(WSColor.textTertiary)
            }
        }
        .padding(WSSpace.l)
        .frame(width: 560)
        .background(WSColor.raised)
        .onAppear { focused = true }
        .onEscape { dismiss() }
    }

    private func submit() {
        let result = parsed
        guard !result.title.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        model.createTask(from: result, defaultScope: request.presetContainer ?? scope,
                         milestoneId: request.presetMilestone, startDate: request.presetStart)
        dismiss()
    }

    private func milestoneTitle(_ id: UUID) -> String? {
        (try? model.store.db.read { try TaskItem.fetchOne($0, id: id) })?.title
    }

    private func destinationLabel(_ r: QuickAddParser.Result) -> String {
        if let id = r.containerId, let c = model.container(id) { return c.name }
        guard let scope = request.presetContainer ?? scope, let c = model.container(scope) else { return "Inbox" }
        if c.kind.holdsTasks { return c.name }
        if let list = c.defaultListId.flatMap({ model.container($0) }) { return "\(c.name) › \(list.name)" }
        return "\(c.name) › General"
    }

    private func destinationColor(_ r: QuickAddParser.Result) -> ContainerColor? {
        let id = r.containerId ?? request.presetContainer ?? scope
        return model.container(id).map { ContainerColor(named: $0.color) }
    }
}

private struct TokenChip: View {
    let symbol: String
    let text: String
    var color: ContainerColor?

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).imageScale(.small)
            Text(text)
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(color?.accent ?? WSColor.textSecondary)
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(Capsule().fill(color?.fill ?? WSColor.hairline))
    }
}

/// ⌘K: jump to any container or task.
struct CommandPalette: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var tasks: [TaskItem] = []
    @State private var highlighted = 0
    @FocusState private var focused: Bool

    private enum Item: Identifiable {
        case container(Container)
        case task(TaskItem)
        var id: UUID {
            switch self {
            case .container(let c): c.id
            case .task(let t): t.id
            }
        }
    }

    private var results: [Item] {
        var scored: [(Int, Item)] = []
        for c in model.containers {
            let path = ContainerTree.breadcrumb(for: c.id, in: model.containers).map(\.name).joined(separator: " / ")
            if let s = FuzzyMatch.score(query, in: c.name) ?? FuzzyMatch.score(query, in: path) {
                scored.append((s + 5, .container(c)))   // containers slightly preferred
            }
        }
        if !query.isEmpty {
            for t in tasks {
                if let s = FuzzyMatch.score(query, in: t.title) { scored.append((s, .task(t))) }
            }
        }
        return scored.sorted { $0.0 > $1.0 }.prefix(12).map(\.1)
    }

    var body: some View {
        let items = results
        VStack(spacing: 0) {
            HStack(spacing: WSSpace.s) {
                Image(systemName: "magnifyingglass").foregroundStyle(WSColor.textTertiary)
                TextField("Jump to a folder, class, project or task", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 16))
                    .focused($focused)
                    .onSubmit { open(items) }
                    .onChange(of: query) { highlighted = 0 }
            }
            .padding(WSSpace.l)
            Divider()
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        resultRow(item, isHighlighted: index == highlighted)
                            .onTapGesture { highlighted = index; open(items) }
                    }
                }
                .padding(WSSpace.s)
            }
            .frame(height: 320)
        }
        .frame(width: 560)
        .background(WSColor.raised)
        .onAppear { focused = true }
        .onEscape { dismiss() }
        .onKeyPress(.downArrow) { highlighted = min(highlighted + 1, max(items.count - 1, 0)); return .handled }
        .onKeyPress(.upArrow) { highlighted = max(highlighted - 1, 0); return .handled }
        .task {
            tasks = (try? await model.store.db.read { try TaskItem.live().fetchAll($0) }) ?? []
        }
    }

    @ViewBuilder
    private func resultRow(_ item: Item, isHighlighted: Bool) -> some View {
        HStack(spacing: WSSpace.s) {
            switch item {
            case .container(let c):
                Image(systemName: c.kind.symbol)
                    .foregroundStyle(ContainerColor(named: c.color).accent)
                    .frame(width: 18)
                Text(c.name).foregroundStyle(WSColor.textPrimary)
                Text(ContainerTree.breadcrumb(for: c.id, in: model.containers).dropLast().map(\.name).joined(separator: " › "))
                    .foregroundStyle(WSColor.textTertiary)
            case .task(let t):
                Image(systemName: t.status == .done ? "checkmark.circle" : "circle")
                    .foregroundStyle(ContainerColor(named: model.color(for: t)).accent)
                    .frame(width: 18)
                Text(t.title).foregroundStyle(WSColor.textPrimary)
                Text(model.container(for: t)?.name ?? "Inbox").foregroundStyle(WSColor.textTertiary)
            }
            Spacer()
        }
        .font(.system(size: 13))
        .lineLimit(1)
        .padding(.horizontal, WSSpace.m).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 6).fill(isHighlighted ? WSColor.hairline : .clear))
        .contentShape(Rectangle())
    }

    private func open(_ items: [Item]) {
        guard items.indices.contains(highlighted) else { return }
        switch items[highlighted] {
        case .container(let c):
            model.selection = .container(c.id)
        case .task(let t):
            model.selection = t.containerId.map { .container($0) } ?? .allWorkspace
            model.openDetails(t.id)
        }
        dismiss()
    }
}
