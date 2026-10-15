import Foundation
import Combine

/// User preferences, persisted in UserDefaults.
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    /// Folders scanned for ROMs, in the order the user added them.
    @Published var romFolders: [String] {
        didSet { defaults.set(romFolders, forKey: Keys.romFolders) }
    }
    /// Folders scanned for .app bundles.
    @Published var applicationFolders: [String] {
        didSet { defaults.set(applicationFolders, forKey: Keys.appFolders) }
    }
    /// Apps the user added one by one, because the scan does not take them
    /// for games. Always listed as games, wherever they live.
    @Published var manualApplications: [String] {
        didSet { defaults.set(manualApplications, forKey: Keys.manualApps) }
    }
    @Published var scanApplications: Bool {
        didSet { defaults.set(scanApplications, forKey: Keys.scanApps) }
    }
    /// Boot straight into the game, fullscreen, without the emulator's interface.
    @Published var directLaunch: Bool {
        didSet { defaults.set(directLaunch, forKey: Keys.directLaunch) }
    }
    /// Start on the game's save state when the emulator can do it.
    @Published var resumeOnLaunch: Bool {
        didSet { defaults.set(resumeOnLaunch, forKey: Keys.resumeOnLaunch) }
    }
    @Published var autoFetchArtwork: Bool {
        didSet { defaults.set(autoFetchArtwork, forKey: Keys.autoArtwork) }
    }
    @Published var steamGridDBKey: String {
        didSet { defaults.set(steamGridDBKey, forKey: Keys.sgdbKey) }
    }
    /// Preferred region when several dumps share a title ("Europe", "USA"…).
    @Published var preferredRegion: String {
        didSet { defaults.set(preferredRegion, forKey: Keys.region) }
    }
    @Published var watchFolders: Bool {
        didSet { defaults.set(watchFolders, forKey: Keys.watchFolders) }
    }
    @Published var cardSize: Double {
        didSet { defaults.set(cardSize, forKey: Keys.cardSize) }
    }
    /// systemID -> emulator id, when the user does not want the default.
    @Published var emulatorForSystem: [String: String] {
        didSet { defaults.set(emulatorForSystem, forKey: Keys.emulatorForSystem) }
    }
    /// Emulators the user pointed at by hand, because nothing detected them:
    /// app path -> the consoles it runs.
    @Published var manualEmulators: [String: [String]] {
        didSet { defaults.set(manualEmulators, forKey: Keys.manualEmulators) }
    }

    /// Where the saves are copied: a folder on the drive the user keeps their
    /// backups on. Empty until they pick one.
    @Published var backupDestination: String {
        didSet { defaults.set(backupDestination, forKey: Keys.backupDestination) }
    }
    /// Copy the saves by itself: on a timer, at launch and when quitting.
    @Published var autoBackup: Bool {
        didSet { defaults.set(autoBackup, forKey: Keys.autoBackup) }
    }
    /// The timer that runs while Biblijeu is open. Separate from `autoBackup`
    /// so that somebody can keep the copies at launch and at quit -- the two
    /// moments that matter -- without the drive being woken every half hour.
    @Published var backupOnInterval: Bool {
        didSet { defaults.set(backupOnInterval, forKey: Keys.backupOnInterval) }
    }
    @Published var backupIntervalMinutes: Int {
        didSet { defaults.set(backupIntervalMinutes, forKey: Keys.backupInterval) }
    }
    @Published var backupOnLaunch: Bool {
        didSet { defaults.set(backupOnLaunch, forKey: Keys.backupOnLaunch) }
    }
    @Published var backupOnQuit: Bool {
        didSet { defaults.set(backupOnQuit, forKey: Keys.backupOnQuit) }
    }
    /// Which kinds of folder the backup covers, by `SaveKind` raw value.
    ///
    /// Everything that holds a save is on by default. The virtual SD cards are
    /// not: that is where a Switch or 3DS emulator keeps the games, mods and
    /// DLC *installed* into it, which is a copy of a ROM rather than a save.
    @Published var backupKinds: [String] {
        didSet { defaults.set(backupKinds, forKey: Keys.backupKinds) }
    }
    /// Emulators left out of the backup, by id.
    @Published var backupExcludedEmulators: [String] {
        didSet { defaults.set(backupExcludedEmulators, forKey: Keys.backupExcluded) }
    }

    /// Download and install an emulator's new build as soon as the daily
    /// check finds one, instead of only pointing at its page.
    @Published var autoInstallUpdates: Bool {
        didSet { defaults.set(autoInstallUpdates, forKey: Keys.autoInstallUpdates) }
    }
    /// Lift the quarantine and sign again, locally, any emulator whose build
    /// changed and whose signature no longer holds.
    @Published var autoSignEmulators: Bool {
        didSet { defaults.set(autoSignEmulators, forKey: Keys.autoSignEmulators) }
    }

    private let defaults = UserDefaults.standard

    private enum Keys {
        static let romFolders = "romFolders"
        static let appFolders = "applicationFolders"
        static let scanApps = "scanApplications"
        static let manualApps = "manualApplications"
        static let directLaunch = "directLaunch"
        static let resumeOnLaunch = "resumeOnLaunch"
        static let autoArtwork = "autoFetchArtwork"
        static let sgdbKey = "steamGridDBKey"
        static let region = "preferredRegion"
        static let watchFolders = "watchFolders"
        static let cardSize = "cardSize"
        static let emulatorForSystem = "emulatorForSystem"
        static let manualEmulators = "manualEmulators"
        static let backupDestination = "backupDestination"
        static let autoBackup = "autoBackup"
        static let backupInterval = "backupIntervalMinutes"
        static let backupOnInterval = "backupOnInterval"
        static let backupOnLaunch = "backupOnLaunch"
        static let backupOnQuit = "backupOnQuit"
        static let backupStates = "backupStates"   // remplacé par backupKinds
        static let backupKinds = "backupKinds"
        static let backupExcluded = "backupExcludedEmulators"
        static let autoInstallUpdates = "autoInstallUpdates"
        static let autoSignEmulators = "autoSignEmulators"
    }

    private init() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        defaults.register(defaults: [
            Keys.appFolders: ["/Applications", "\(home)/Applications"],
            Keys.scanApps: true,
            Keys.directLaunch: true,
            Keys.resumeOnLaunch: true,
            Keys.autoArtwork: true,
            Keys.region: "Europe",
            Keys.watchFolders: true,
            Keys.cardSize: 168.0,
            Keys.backupInterval: 30,
            // On by default: this is how the backup behaved before the switch
            // existed, and a new switch must not quietly turn something off.
            Keys.backupOnInterval: true,
            Keys.backupOnLaunch: true,
            Keys.backupOnQuit: true,
            Keys.backupKinds: AppSettings.defaultBackupKinds,
            Keys.autoInstallUpdates: true,
            Keys.autoSignEmulators: true
        ])
        romFolders = defaults.stringArray(forKey: Keys.romFolders) ?? []
        applicationFolders = defaults.stringArray(forKey: Keys.appFolders)
            ?? ["/Applications", "\(home)/Applications"]
        manualApplications = defaults.stringArray(forKey: Keys.manualApps) ?? []
        scanApplications = defaults.bool(forKey: Keys.scanApps)
        directLaunch = defaults.bool(forKey: Keys.directLaunch)
        resumeOnLaunch = defaults.bool(forKey: Keys.resumeOnLaunch)
        autoFetchArtwork = defaults.bool(forKey: Keys.autoArtwork)
        steamGridDBKey = defaults.string(forKey: Keys.sgdbKey) ?? ""
        preferredRegion = defaults.string(forKey: Keys.region) ?? "Europe"
        watchFolders = defaults.bool(forKey: Keys.watchFolders)
        cardSize = defaults.double(forKey: Keys.cardSize)
        emulatorForSystem = defaults.dictionary(forKey: Keys.emulatorForSystem) as? [String: String] ?? [:]
        manualEmulators = defaults.dictionary(forKey: Keys.manualEmulators) as? [String: [String]] ?? [:]
        backupDestination = defaults.string(forKey: Keys.backupDestination) ?? ""
        autoBackup = defaults.bool(forKey: Keys.autoBackup)
        backupIntervalMinutes = defaults.integer(forKey: Keys.backupInterval)
        backupOnInterval = defaults.bool(forKey: Keys.backupOnInterval)
        backupOnLaunch = defaults.bool(forKey: Keys.backupOnLaunch)
        backupOnQuit = defaults.bool(forKey: Keys.backupOnQuit)
        // The single "include save states" switch this replaces: somebody who
        // had turned it off asked for the states to be left out, and that
        // answer is worth carrying over rather than quietly undoing. Read
        // before the property is set, since nothing may touch `self` until
        // every stored property has a value.
        var kinds = defaults.stringArray(forKey: Keys.backupKinds) ?? AppSettings.defaultBackupKinds
        if defaults.object(forKey: Keys.backupStates) != nil {
            if !defaults.bool(forKey: Keys.backupStates) {
                kinds = kinds.filter { $0 != "states" }
            }
            defaults.removeObject(forKey: Keys.backupStates)
        }
        backupKinds = kinds
        backupExcludedEmulators = defaults.stringArray(forKey: Keys.backupExcluded) ?? []
        autoInstallUpdates = defaults.bool(forKey: Keys.autoInstallUpdates)
        autoSignEmulators = defaults.bool(forKey: Keys.autoSignEmulators)
        if cardSize < 110 { cardSize = 168 }
        // A zero here would mean a timer firing as fast as it can. The upper
        // bound is a day: beyond that the timer is a pretence, since it only
        // ever runs while Biblijeu is open.
        if backupIntervalMinutes < 1 { backupIntervalMinutes = 30 }
        if backupIntervalMinutes > AppSettings.maxBackupInterval {
            backupIntervalMinutes = AppSettings.maxBackupInterval
        }
    }

    /// Minutes the interval is held between, wherever it is set or typed.
    static let backupIntervalRange = 1...1440
    static var maxBackupInterval: Int { backupIntervalRange.upperBound }

    /// The ROM folders as stored on disk, readable without the main actor: the
    /// command-line reports run before the app has one.
    nonisolated static var storedRomFolders: [String] {
        UserDefaults.standard.stringArray(forKey: Keys.romFolders) ?? []
    }

    /// The chosen kinds, readable without the main actor, for the same reason.
    nonisolated static var storedBackupKinds: [String] {
        UserDefaults.standard.stringArray(forKey: Keys.backupKinds) ?? defaultBackupKinds
    }

    var hasSteamGridDBKey: Bool {
        !steamGridDBKey.trimmingCharacters(in: .whitespaces).isEmpty
    }

    static let regions = ["Europe", "France", "États-Unis", "Japon", "Monde"]

    /// Everything a save can live in. The SD cards are deliberately absent.
    nonisolated static let defaultBackupKinds = ["saves", "states", "memoryCards", "systemMemory"]

    /// Application-support directory, created on demand.
    nonisolated static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Biblijeu", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }
}
