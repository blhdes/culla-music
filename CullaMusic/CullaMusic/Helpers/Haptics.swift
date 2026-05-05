import UIKit

enum Haptics {
    static func swipeLeft()  { impact(.light)  }   // dismiss
    static func swipeRight() { impact(.medium) }   // assign to playlist
    static func skip()       { impact(.soft)   }   // double-tap → skip (session-only)
    static func tap()        { impact(.light)  }
    static func confirm()    { notification(.success) }

    private static func impact(_ style: UIImpactFeedbackGenerator.FeedbackStyle) {
        guard UserDefaults.standard.bool(forKey: "hapticsEnabled") else { return }
        UIImpactFeedbackGenerator(style: style).impactOccurred()
    }

    private static func notification(_ type: UINotificationFeedbackGenerator.FeedbackType) {
        guard UserDefaults.standard.bool(forKey: "hapticsEnabled") else { return }
        UINotificationFeedbackGenerator().notificationOccurred(type)
    }
}
