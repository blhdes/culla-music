import SwiftUI
import UIKit

/// Reliable color-scheme override for content shown in a `.sheet`.
///
/// Why this exists: changing the theme *while a sheet is already on screen* does
/// not reliably restyle the sheet. A sheet lives in its own hosting controller,
/// and UIKit doesn't re-cascade an ancestor's (or the window's) appearance to an
/// already-presented modal — and SwiftUI's `.preferredColorScheme` push to the
/// sheet's host is intermittent. The visible result is a half-themed sheet:
/// `.primary`/`.secondary` text (driven by SwiftUI's environment) flips, but
/// `Color(.systemBackground)` and glass materials (driven by the UIKit *trait
/// collection*) keep the old appearance — or nothing updates until the sheet is
/// dismissed and re-presented.
///
/// This sets `overrideUserInterfaceStyle` straight on the sheet's hosting
/// controller, so the whole sheet — bars, background, materials, and text — all
/// re-resolve together every time the value changes.
extension View {
    /// Use in place of `.preferredColorScheme` on the root of a sheet's content.
    /// Pass `nil` to defer to the system/inherited appearance ("System" mode).
    func sheetColorScheme(_ scheme: ColorScheme?) -> some View {
        background(
            InterfaceStyleHost(style: scheme.resolvedInterfaceStyle)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        )
    }
}

/// Invisible bridge view: finds the sheet's hosting controller and pins its
/// `overrideUserInterfaceStyle`. Zero-sized, so it never affects layout.
private struct InterfaceStyleHost: UIViewControllerRepresentable {
    let style: UIUserInterfaceStyle

    func makeUIViewController(context: Context) -> Controller { Controller() }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.apply(style)
    }

    final class Controller: UIViewController {
        private var style: UIUserInterfaceStyle = .unspecified

        func apply(_ style: UIUserInterfaceStyle) {
            self.style = style
            applyToHost()
        }

        // Re-apply whenever we (re)enter the hierarchy, so the *initial*
        // presentation is styled too — not just later live changes.
        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            applyToHost()
        }

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            applyToHost()
        }

        private func applyToHost() {
            // Walk up to the top of this presentation — the sheet's own hosting
            // controller. (`.parent` stops there: a presented sheet's host has
            // no parent, so this never leaks into the presenting screen.)
            var host: UIViewController = self
            while let parent = host.parent { host = parent }
            guard host !== self, host.overrideUserInterfaceStyle != style else { return }
            host.overrideUserInterfaceStyle = style
        }
    }
}

private extension Optional where Wrapped == ColorScheme {
    /// `.unspecified` means "inherit" — i.e. follow the system in "System" mode.
    var resolvedInterfaceStyle: UIUserInterfaceStyle {
        switch self {
        case .light: .light
        case .dark:  .dark
        default:     .unspecified
        }
    }
}
