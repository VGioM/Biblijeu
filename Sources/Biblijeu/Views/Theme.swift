import SwiftUI

/// Music.app's dark-mode greys with the system blue for the accent.
/// Shared with Biblifilm so the two apps read as one family: a colour
/// changed here has to be changed there too.
enum Theme {
    static let accent = Color(red: 0.04, green: 0.52, blue: 1.00)      // macOS system blue
    /// Warnings only -- a missing emulator has to stand apart from the accent.
    static let accentWarm = Color(red: 0.98, green: 0.62, blue: 0.24)
    static let windowBackground = Color(red: 0.13, green: 0.13, blue: 0.14)
    static let contentBackground = Color(red: 0.11, green: 0.11, blue: 0.12)
    static let cardBackground = Color(red: 0.17, green: 0.17, blue: 0.18)
    static let hairline = Color.white.opacity(0.08)

    static let coverRadius: CGFloat = 9
    /// Box art comes in every shape; the tile keeps one so the grid stays even.
    static let coverAspect: CGFloat = 3.0 / 4.0

    /// Deterministic placeholder gradient so an artwork-less card still looks intentional.
    static func placeholderGradient(for seed: String) -> LinearGradient {
        var hash = 5381
        for byte in seed.utf8 { hash = (hash &* 33 &+ Int(byte)) & 0xFFFFFF }
        let hue = Double(hash % 360) / 360.0
        return LinearGradient(
            colors: [
                Color(hue: hue, saturation: 0.36, brightness: 0.40),
                Color(hue: (hue + 0.09).truncatingRemainder(dividingBy: 1),
                      saturation: 0.44, brightness: 0.22)
            ],
            startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

/// Loads cover art through the on-disk cache, with a graceful placeholder.
///
/// A GameCube box is 4:3, a Switch cover 3:4, an app icon square. Rather than
/// crop them all to one shape, the picture is fitted and a blurred copy of
/// itself fills the space behind it -- the way Music.app handles odd artwork.
struct ArtworkView: View {
    let ref: ArtworkRef
    let seed: String
    var symbol: String = "gamecontroller"
    var aspect: CGFloat = Theme.coverAspect
    var cornerRadius: CGFloat = Theme.coverRadius
    var showsPlaceholderSymbol = true

    @State private var image: NSImage?
    @State private var loadedKey: String?
    @State private var isLoading = false

    var body: some View {
        // `Color.clear` sets the size; the picture lives in an overlay, which
        // never feeds its own size back to the layout. Without this a
        // `.fill` image reports a size larger than its tile and spills over
        // the neighbouring cards.
        Color.clear
            .aspectRatio(aspect, contentMode: .fit)
            .overlay { content }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.09), lineWidth: 0.5))
            .task(id: ref) { await load() }
    }

    @ViewBuilder
    private var content: some View {
        if let image {
            // A GameCube box is 4:3, a PS1 jewel case almost square, an app
            // icon exactly square. Fit the picture, and fill the leftover space
            // with a blurred copy of itself rather than cropping.
            //
            // Everything hangs off `Color.clear`, which is the only view here
            // that takes the tile's size and nothing more. A `.scaledToFill()`
            // image reports a size *larger* than the tile, so putting it in a
            // ZStack would stretch the stack -- and the fitted copy beside it
            // would then be laid out against that larger box and lose its edges
            // to the clip. As an overlay it can spill without moving anything.
            Color.clear
                .overlay {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                        .blur(radius: 22)
                        .opacity(0.55)
                }
                .overlay(Color.black.opacity(0.28))
                .overlay {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                }
        } else {
            ZStack {
                Theme.placeholderGradient(for: seed)
                if showsPlaceholderSymbol {
                    Image(systemName: symbol)
                        .font(.system(size: 26, weight: .light))
                        .foregroundStyle(.white.opacity(0.42))
                }
                if isLoading {
                    ProgressView().controlSize(.small).opacity(0.6)
                }
            }
        }
    }

    private func load() async {
        guard !ref.isEmpty else {
            image = nil
            loadedKey = nil
            return
        }
        // Keep showing the current cover if this is the same image re-appearing
        // (scrolling, window resize) -- clearing it first causes a visible flash.
        guard loadedKey != ref.cacheKey else { return }

        isLoading = true
        let loaded = await ArtworkCache.shared.image(for: ref)
        isLoading = false
        guard !Task.isCancelled else { return }
        loadedKey = loaded != nil ? ref.cacheKey : nil
        withAnimation(.easeOut(duration: 0.22)) { image = loaded }
    }
}
