import SwiftUI

// A ruled notepad for the Today checklist: header band, blue-gray rules, red
// margin line. Muted in dark mode so it stands out without glaring.

extension WSColor {
    public static let paper       = Color.dynamic(light: 0xFBF8F1, dark: 0x23211D)
    public static let paperHeader = Color.dynamic(light: 0xEFE8D8, dark: 0x2D2A25)
    public static let paperRule   = Color.dynamic(light: 0xD9E1EC, dark: 0x33363B)
    public static let paperMargin = Color.dynamic(light: 0xE5A0A0, dark: 0x6E3236)
    public static let paperEdge   = Color.dynamic(light: 0xE4DCCB, dark: 0x34302A)
}

public enum NotepadMetrics {
    /// Every line on the pad is this tall, so rows sit on the rules.
    public static let lineHeight: CGFloat = 36
    /// Left of the margin: checkboxes. Right of it: writing.
    public static let marginX: CGFloat = 40
}

/// The pad itself. Put `NotepadRow`s (and `NotepadBlankLine`s) inside.
public struct Notepad<Content: View>: View {
    let title: String
    let subtitle: String?
    let content: Content

    public init(title: String, subtitle: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Glued top of the pad.
            HStack(alignment: .firstTextBaseline, spacing: WSSpace.s) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(WSColor.textPrimary)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 12, weight: .regular, design: .rounded))
                        .foregroundStyle(WSColor.textSecondary)
                }
                Spacer()
            }
            .padding(.leading, NotepadMetrics.marginX + WSSpace.s)
            .padding(.trailing, WSSpace.l)
            .frame(height: 40)
            .background(WSColor.paperHeader)
            .overlay(alignment: .bottom) {
                Rectangle().fill(WSColor.paperEdge).frame(height: 1)
            }

            VStack(spacing: 0) { content }
                .padding(.bottom, WSSpace.xs)
                .background(alignment: .leading) {
                    Rectangle()
                        .fill(WSColor.paperMargin)
                        .frame(width: 1)
                        .padding(.leading, NotepadMetrics.marginX)
                }
        }
        .background(WSColor.paper)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(WSColor.paperEdge))
        .shadow(color: .black.opacity(0.22), radius: 6, y: 3)
    }
}

/// One checklist line on the pad.
public struct NotepadRow<Trailing: View>: View {
    let title: String
    let subtitle: String?
    let isDone: Bool
    let ink: ContainerColor
    let isSelected: Bool
    let onToggle: () -> Void
    let trailing: Trailing

    public init(title: String, subtitle: String? = nil, isDone: Bool, ink: ContainerColor,
                isSelected: Bool = false, onToggle: @escaping () -> Void,
                @ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
        self.title = title
        self.subtitle = subtitle
        self.isDone = isDone
        self.ink = ink
        self.isSelected = isSelected
        self.onToggle = onToggle
        self.trailing = trailing()
    }

    public var body: some View {
        HStack(spacing: 0) {
            Button(action: onToggle) {
                ZStack {
                    RoundedRectangle(cornerRadius: 3)
                        .strokeBorder(ink.accent, lineWidth: 1.5)
                        .frame(width: 15, height: 15)
                    if isDone {
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .heavy))
                            .foregroundStyle(ink.accent)
                            .offset(x: 1, y: -1)
                    }
                }
                .frame(width: NotepadMetrics.marginX, height: NotepadMetrics.lineHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isDone ? "Mark not done" : "Mark done")

            HStack(alignment: .firstTextBaseline, spacing: WSSpace.s) {
                Text(title)
                    .font(.system(size: 14, design: .rounded))
                    .foregroundStyle(isDone ? WSColor.textTertiary : WSColor.textPrimary)
                    .strikethrough(isDone, color: ink.accent.opacity(0.8))
                    .lineLimit(1)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(WSColor.textTertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: WSSpace.s)
                trailing
                    .font(.system(size: 11.5, design: .rounded).monospacedDigit())
                    .foregroundStyle(WSColor.textSecondary)
            }
            .padding(.leading, WSSpace.s + 2)
            .padding(.trailing, WSSpace.l)
        }
        .frame(height: NotepadMetrics.lineHeight)
        .background(isSelected ? ink.fill.opacity(0.45) : .clear)
        .overlay(alignment: .bottom) {
            Rectangle().fill(WSColor.paperRule).frame(height: 1)
        }
        .contentShape(Rectangle())
    }
}

/// An empty ruled line, optionally with faint placeholder text (e.g. "Add to today…").
public struct NotepadBlankLine: View {
    let placeholder: String?
    let action: (() -> Void)?

    public init(placeholder: String? = nil, action: (() -> Void)? = nil) {
        self.placeholder = placeholder
        self.action = action
    }

    public var body: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: NotepadMetrics.marginX)
            if let placeholder {
                Text(placeholder)
                    .font(.system(size: 13, design: .rounded))
                    .foregroundStyle(WSColor.textTertiary)
                    .padding(.leading, WSSpace.s + 2)
            }
            Spacer()
        }
        .frame(height: NotepadMetrics.lineHeight)
        .overlay(alignment: .bottom) {
            Rectangle().fill(WSColor.paperRule).frame(height: 1)
        }
        .contentShape(Rectangle())
        .onTapGesture { action?() }
    }
}
