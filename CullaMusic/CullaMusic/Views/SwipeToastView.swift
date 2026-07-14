import SwiftUI

/// Semantic category for a swipe-session toast. Drives the trailing icon and
/// its role color in `SwipeToastView`. Deliberately SwiftUI-free (just an SF
/// Symbol name + a role) so the view model can tag each `setToast(...)` without
/// reaching into the view layer.
enum ToastKind {
    case loved
    case added
    case dismissed
    case skipped
    case removed
    case restored
    case created
    case renamed
    case forgotten
    case error
    case info

    /// SF Symbol shown inside the trailing glass dot.
    var systemImage: String {
        switch self {
        case .loved:     return "heart.fill"
        case .added:     return "plus"
        case .dismissed: return "xmark"
        case .skipped:   return "forward.fill"
        case .removed:   return "trash.fill"
        case .restored:  return "arrow.uturn.backward"
        case .created:   return "folder.badge.plus"
        case .renamed:   return "pencil"
        case .forgotten: return "tray.and.arrow.up.fill"
        case .error:     return "exclamationmark.triangle.fill"
        case .info:      return "info.circle.fill"
        }
    }

    /// Which of the three semantic tiers colors the icon.
    var role: ToastRole {
        switch self {
        case .loved, .added, .created, .restored:
            return .positive
        case .dismissed, .skipped, .renamed, .forgotten, .info:
            return .neutral
        case .removed, .error:
            return .destructive
        }
    }
}

/// Three semantic tiers that color a toast's icon: the brand/album accent for
/// wins, neutral gray for housekeeping, red for destructive or failed actions.
/// Text always stays `.primary` — only the small dot rides the color, so the
/// pill never goes loud (matches the project's accent-restraint stance).
enum ToastRole {
    case positive
    case neutral
    case destructive
}

/// The swipe-session status pill: one line of text with a trailing glass "dot"
/// carrying an action icon. On iOS 26 the dot and the pill share a
/// `GlassEffectContainer`, so their glass refracts into each other; older OSes
/// fall back to stacked `.thinMaterial`. The icon does a one-shot bounce as the
/// toast lands and again on every back-to-back message change.
struct SwipeToastView: View {
    let message: String
    let kind: ToastKind

    /// Album-derived accent for positive toasts — but *frozen at the instant
    /// the toast was set*, not read live from the environment. A sort toast
    /// only lands as the next card slides in, by which point the live
    /// `appAccent` has already begun shifting to the new song's artwork. Passing
    /// the snapshot in keeps the icon tinted by the song you actually sorted.
    let accent: Color

    /// Bumped on appear (deferred one tick) and on every message change to
    /// re-fire the symbol bounce. An Int so `.symbolEffect(value:)` always sees
    /// a fresh value, even for two consecutive same-kind toasts.
    @State private var bounceTick = 0

    private var roleColor: Color {
        switch kind.role {
        case .positive:    return accent
        case .neutral:     return .secondary
        case .destructive: return .red
        }
    }

    var body: some View {
        Group {
            if #available(iOS 26.0, *), !DebugFlags.forceLegacyUI {
                GlassEffectContainer(spacing: 6) { pill }
            } else {
                pill
            }
        }
        .onAppear {
            // One-tick defer so the symbol-effect coordinator sees the icon
            // laid out before the value flips — otherwise the first bounce
            // silently drops on a fraction of appearances.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                bounceTick += 1
            }
        }
        .onChange(of: message) { _, _ in
            // Back-to-back toasts update this view in place (no re-appear), so
            // re-trigger the bounce when the text swaps under it.
            bounceTick += 1
        }
    }

    private var pill: some View {
        HStack(spacing: 8) {
            Text(message)
                .font(.footnote.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
                .contentTransition(.opacity)
            iconDot
        }
        .padding(.leading, 14)
        .padding(.trailing, 5)
        .padding(.vertical, 5)
        // Cap long titles at 280pt, but let short toasts hug their text. A
        // bare `maxWidth` frame *expands* to fill the proposal (that's why
        // every toast used to render 280 wide); `fixedSize` makes the frame
        // size to the text's ideal width instead, with 280 still the ceiling
        // so lineLimit(1) truncation kicks in for long messages.
        .frame(maxWidth: 280)
        .fixedSize(horizontal: true, vertical: false)
        .glassSurface(in: Capsule())
        // Hairline edge so the pill reads against bright artwork — the flat
        // glass alone melted into light covers.
        .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
        .animation(.easeInOut(duration: 0.2), value: message)
    }

    private var iconDot: some View {
        Image(systemName: kind.systemImage)
            .font(.caption2.weight(.bold))
            .foregroundStyle(roleColor)
            .symbolEffect(.bounce, value: bounceTick)
            .frame(width: 20, height: 20)
            // Plain frosted glass for EVERY role. The icon itself carries the
            // role color, so tinting the dot with that same color washed the
            // glyph out — an accent icon on an accent dot read as "just a
            // color, no icon." Neutral glass lets the colored glyph stay legible.
            .glassSurface(in: Circle())
    }
}
