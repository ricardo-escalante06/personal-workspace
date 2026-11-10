import GRDB
import SwiftUI
import WorkspaceKit
import WorkspaceUI

/// Create or edit a folder / list / class / project: name, kind and color in one place.
struct ContainerEditorSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let request: ContainerEditorRequest

    @State private var name = ""
    @State private var kind: ContainerKind = .list
    @State private var color: ContainerColor = .steel
    @State private var classSetup = ClassSetup()
    @FocusState private var nameFocused: Bool

    private var editingId: UUID? {
        if case .edit(let c) = request.mode { return c.id }
        return nil
    }

    private var isCreate: Bool {
        if case .create = request.mode { return true }
        return false
    }

    private var parent: Container? {
        switch request.mode {
        case .create(_, let parentId): model.container(parentId)
        case .edit(let c): model.container(c.parentId)
        }
    }

    /// Kinds allowed under this parent.
    private var allowedKinds: [ContainerKind] {
        ContainerKind.allCases.filter { parent?.kind.canContain($0) ?? true }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: WSSpace.l) {
            Text(isCreate ? "New \(kind.displayName)" : "Edit \(kind.displayName)")
                .font(.system(size: 15, weight: .semibold))

            // Live preview, as it will look in the sidebar.
            HStack(spacing: WSSpace.s) {
                Image(systemName: kind.symbol)
                    .foregroundStyle(color.accent)
                    .frame(width: 20)
                TextField("Name", text: $name)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .focused($nameFocused)
                    .onSubmit(save)
            }
            .padding(.horizontal, WSSpace.m).padding(.vertical, WSSpace.s)
            .background(RoundedRectangle(cornerRadius: WSRadius.block).fill(WSColor.canvas))
            .overlay(RoundedRectangle(cornerRadius: WSRadius.block).strokeBorder(WSColor.hairline))

            if allowedKinds.count > 1 {
                VStack(alignment: .leading, spacing: WSSpace.xs) {
                    Picker("Kind", selection: $kind) {
                        ForEach(allowedKinds, id: \.self) { k in
                            Text(k.displayName).tag(k)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    Text(kindHelp)
                        .font(.system(size: 11))
                        .foregroundStyle(WSColor.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(alignment: .leading, spacing: WSSpace.s) {
                Text("Color")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(WSColor.textSecondary)
                HStack(spacing: WSSpace.s) {
                    ForEach(ContainerColor.allCases) { option in
                        Button {
                            color = option
                        } label: {
                            Circle()
                                .fill(option.accent)
                                .frame(width: 22, height: 22)
                                .overlay(
                                    Circle()
                                        .strokeBorder(WSColor.textPrimary, lineWidth: color == option ? 2 : 0)
                                        .padding(-4)
                                )
                                .padding(4)
                        }
                        .buttonStyle(.plain)
                        .help(option.displayName)
                        .accessibilityLabel(option.displayName)
                        .accessibilityAddTraits(color == option ? .isSelected : [])
                    }
                }
            }

            if kind == .class {
                Divider()
                ClassScheduleEditor(setup: $classSetup, containerId: editingId)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isCreate ? "Create" : "Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(WSSpace.xl)
        .frame(width: kind == .class ? 560 : 420)
        .background(WSColor.raised)
        .onAppear(perform: load)
    }

    private var kindHelp: String {
        switch kind {
        case .folder: "Organizes lists, classes and projects. Holds no tasks itself."
        case .list: "A plain list of tasks."
        case .class: "A list with a term, assignment categories and (soon) assignment series."
        case .project: "A list with a Kanban board (coming in Milestone 3)."
        }
    }

    private func load() {
        switch request.mode {
        case .create(let k, let parentId):
            kind = allowedKinds.contains(k) ? k : (allowedKinds.first ?? .list)
            // New things inherit the parent's color; top-level ones get the next unused color.
            if let p = model.container(parentId) {
                color = ContainerColor(named: p.color)
            } else {
                let used = Set(model.containers.filter { $0.parentId == nil }.map(\.color))
                color = ContainerColor.allCases.first { !used.contains($0.rawValue) && $0 != .grey } ?? .steel
            }
        case .edit(let c):
            name = c.name
            kind = c.kind
            color = ContainerColor(named: c.color)
            if c.kind == .class { classSetup = model.loadClassSetup(for: c) }
        }
        if case .create = request.mode { classSetup.calendarId = model.calendarSource.defaultCalendarId }
        nameFocused = true
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        var setup = classSetup
        if setup.code.trimmingCharacters(in: .whitespaces).isEmpty { setup.code = trimmed }
        if model.saveContainer(request, name: trimmed, kind: kind, color: color.rawValue,
                               classSetup: kind == .class ? setup : nil) {
            dismiss()
        }
    }
}

/// Colored dots for menus. Menus draw SF Symbols as monochrome templates, so the
/// swatch is rendered as a non-template image.
enum ColorSwatchImage {
    static func image(hex: UInt32) -> Image { swatch(Color(hex: hex)) }

    static func image(for color: ContainerColor) -> Image { swatch(color.accent) }

    private static func swatch(_ color: Color) -> Image {
        #if os(macOS)
        let size = NSSize(width: 12, height: 12)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor(color).setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5)).fill()
            return true
        }
        image.isTemplate = false
        return Image(nsImage: image)
        #else
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 12, height: 12))
        let image = renderer.image { _ in
            UIColor(color).setFill()
            UIBezierPath(ovalIn: CGRect(x: 0.5, y: 0.5, width: 11, height: 11)).fill()
        }
        return Image(uiImage: image.withRenderingMode(.alwaysOriginal))
        #endif
    }
}
