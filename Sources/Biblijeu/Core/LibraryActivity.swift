import Foundation

/// What the library is busy with right now, as the progress lines say it:
/// "Analyse… PS2", "Recherche des jaquettes… 40 %", "Téléchargement 42 %".
///
/// Kept apart from `LibraryModel` on purpose. Everything on screen -- the
/// grid, every tile, the sidebar and its counts -- observes the model, so each
/// change to it redraws the lot. These lines change many times a second while
/// something runs: a single emulator download moves its percentage a hundred
/// times, and the auto-update installs several in a row at launch. Here, only
/// the few views that show a progress line hear about it.
@MainActor
final class LibraryActivity: ObservableObject {
    static let shared = LibraryActivity()

    @Published var scanProgress = ""
    @Published var artworkProgress: Double = 0
    /// What an install or a signing is doing right now, by emulator id.
    @Published var emulatorActivity: [String: String] = [:]

    private init() {}
}
