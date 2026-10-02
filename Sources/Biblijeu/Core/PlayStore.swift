import Foundation
import Combine

/// Everything Biblijeu remembers about a game between launches: when it was
/// last played, whether it is a favourite, which emulator to use for it, and
/// the cover art that was found for it.
struct GameState: Codable, Hashable {
    var lastPlayed: Date?
    var playCount: Int = 0
    var favorite: Bool = false
    var hidden: Bool = false
    /// Overrides the system default for this one game.
    var emulatorID: String?
    /// Remote cover art resolved by the artwork service.
    var artworkURL: String?
    /// A cover the user picked by hand; wins over everything else.
    var customArtworkPath: String?
    /// A lookup already ran and came back empty -- don't hammer the network.
    var artworkMissing: Bool = false
    /// Title the user corrected by hand, used for the next artwork search.
    var searchTitle: String?
    /// Save-state slot this game resumes from, when the emulator has slots.
    var resumeSlot: Int?
    /// A state file the user picked, for emulators that need a path.
    var stateFilePath: String?
    /// The state file the last session actually produced, spotted in the
    /// emulator's own state folder. This is what makes "Reprendre" land on the
    /// disc the game was left on rather than on the first one.
    var autoStateFile: String?
    /// When that file was written, so a later session can tell it is newer.
    var autoStateDate: Date?
    /// The disc that state was taken on, at the path it has today. The state
    /// itself remembers the path it had when it was written, which is stale as
    /// soon as the library moves to another drive.
    var autoStateDisc: String?
    /// The user disagreed with the scanner: this is a ROM, a game, an
    /// emulator, or something to keep aside. `GameKind.rawValue`.
    var kindOverride: String?
    /// The user named the console themselves, when the extension was ambiguous.
    var systemOverride: String?
    /// For an app the user declared an emulator: the consoles it can run.
    /// Without this an unknown emulator has nothing to be chosen for.
    var emulatorSystems: [String]?
    /// The CrossOver bottle this Windows game runs in, when the user named it
    /// rather than let Biblijeu work it out.
    var crossOverBottle: String?
}

@MainActor
final class PlayStore: ObservableObject {
    static let shared = PlayStore()

    @Published private(set) var states: [String: GameState] = [:]

    private let fileURL: URL
    private var saveTask: Task<Void, Never>?

    private init() {
        fileURL = AppSettings.supportDirectory.appendingPathComponent("play-state.json")
        load()
    }

    // MARK: - Reading

    func state(for id: String) -> GameState { states[id] ?? GameState() }

    func lastPlayed(_ id: String) -> Date? { states[id]?.lastPlayed }
    func isFavorite(_ id: String) -> Bool { states[id]?.favorite ?? false }
    func isHidden(_ id: String) -> Bool { states[id]?.hidden ?? false }
    func playCount(_ id: String) -> Int { states[id]?.playCount ?? 0 }

    var hasHistory: Bool { states.values.contains { $0.lastPlayed != nil } }
    var favoriteCount: Int { states.values.filter(\.favorite).count }
    var hiddenCount: Int { states.values.filter(\.hidden).count }

    // MARK: - Writing

    func update(_ id: String, _ change: (inout GameState) -> Void) {
        var state = states[id] ?? GameState()
        change(&state)
        states[id] = state
        scheduleSave()
    }

    func recordPlay(_ id: String) {
        update(id) { $0.lastPlayed = Date(); $0.playCount += 1 }
    }

    func toggleFavorite(_ id: String) {
        update(id) { $0.favorite.toggle() }
    }

    func setHidden(_ hidden: Bool, for id: String) {
        update(id) { $0.hidden = hidden }
    }

    func setEmulator(_ emulatorID: String?, for id: String) {
        update(id) { $0.emulatorID = emulatorID }
    }

    func setArtwork(_ urlString: String?, for id: String) {
        update(id) { $0.artworkURL = urlString; $0.artworkMissing = (urlString == nil) }
    }

    func setResumeSlot(_ slot: Int?, for id: String) {
        update(id) { $0.resumeSlot = slot; if slot != nil { $0.stateFilePath = nil } }
    }

    func setStateFile(_ path: String?, for id: String) {
        update(id) { $0.stateFilePath = path; if path != nil { $0.resumeSlot = nil } }
    }

    /// Records the state a finished session left behind. Older finds are
    /// ignored so a stale scan can never walk a save backwards.
    func setAutoState(_ path: String, disc: String, at date: Date, for id: String) {
        guard state(for: id).autoStateDate.map({ date > $0 }) ?? true else { return }
        update(id) { $0.autoStateFile = path; $0.autoStateDisc = disc; $0.autoStateDate = date }
    }


    func setCustomArtwork(_ path: String?, for id: String) {
        update(id) { $0.customArtworkPath = path }
    }

    /// nil puts the item back under whatever the scanner decided.
    func setKind(_ kind: GameKind?, for id: String) {
        update(id) { $0.kindOverride = kind?.rawValue }
    }

    func setSystem(_ systemID: String?, for id: String) {
        update(id) { $0.systemOverride = systemID }
    }

    func setCrossOverBottle(_ name: String?, for id: String) {
        update(id) { $0.crossOverBottle = name }
    }

    func setEmulatorSystems(_ systems: [String]?, for id: String) {
        update(id) { $0.emulatorSystems = (systems?.isEmpty ?? true) ? nil : systems }
    }

    /// Carries what was recorded under a game's old identity over to its new
    /// one. Only ever copies: the old entry stays put, so a mistaken match
    /// costs nothing and the previous file remains a faithful backup.
    func adopt(legacy pairs: [(id: String, legacy: String)]) {
        var moved = 0
        for pair in pairs where states[pair.id] == nil {
            guard let old = states[pair.legacy] else { continue }
            states[pair.id] = old
            moved += 1
        }
        if moved > 0 { scheduleSave() }
    }

    func clearHistory() {
        for key in states.keys {
            states[key]?.lastPlayed = nil
            states[key]?.playCount = 0
        }
        scheduleSave()
    }

    /// Forget resolved covers so the next scan searches again.
    func clearArtworkResolutions() {
        for key in states.keys {
            states[key]?.artworkURL = nil
            states[key]?.artworkMissing = false
        }
        scheduleSave()
    }

    // MARK: - Persistence

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        saveTask?.cancel()
        saveTask = nil
        let snapshot = states
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        // Keep the previous file around; this is the only irreplaceable state.
        let backup = fileURL.deletingPathExtension().appendingPathExtension("backup.json")
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.copyItem(at: fileURL, to: backup)
        }
        try? data.write(to: fileURL, options: .atomic)
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([String: GameState].self, from: data) else { return }
        states = decoded
    }
}
