import Foundation

/// A container with its children, for sidebar outlines.
public struct ContainerNode: Identifiable, Hashable, Sendable {
    public var container: Container
    public var children: [ContainerNode]

    public var id: UUID { container.id }
    public var isHidden: Bool { container.archivedAt != nil }
    /// `nil` for leaves, so SwiftUI's OutlineGroup shows no disclosure arrow.
    public var childrenOrNil: [ContainerNode]? { children.isEmpty ? nil : children }
}

public enum ContainerTree {
    /// Builds a forest from a flat list, ordered by `sortRank` at every level.
    /// Orphans (parent missing or deleted) are shown at the root rather than hidden.
    public static func build(_ containers: [Container]) -> [ContainerNode] {
        // Hidden (archived) containers stay in the tree so the sidebar can show them dimmed.
        let live = containers.filter { $0.deletedAt == nil }
        let ids = Set(live.map(\.id))
        let byParent = Dictionary(grouping: live) { c -> UUID? in
            guard let p = c.parentId, ids.contains(p) else { return nil }
            return p
        }
        func nodes(under parent: UUID?) -> [ContainerNode] {
            (byParent[parent] ?? [])
                .sorted { ($0.sortRank, $0.name) < ($1.sortRank, $1.name) }
                .map { ContainerNode(container: $0, children: nodes(under: $0.id)) }
        }
        return nodes(under: nil)
    }

    /// Ancestors of `id` from the root down, including `id` itself (for breadcrumbs).
    public static func breadcrumb(for id: UUID, in containers: [Container]) -> [Container] {
        let byId = Dictionary(uniqueKeysWithValues: containers.map { ($0.id, $0) })
        guard let leaf = byId[id] else { return [] }
        return leaf.path
            .split(separator: "/")
            .compactMap { UUID(uuidString: String($0)) }
            .compactMap { byId[$0] }
    }
}
