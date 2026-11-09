import SwiftUI
import WorkspaceKit

/// How a tag is drawn: its name and color.
public struct TagStyle: Hashable, Sendable {
    public var name: String
    public var shortName: String
    public var color: ContainerColor

    public init(name: String, shortName: String, color: ContainerColor) {
        self.name = name; self.shortName = shortName; self.color = color
    }

    public init(_ category: TaskCategory) {
        self.init(name: category.name, shortName: category.shortName, color: ContainerColor(named: category.color ?? "grey"))
    }
}

/// A small tinted capsule: "Exam", "HW". Color is never the only signal; the name is always shown.
public struct TagPill: View {
    let tag: TagStyle
    let compact: Bool

    public init(_ tag: TagStyle, compact: Bool = false) {
        self.tag = tag
        self.compact = compact
    }

    public var body: some View {
        Text(compact ? tag.shortName : tag.name)
            .font(.system(size: compact ? 9.5 : 10.5, weight: .semibold))
            .foregroundStyle(tag.color.accent)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, compact ? 4 : 6)
            .padding(.vertical, compact ? 0.5 : 1.5)
            .background(Capsule().fill(tag.color.accent.opacity(0.16)))
            .accessibilityLabel("Tag \(tag.name)")
    }
}
