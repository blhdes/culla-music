import UIKit

enum Haptics {
    static func swipeLeft()  { impact(.light)  }   // dismiss
    static func loved()      { impact(.medium) }   // up-swipe → Loved
    static func share()      { impact(.light)  }   // down-swipe → share
    static func sidebarDrop() { notification(.success) }  // drop into a sidebar row — heavier "landed" feel
    static func skip()       { impact(.soft)   }   // double-tap → skip (session-only)
    static func tap()        { impact(.light)  }
    static func scrubTick()  { selection() }       // scrub start / end
    static func confirm()    { notification(.success) }
    static func contextMenuOpen() { impact(.heavy) }  // long-press in Dismissed mode
    static func undo()       { selection() }       // undo tap (light tick)

    /// Haptics default to ON unless the user explicitly turned them off in
    /// Settings. Reading via `object(forKey:)` instead of `bool(forKey:)` lets
    /// us distinguish "never set" (→ default true) from "set to false" (→ off),
    /// so feedback works on first launch before `RootView.seedDefaults` runs.
    private static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: "hapticsEnabled") as? Bool ?? true
    }

    private static func impact(_ style: UIImpactFeedbackGenerator.FeedbackStyle) {
        guard isEnabled else { return }
        UIImpactFeedbackGenerator(style: style).impactOccurred()
    }

    private static func selection() {
        guard isEnabled else { return }
        UISelectionFeedbackGenerator().selectionChanged()
    }

    private static func notification(_ type: UINotificationFeedbackGenerator.FeedbackType) {
        guard isEnabled else { return }
        UINotificationFeedbackGenerator().notificationOccurred(type)
    }
}
