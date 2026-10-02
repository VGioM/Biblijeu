import SwiftUI

/// One grid tile: cover art, title, and the badges that say what it is.
struct GameCard: View {
    let item: GameItem
    let isSelected: Bool
    /// nil when nothing installed can run this ROM.
    let emulator: InstalledEmulator?
    let onPlay: () -> Void
    let onInfo: () -> Void

    @ObservedObject private var play = PlayStore.shared
    @State private var isHovering = false

    private var isFavorite: Bool { play.isFavorite(item.id) }
    private var playable: Bool { item.kind != .rom || emulator != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            cover
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text(item.subtitle)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if isFavorite {
                        Image(systemName: "heart.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(Theme.accent)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(7)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isSelected ? Color.white.opacity(0.10) : .clear))
        .animation(.easeOut(duration: 0.16), value: isHovering)
        .onHover { isHovering = $0 }
        .contentShape(Rectangle())
    }

    private var cover: some View {
        ZStack {
            ArtworkView(
                ref: ArtworkService.reference(for: item),
                seed: item.sortTitle,
                symbol: item.symbol,
                // One shape for every tile, so the rows of the grid line up
                // whatever the cover's own proportions are.
                aspect: Theme.coverAspect)

            if isHovering {
                RoundedRectangle(cornerRadius: Theme.coverRadius, style: .continuous)
                    .fill(.black.opacity(0.36))
                    .transition(.opacity)
                HStack(spacing: 10) {
                    circleButton("play.fill", action: onPlay).disabled(!playable)
                    circleButton("info", action: onInfo)
                }
                .transition(.scale(scale: 0.85).combined(with: .opacity))
            }

            // Bottom-left: the console, so a mixed grid stays readable.
            if item.kind == .rom, let system = item.system {
                badge(system.shortName)
                    .padding(6)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            } else {
                badge(item.kind.label)
                    .padding(6)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            }

            if item.isMultiDisc {
                badge("\(item.discs.count) disques")
                    .padding(6)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            }

            if !playable {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(.black, Theme.accentWarm)
                    .padding(7)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .help("Aucun émulateur installé pour cette console")
            }
        }
        .shadow(color: .black.opacity(0.42), radius: isHovering ? 11 : 5,
                x: 0, y: isHovering ? 6 : 3)
        .scaleEffect(isHovering ? 1.022 : 1)
    }

    private func badge(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.white.opacity(0.95))
            .padding(.horizontal, 6)
            .padding(.vertical, 2.5)
            .background(Capsule().fill(.black.opacity(0.62)))
            .overlay(Capsule().strokeBorder(.white.opacity(0.22), lineWidth: 0.5))
    }

    private func circleButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 38, height: 38)
                .background(Circle().fill(.black.opacity(0.55)))
                .overlay(Circle().strokeBorder(.white.opacity(0.85), lineWidth: 1.2))
        }
        .buttonStyle(.plain)
    }
}
