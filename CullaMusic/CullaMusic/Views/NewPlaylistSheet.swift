import SwiftUI

/// Compact "create a playlist" card. Replaces the old `.medium` Form — which
/// rose tall-and-empty, then brought the keyboard up as a *second* motion — with
/// a content-hugging custom-height sheet that settles in one move with the
/// keyboard. Identity header + one glass field + the project's gradient CTA,
/// kept calm to match its now-native parent (`ManagePlaylistsSheet`).
struct NewPlaylistSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var name: String = ""
    @State private var iconBounce = false
    @FocusState private var isFocused: Bool

    /// Drives the custom detent. `@ScaledMetric` so the card grows with the
    /// user's Dynamic Type setting instead of clipping the CTA at large sizes.
    @ScaledMetric private var sheetHeight: CGFloat = 360

    let onCreate: (String) -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header
                    .padding(.top, 28)

                Spacer(minLength: 16)

                // Field + CTA ride together at the bottom so they sit right
                // above the keyboard — thumb-reachable, unlike a top-bar "Save".
                VStack(spacing: 14) {
                    nameField
                    GradientCapsuleButton(title: "Create playlist", icon: "plus", action: submit)
                        .disabled(trimmedName.isEmpty)
                        .opacity(trimmedName.isEmpty ? 0.5 : 1)
                        .animation(.snappy(duration: 0.2), value: trimmedName.isEmpty)
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 20)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onAppear(perform: onAppear)
        }
        .presentationDetents([.height(sheetHeight)])
        .presentationDragIndicator(.visible)
    }

    // MARK: - Pieces

    private var header: some View {
        VStack(spacing: 10) {
            Image(systemName: "music.note.list")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 60, height: 60)
                .glassSurface(in: Circle())
                .symbolEffect(.bounce, value: iconBounce)

            VStack(spacing: 3) {
                Text("New Playlist")
                    .font(.system(.title2, design: .rounded).weight(.bold))
                Text("Name it now — add songs later.")
                    .font(.system(.subheadline, design: .rounded))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .multilineTextAlignment(.center)
    }

    private var nameField: some View {
        TextField("Playlist name", text: $name)
            .font(.system(.body, design: .rounded))
            .focused($isFocused)
            .submitLabel(.done)
            .onSubmit(submit)
            .textInputAutocapitalization(.words)
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .glassSurface(in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // MARK: - Logic (unchanged)

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func submit() {
        guard !trimmedName.isEmpty else { return }
        onCreate(trimmedName)
        dismiss()
    }

    /// Focus immediately so the keyboard rises *with* the sheet (no tall-then-
    /// keyboard stagger). The header bounce fires one runloop tick later — the
    /// symbol-effect coordinator can miss a value flip made inline in `onAppear`
    /// — and is skipped entirely under reduce-motion.
    private func onAppear() {
        isFocused = true
        guard !reduceMotion else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            iconBounce = true
        }
    }
}
