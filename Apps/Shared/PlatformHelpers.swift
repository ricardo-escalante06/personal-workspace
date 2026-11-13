import SwiftUI

extension View {
    /// Esc closes sheets and palettes on both platforms.
    func onEscape(_ action: @escaping () -> Void) -> some View {
        #if os(macOS)
        onExitCommand(perform: action)
        #else
        onKeyPress(.escape) { action(); return .handled }
        #endif
    }

    /// Checkbox on Mac, switch on iPhone.
    func checkboxToggleStyle() -> some View {
        #if os(macOS)
        toggleStyle(.checkbox)
        #else
        toggleStyle(.switch)
        #endif
    }
}

#if os(macOS)
import AppKit

/// Window-level key handling for views that don't hold keyboard focus (like the
/// calendar grid after clicking a block). Keys typed into a text field are never
/// intercepted. Return true from the handler to consume the key.
struct KeyDownCatcher: NSViewRepresentable {
    let handler: (NSEvent) -> Bool

    func makeNSView(context: Context) -> NSView {
        context.coordinator.install()
        return NSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.handler = handler
        context.coordinator.view = nsView
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.uninstall()
    }

    func makeCoordinator() -> Coordinator { Coordinator(handler: handler) }

    @MainActor final class Coordinator {
        var handler: (NSEvent) -> Bool
        weak var view: NSView?
        private var monitor: Any?

        init(handler: @escaping (NSEvent) -> Bool) { self.handler = handler }

        func install() {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let window = self.view?.window, event.window === window else { return event }
                // Typing in a field (title, search, inspector): leave the key alone.
                if window.firstResponder is NSText { return event }
                // Only plain keys; ⌘/⌃/⌥ shortcuts go to menus as usual.
                if !event.modifierFlags.intersection([.command, .control, .option]).isEmpty { return event }
                return self.handler(event) ? nil : event
            }
        }

        func uninstall() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}
#endif

/// Keyboard modifiers held right now (for ⌘-click / ⇧-click selection).
enum Platform {
    #if os(macOS)
    static let deviceName = "Mac"
    #else
    static let deviceName = "iPhone"
    #endif

    static func copy(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }
    struct Modifiers: OptionSet {
        let rawValue: Int
        static let command = Modifiers(rawValue: 1)
        static let shift = Modifiers(rawValue: 2)
    }

    @MainActor static var modifierFlags: Modifiers {
        #if os(macOS)
        let flags = NSEvent.modifierFlags
        var out: Modifiers = []
        if flags.contains(.command) { out.insert(.command) }
        if flags.contains(.shift) { out.insert(.shift) }
        return out
        #else
        return []
        #endif
    }
}
