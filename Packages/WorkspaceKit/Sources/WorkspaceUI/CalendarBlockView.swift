import SwiftUI

/// The calendar block from DESIGN.md §3.3: filled rectangle in the container's
/// fill color, 3pt accent bar on the left, title + time range.
public struct CalendarBlockView: View {
    public enum Style: Sendable {
        case normal
        case past
        case completed
        /// Tentative / declined external events: dashed outline, no fill.
        case tentative
    }

    let title: String
    let timeText: String?
    let color: ContainerColor
    let style: Style

    public init(title: String, timeText: String? = nil, color: ContainerColor, style: Style = .normal) {
        self.title = title
        self.timeText = timeText
        self.color = color
        self.style = style
    }

    public var body: some View {
        HStack(spacing: 0) {
            Rectangle()
                .fill(color.accent)
                .frame(width: WSRadius.accentBar)
                .opacity(style == .tentative ? 0 : 1)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: WSSpace.xs) {
                    if style == .completed {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .bold))
                    }
                    Text(title)
                        .font(WSFont.blockTitle)
                        .strikethrough(style == .completed)
                        .lineLimit(2)
                }
                .foregroundStyle(WSColor.textPrimary)

                if let timeText {
                    Text(timeText)
                        .font(WSFont.blockMeta)
                        .foregroundStyle(WSColor.textSecondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, WSSpace.s)
            .padding(.vertical, WSSpace.xs + 1)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(style == .tentative ? Color.clear : color.fill)
        .overlay {
            if style == .tentative {
                RoundedRectangle(cornerRadius: WSRadius.block)
                    .strokeBorder(color.accent, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: WSRadius.block))
        .opacity(style == .past ? 0.6 : 1)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(style == .completed ? .isSelected : [])
    }
}

/// A small color dot for sidebar rows and chips.
public struct ColorDot: View {
    let color: ContainerColor
    public init(_ color: ContainerColor) { self.color = color }
    public var body: some View {
        Circle().fill(color.accent).frame(width: 8, height: 8)
    }
}

/// Visual check of tokens and block styles (Milestone 0 deliverable).
public struct TokenGallery: View {
    public init() {}

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: WSSpace.xl) {
                Text("Design tokens").font(WSFont.pageTitle).foregroundStyle(WSColor.textPrimary)

                VStack(alignment: .leading, spacing: WSSpace.s) {
                    Text("CONTAINER COLORS").font(WSFont.sectionLabel).foregroundStyle(WSColor.textSecondary)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: WSSpace.s)], spacing: WSSpace.s) {
                        ForEach(ContainerColor.allCases) { c in
                            CalendarBlockView(title: c.displayName, timeText: "9–9:45 AM", color: c)
                                .frame(height: 44)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: WSSpace.s) {
                    Text("BLOCK STATES").font(WSFont.sectionLabel).foregroundStyle(WSColor.textSecondary)
                    HStack(spacing: WSSpace.s) {
                        CalendarBlockView(title: "Lecture 10b", timeText: "1–2:45 PM", color: .green)
                        CalendarBlockView(title: "Get Ready", timeText: "9:30–10:15 AM", color: .grey, style: .past)
                        CalendarBlockView(title: "Study for Quiz 4", timeText: "7–8 PM", color: .steel, style: .completed)
                        CalendarBlockView(title: "weekly HEI meeting", timeText: "3–4 PM", color: .steel, style: .tentative)
                    }
                    .frame(height: 64)
                }

                VStack(alignment: .leading, spacing: WSSpace.s) {
                    Text("NOW LINE").font(WSFont.sectionLabel).foregroundStyle(WSColor.textSecondary)
                    HStack(spacing: 0) {
                        Text("3:24 PM")
                            .font(WSFont.blockMeta.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(WSColor.now, in: RoundedRectangle(cornerRadius: 4))
                        Rectangle().fill(WSColor.now).frame(height: 1)
                    }
                }
            }
            .padding(WSSpace.xl)
        }
        .background(WSColor.canvas)
    }
}

#Preview("Tokens") {
    TokenGallery().frame(width: 720, height: 420)
}
