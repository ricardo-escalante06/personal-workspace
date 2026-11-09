import SwiftUI
import WorkspaceKit

/// The round checkbox used everywhere: outlined in the container's accent,
/// filled with a check when done.
public struct TaskCheckbox: View {
    let isDone: Bool
    let color: ContainerColor
    let action: () -> Void

    public init(isDone: Bool, color: ContainerColor, action: @escaping () -> Void) {
        self.isDone = isDone
        self.color = color
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .strokeBorder(color.accent, lineWidth: 1.5)
                    .background(Circle().fill(isDone ? color.accent : .clear))
                if isDone {
                    Image(systemName: "checkmark")
                        .font(.system(size: 8, weight: .heavy))
                        .foregroundStyle(WSColor.canvas)
                }
            }
            .frame(width: 15, height: 15)
            .contentShape(Rectangle().inset(by: -4))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isDone ? "Mark not done" : "Mark done")
    }
}

/// A task row: checkbox, title, optional context line, and trailing metadata.
public struct TaskRowView: View {
    public struct Context {
        public var color: ContainerColor
        /// Shown under the title, e.g. the container name in broader scopes.
        public var subtitle: String?
        public var tag: TagStyle?
        public var isStarred: Bool
        public var subtasks: SubtaskProgress?
        /// e.g. "7–8 PM" for a block today.
        public var timeText: String?
        public var dueText: String?
        public var isOverdue: Bool

        public init(color: ContainerColor, subtitle: String? = nil, tag: TagStyle? = nil, isStarred: Bool = false,
                    subtasks: SubtaskProgress? = nil, timeText: String? = nil,
                    dueText: String? = nil, isOverdue: Bool = false) {
            self.color = color; self.subtitle = subtitle; self.tag = tag; self.isStarred = isStarred
            self.subtasks = subtasks; self.timeText = timeText; self.dueText = dueText; self.isOverdue = isOverdue
        }
    }

    let task: TaskItem
    let context: Context
    let isSelected: Bool
    let onToggle: () -> Void

    public init(task: TaskItem, context: Context, isSelected: Bool = false, onToggle: @escaping () -> Void) {
        self.task = task
        self.context = context
        self.isSelected = isSelected
        self.onToggle = onToggle
    }

    public var body: some View {
        let done = task.status == .done
        HStack(alignment: .firstTextBaseline, spacing: WSSpace.s + 2) {
            TaskCheckbox(isDone: done, color: context.color, action: onToggle)
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(task.title)
                        .font(WSFont.rowTitle)
                        .strikethrough(done, color: WSColor.textTertiary)
                        .foregroundStyle(done ? WSColor.textTertiary : WSColor.textPrimary)
                        .lineLimit(1)
                    if let tag = context.tag { TagPill(tag).opacity(done ? 0.5 : 1) }
                    if task.isRecurring {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(WSColor.textTertiary)
                            .accessibilityLabel("Repeats")
                    }
                    if context.isStarred {
                        Image(systemName: "star.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(Color(hex: 0xD6A740))
                            .accessibilityLabel("Starred")
                    }
                }
                if let subtitle = context.subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(WSColor.textTertiary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: WSSpace.s)

            HStack(spacing: WSSpace.s) {
                if let p = context.subtasks, p.total > 0 {
                    Label("\(p.done)/\(p.total)", systemImage: "checklist")
                        .labelStyle(.titleAndIcon)
                }
                if let time = context.timeText {
                    Text(time)
                }
                if let due = context.dueText {
                    Label(due, systemImage: "flag")
                        .foregroundStyle(context.isOverdue && !done ? WSColor.now : WSColor.textSecondary)
                }
            }
            .font(WSFont.metric)
            .foregroundStyle(WSColor.textSecondary)
            .imageScale(.small)
        }
        .padding(.vertical, 5)
        .padding(.horizontal, WSSpace.s)
        .background(
            RoundedRectangle(cornerRadius: WSRadius.block)
                .fill(isSelected ? WSColor.hairline : .clear)
        )
        .contentShape(Rectangle())
    }
}

/// Small caps section label: "TODAY", "UPCOMING".
public struct SectionLabel: View {
    let text: String
    let trailing: String?
    public init(_ text: String, trailing: String? = nil) {
        self.text = text
        self.trailing = trailing
    }
    public var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(text.uppercased())
                .font(WSFont.sectionLabel)
                .tracking(0.6)
                .foregroundStyle(WSColor.textSecondary)
            if let trailing {
                Text(trailing)
                    .font(WSFont.sectionLabel)
                    .foregroundStyle(WSColor.textTertiary)
            }
            Spacer()
        }
    }
}
