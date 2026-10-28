import AppKit
import Combine
import Foundation

/// What the backup folder on the external drive says about itself.
///
/// Written beside the copies rather than kept in Biblijeu's own preferences:
/// it describes *that* drive, so it stays true when the user keeps two of them,
/// and it is still there after a reinstall -- or on another Mac.
struct BackupManifest: Codable {
    var updated: Date
    /// The Mac these saves came from, so a folder found on a shared drive can
    /// be placed.
    var machine: String?
    var entries: [String: Entry]

    struct Entry: Codable {
        var emulator: String
        var kind: String
        /// Where this came from, to show on restore what it would go back to.
        var source: String
        var files: Int
        var bytes: Int64
        var date: Date
    }

    static let fileName = "Biblijeu.json"
}

/// Which way the files move.
enum BackupDirection: Sendable {
    /// The emulators' folders onto the backup drive. The only direction that
    /// ever runs by itself.
    case toBackup
    /// The backup drive back into the emulators' folders, asked for by hand.
    case toEmulator

    var label: String {
        switch self {
        case .toBackup:   return "Sauvegarder"
        case .toEmulator: return "Restaurer"
        }
    }
}

/// One emulator's save folders, as found on this Mac.
struct EmulatorSaves: Identifiable {
    let emulatorID: String
    let name: String
    /// False when the saves are here but the emulator is not -- uninstalled,
    /// or sitting on a drive that is not plugged in. Its saves are still worth
    /// backing up, and saying nothing about them would be the wrong answer.
    let isInstalled: Bool
    var folders: [FolderState]

    var id: String { emulatorID }
    var files: Int { folders.reduce(0) { $0 + $1.files } }
    var bytes: Int64 { folders.reduce(0) { $0 + $1.bytes } }
}

/// A save folder, what it holds, and what the backup holds of it.
struct FolderState: Identifiable {
    let folder: SaveFolder
    var files: Int
    var bytes: Int64
    /// What the backup drive says about this folder, when it is reachable.
    var backed: BackupManifest.Entry?

    var id: String { folder.id }
}

/// Finds where every emulator keeps its saves, copies them onto a drive of the
/// user's choosing, and puts them back when asked.
///
/// The automatic run only ever goes one way -- emulators to backup. Restoring
/// overwrites a save with an older one, which is the one mistake this whole
/// feature exists to prevent, so it is never done without being asked.
@MainActor
final class BackupManager: ObservableObject {
    static let shared = BackupManager()

    /// The folder Biblijeu owns inside whatever the user picked. Never the
    /// picked folder itself: pointing at the root of a drive must not scatter
    /// emulator folders across it.
    nonisolated static let folderName = "Biblijeu Sauvegardes"

    @Published private(set) var groups: [EmulatorSaves] = []
    @Published private(set) var isScanning = false
    @Published private(set) var isRunning = false
    @Published private(set) var progress = ""
    @Published private(set) var lastRun: Date?
    /// What the last run came to, in one readable line.
    @Published private(set) var lastSummary: String?
    @Published private(set) var lastFailures: [String] = []
    /// Set when the user asked for something that could not be done. Shown in
    /// the tab rather than as an alert: none of it is urgent.
    @Published var message: String?

    private let settings = AppSettings.shared
    private var cancellables = Set<AnyCancellable>()
    private var timerTask: Task<Void, Never>?
    /// The folder scan in flight, so two callers share one walk of the disc.
    private var scanTask: Task<Void, Never>?
    private var runTask: Task<Void, Never>?
    private var hasRunAtLaunch = false
    private var installed: [String: String] = [:]

    private enum Keys {
        static let lastRun = "backupLastRun"
    }

    private init() {
        lastRun = UserDefaults.standard.object(forKey: Keys.lastRun) as? Date

        // The timer follows the three settings that decide whether it should
        // exist at all. `@Published` hands the new value to the sink, so the
        // one that just changed is read from the argument and not from the
        // object, where it has not landed yet.
        // Coming back to Biblijeu is when something has just changed: an
        // emulator was run for the first time and has only now created its save
        // folder, a game wrote its first save beside the ROM, a drive was
        // plugged in. Re-reading then is what makes the tab keep up with a
        // library that changes without Biblijeu being told -- RPCS3 tried for
        // the first time appears by itself, rather than when somebody thinks to
        // press a button.
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .debounce(for: .seconds(1), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)

        settings.$autoBackup
            .combineLatest(settings.$backupOnInterval, settings.$backupIntervalMinutes,
                           settings.$backupDestination)
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .sink { [weak self] auto, onInterval, minutes, destination in
                self?.reschedule(auto: auto && onInterval, minutes: minutes,
                                 destination: destination)
            }
            .store(in: &cancellables)

        // A ROM folder added or dropped changes what there is to back up.
        settings.$romFolders
            .dropFirst()
            .debounce(for: .milliseconds(500), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)
    }

    // MARK: - Where the backup lives

    /// The folder the user picked, as they picked it.
    var destination: URL? {
        let path = settings.backupDestination
        return path.isEmpty ? nil : URL(fileURLWithPath: path)
    }

    /// Biblijeu's own folder inside it, where the copies actually go.
    var root: URL? {
        destination?.appendingPathComponent(Self.folderName, isDirectory: true)
    }

    /// False when the drive is asleep, unplugged or renamed -- the ordinary
    /// state of an external drive, and never treated as an error.
    var isDestinationAvailable: Bool {
        guard let destination else { return false }
        return FileManager.default.fileExists(atPath: destination.path)
    }

    func chooseDestination() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choisir"
        panel.message = "Choisissez où garder vos sauvegardes — un dossier de votre disque externe."
        if let destination { panel.directoryURL = destination }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        settings.backupDestination = url.path
        refresh()
    }

    func forgetDestination() {
        settings.backupDestination = ""
        settings.autoBackup = false
        refresh()
    }

    /// Where one save folder's copies sit on the drive, when they are really
    /// there. Nil rather than a path that would open an empty Finder window:
    /// a folder never backed up has nothing to show.
    func backupFolder(for folder: SaveFolder) -> URL? {
        exists(root?.appendingPathComponent(folder.backupSubpath, isDirectory: true))
    }

    /// The same for a whole emulator, which is one folder up.
    func backupFolder(forEmulator id: String) -> URL? {
        exists(root?.appendingPathComponent(id, isDirectory: true))
    }

    private func exists(_ url: URL?) -> URL? {
        guard isDestinationAvailable, let url,
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    // MARK: - Finding the folders

    /// Called whenever the library knows which emulators are installed.
    func update(installed emulators: [InstalledEmulator]) {
        installed = Dictionary(emulators.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        refresh()
    }

    /// Re-reads where the saves are and how big they have become.
    func refresh() {
        Task { await rescan() }
    }

    /// The same, waited on.
    ///
    /// A run must never start against a list that is still being built: the
    /// backup at launch happens the moment the emulators are known, which is
    /// also the moment the first scan is in flight, and reading the list then
    /// would find it empty and copy nothing at all. A caller arriving mid-scan
    /// waits for that one rather than skipping past it.
    func rescan() async {
        if let inFlight = scanTask {
            await inFlight.value
            return
        }
        let task = Task { await performScan() }
        scanTask = task
        await task.value
        scanTask = nil
    }

    private func performScan() async {
        isScanning = true
        defer { isScanning = false }

        // Every emulator the catalogue knows, not only the installed ones: an
        // emulator deleted last month left its saves behind, and they are
        // exactly what somebody would want on a drive before reinstalling.
        let ids = Set(SaveCatalog.knownEmulatorIDs)
        let names = installed
        let romFolders = settings.romFolders
        let backupRoot = isDestinationAvailable ? root : nil
        let manifestURL = backupRoot?.appendingPathComponent(BackupManifest.fileName)

        groups = await Task.detached(priority: .utility) {
            let manifest = manifestURL.flatMap(Self.readManifest)

            func measure(_ folders: [SaveFolder]) -> [FolderState] {
                folders.map { folder in
                    let measured = BackupEngine.measure(folder.url, filter: folder.filter)
                    return FolderState(folder: folder, files: measured.files, bytes: measured.bytes,
                                       backed: manifest?.entries[folder.backupSubpath])
                }
            }

            var groups: [EmulatorSaves] = []
            for id in ids.sorted() {
                var folders = SaveCatalog.folders(forEmulator: id)
                // What the drive holds and this Mac has never made, so it can
                // be restored -- the saves of a game not yet started here.
                if let backupRoot {
                    folders += SaveCatalog.folders(onlyInBackup: backupRoot, forEmulator: id,
                                                   present: Set(folders.map(\.backupSubpath)))
                }
                guard !folders.isEmpty else { continue }
                let standalone = SaveCatalog.standaloneNames[id]
                let name = names[id] ?? standalone ?? EmulatorCatalog.byID[id]?.name ?? id
                groups.append(EmulatorSaves(emulatorID: id, name: name,
                                            isInstalled: names[id] != nil || standalone != nil,
                                            folders: measure(folders)))
            }
            groups.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

            // The ROM folders come last, and outside the sort: they are not an
            // emulator, and a group of them landing in the middle of the list
            // alphabetically would read as one.
            let beside = SaveCatalog.folders(besideRomsIn: romFolders)
            if !beside.isEmpty {
                groups.append(EmulatorSaves(emulatorID: SaveCatalog.romsID,
                                            name: "À côté des ROM",
                                            isInstalled: true, folders: measure(beside)))
            }
            return groups
        }.value
    }

    // MARK: - What a run covers

    /// The folders a run would touch, after the user's choices.
    var selectedFolders: [SaveFolder] {
        let excluded = Set(settings.backupExcludedEmulators)
        let kinds = includedKinds
        return groups
            .filter { !excluded.contains($0.emulatorID) }
            .flatMap(\.folders)
            .map(\.folder)
            .filter { kinds.contains($0.kind) }
    }

    /// The kinds of folder the backup covers.
    var includedKinds: Set<SaveKind> {
        Set(settings.backupKinds.compactMap(SaveKind.init(rawValue:)))
    }

    func isIncluded(_ kind: SaveKind) -> Bool { includedKinds.contains(kind) }

    func setIncluded(_ included: Bool, for kind: SaveKind) {
        var kinds = includedKinds
        if included { kinds.insert(kind) } else { kinds.remove(kind) }
        // Stored in the order the user reads them, not in whatever order a set
        // happens to hold.
        settings.backupKinds = SaveKind.allCases.filter { kinds.contains($0) }.map(\.rawValue)
    }

    /// What one kind of folder amounts to across every emulator, so the choice
    /// can be made knowing what it costs.
    func total(for kind: SaveKind) -> (folders: Int, bytes: Int64) {
        let matching = groups.flatMap(\.folders).filter { $0.folder.kind == kind }
        return (matching.count, matching.reduce(0) { $0 + $1.bytes })
    }

    func isIncluded(_ emulatorID: String) -> Bool {
        !settings.backupExcludedEmulators.contains(emulatorID)
    }

    func setIncluded(_ included: Bool, for emulatorID: String) {
        var excluded = Set(settings.backupExcludedEmulators)
        if included { excluded.remove(emulatorID) } else { excluded.insert(emulatorID) }
        settings.backupExcludedEmulators = excluded.sorted()
    }

    var totalBytes: Int64 {
        let ids = Set(selectedFolders.map(\.id))
        return groups.flatMap(\.folders).filter { ids.contains($0.id) }.reduce(0) { $0 + $1.bytes }
    }

    // MARK: - Running

    /// Claims the single run slot.
    ///
    /// Nothing may be awaited between asking whether a run is under way and
    /// saying that one now is: a run waits for the folder scan before it copies
    /// anything, and two clicks either side of that wait would otherwise start
    /// two runs onto the same manifest.
    private func beginRun() -> Bool {
        guard !isRunning else { return false }
        isRunning = true
        lastFailures = []
        return true
    }

    /// Starts a run the user asked for. `emulatorID` limits it to one emulator.
    func run(_ direction: BackupDirection, emulatorID: String? = nil) {
        guard !isRunning else { return }
        guard destination != nil else {
            message = "Choisissez d'abord un dossier de sauvegarde."
            return
        }
        guard isDestinationAvailable else {
            message = "Le dossier de sauvegarde est introuvable — le disque est-il branché ?"
            return
        }
        guard beginRun() else { return }
        runTask = Task {
            defer {
                isRunning = false
                progress = ""
            }
            // Against a freshly read list: a folder the emulator created while
            // the tab was open would otherwise be missed.
            await rescan()
            var folders = selectedFolders
            if let emulatorID {
                // Asked for one emulator by name: its own exclusion no longer
                // applies, but leaving out the save states still does.
                let kinds = includedKinds
                folders = groups.first { $0.emulatorID == emulatorID }?.folders.map(\.folder)
                    .filter { kinds.contains($0.kind) } ?? []
            }
            guard !folders.isEmpty else {
                message = "Rien à copier : aucun dossier de sauvegarde retenu."
                return
            }
            await perform(direction, folders: folders)
        }
    }

    /// The automatic run: quiet about everything that is not worth waking
    /// somebody for.
    private func runAutomatically(reason: String) async {
        guard settings.autoBackup, !isRunning, destination != nil else { return }
        guard isDestinationAvailable else {
            lastSummary = "Ignorée (\(reason)) : disque absent."
            return
        }
        guard beginRun() else { return }
        defer {
            isRunning = false
            progress = ""
        }
        await rescan()
        let folders = selectedFolders
        guard !folders.isEmpty else { return }
        await perform(.toBackup, folders: folders, reason: reason)
    }

    private func perform(_ direction: BackupDirection, folders: [SaveFolder],
                         reason: String? = nil) async {
        guard let root else { return }
        var total = BackupEngine.Outcome()
        var manifest = Self.readManifest(root.appendingPathComponent(BackupManifest.fileName))
            ?? BackupManifest(updated: Date(), machine: Host.current().localizedName, entries: [:])
        var touched = 0
        // Whether the drive was written to at all. A run that finds every file
        // already up to date must leave the drive exactly as it was -- rewriting
        // the manifest each time would be one pointless write every half hour.
        var changed = false

        for folder in folders {
            if Task.isCancelled { break }
            let name = installed[folder.emulatorID] ?? SaveCatalog.standaloneNames[folder.emulatorID]
                ?? EmulatorCatalog.byID[folder.emulatorID]?.name ?? folder.emulatorID
            progress = "\(direction.label) — \(name), \(folder.title)…"

            let copy = await Task.detached(priority: .utility) {
                Self.copy(folder, direction: direction, root: root)
            }.value
            guard !copy.skipped else { continue }

            total = total + copy.outcome
            touched += 1
            if let entry = copy.entry,
               Self.isWorthRecording(entry, over: manifest.entries[folder.backupSubpath],
                                     copied: copy.outcome.copied) {
                manifest.entries[folder.backupSubpath] = entry
                changed = true
            }
        }

        if direction == .toBackup {
            let now = Date()
            if changed {
                manifest.updated = now
                manifest.machine = Host.current().localizedName
                Self.writeManifest(manifest, to: root.appendingPathComponent(BackupManifest.fileName))
            }
            // Recorded even when nothing moved: the question the interface asks
            // is when the saves were last checked against the drive, and the
            // answer is now. It lives in this Mac's preferences, not on the
            // drive, so saying so costs the drive nothing.
            lastRun = now
            UserDefaults.standard.set(now, forKey: Keys.lastRun)
        }

        lastFailures = total.failures
        lastSummary = summary(for: total, direction: direction, folders: touched, reason: reason)
        await rescan()
    }

    private func summary(for outcome: BackupEngine.Outcome, direction: BackupDirection,
                         folders: Int, reason: String?) -> String {
        let when = Date().formatted(date: .omitted, time: .shortened)
        if outcome.cancelled {
            return "\(when) — interrompue après \(outcome.copied) fichier(s)."
        }
        let bytes = BackupEngine.size(outcome.bytes)
        let what = direction == .toBackup ? "Sauvegardés" : "Restaurés"
        let why = reason.map { " (\($0))" } ?? ""
        var text: String
        if outcome.copied == 0 {
            text = "\(when)\(why) — rien à copier, les \(outcome.identical) fichiers étaient déjà à jour."
        } else {
            text = "\(when)\(why) — \(what) : \(outcome.copied) fichier(s), \(bytes), "
                + "sur \(folders) dossier(s)."
        }
        if !outcome.failures.isEmpty {
            text += " \(outcome.failures.count) échec(s)."
        }
        return text
    }

    func cancel() {
        runTask?.cancel()
    }

    // MARK: - Launch, timer and quit

    /// Called once the library has scanned: the launch backup waits until the
    /// emulators are known, or it would copy nothing.
    func runAtLaunchIfNeeded() {
        guard !hasRunAtLaunch, settings.autoBackup, settings.backupOnLaunch else { return }
        hasRunAtLaunch = true
        Task { await runAutomatically(reason: "au lancement") }
    }

    private func reschedule(auto: Bool, minutes: Int, destination: String) {
        timerTask?.cancel()
        timerTask = nil
        guard auto, !destination.isEmpty, minutes > 0 else { return }
        let interval = TimeInterval(minutes) * 60
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled else { return }
                await self?.runAutomatically(reason: "toutes les \(minutes) min")
            }
        }
    }

    /// True when quitting should wait for one last copy.
    var wantsBackupOnQuit: Bool {
        settings.autoBackup && settings.backupOnQuit && isDestinationAvailable
            && !selectedFolders.isEmpty
    }

    /// The last copy before the app goes away.
    ///
    /// Quitting must not be something the user can get stuck in: a drive that
    /// stops answering cancels the run and lets the app close. The saves are
    /// still on the Mac, and the next launch will copy them.
    func backupOnQuit(timeout: TimeInterval = 20, completion: @escaping @MainActor () -> Void) {
        // Whichever comes first lets the app go: the run finishing, or the
        // timeout. Cancelling is not enough on its own -- the folder scan runs
        // detached and does not stop when asked, so waiting for the run after
        // cancelling it could still keep the app open for minutes.
        var done = false
        let finish = {
            guard !done else { return }
            done = true
            completion()
        }
        Task {
            let work = Task { await runAutomatically(reason: "à la fermeture") }
            let watchdog = Task {
                try? await Task.sleep(for: .seconds(timeout))
                guard !Task.isCancelled else { return }
                work.cancel()
                self.cancel()
                finish()
            }
            await work.value
            watchdog.cancel()
            finish()
        }
    }

    // MARK: - One folder, copied

    /// What copying one folder came to.
    struct FolderCopy: Sendable {
        /// Nothing was there to copy: a restore asked of a folder that has
        /// never been backed up. Not a failure, and not worth counting.
        var skipped = false
        var outcome = BackupEngine.Outcome()
        /// What the manifest should now say about this folder.
        var entry: BackupManifest.Entry?
    }

    /// Copies one save folder, either way, and works out what the manifest
    /// should say afterwards.
    ///
    /// Deliberately free of both the actor and the interface: the tab drives it
    /// one folder at a time so it can say where it is, the command-line report
    /// drives it in a loop, and neither can end up copying differently from the
    /// other.
    nonisolated static func copy(_ folder: SaveFolder, direction: BackupDirection,
                                 root: URL) -> FolderCopy {
        let backup = root.appendingPathComponent(folder.backupSubpath, isDirectory: true)
        let source = direction == .toBackup ? folder.url : backup
        let target = direction == .toBackup ? backup : folder.url

        // Restoring from a folder that was never backed up would create an
        // empty one and report success; there is nothing to put back.
        if direction == .toEmulator, !FileManager.default.fileExists(atPath: backup.path) {
            return FolderCopy(skipped: true)
        }
        // A folder known only from the backup has nothing here to copy yet.
        if direction == .toBackup, folder.onlyInBackup {
            return FolderCopy(skipped: true)
        }

        let outcome = BackupEngine.copy(from: source, to: target, filter: folder.filter)

        // Only a copy that went onto the drive without failing is worth
        // recording: a half-copied folder must not be remembered as a backup.
        guard direction == .toBackup, outcome.failures.isEmpty, !outcome.cancelled else {
            return FolderCopy(outcome: outcome)
        }
        let measured = BackupEngine.measure(folder.url, filter: folder.filter)
        return FolderCopy(outcome: outcome,
                          entry: BackupManifest.Entry(emulator: folder.emulatorID,
                                                      kind: folder.kind.rawValue,
                                                      source: folder.url.path,
                                                      files: measured.files,
                                                      bytes: measured.bytes,
                                                      date: Date()))
    }

    // MARK: - The manifest

    /// True when the manifest has something new to say about a folder.
    ///
    /// A run where every file was already up to date leaves the drive untouched,
    /// and the entry it would write differs from the one already there only by
    /// its date. Writing that would mean the drive is woken for a few hundred
    /// bytes every half hour, for no news -- and would date a backup that never
    /// happened. The date kept is therefore the date of the last real copy.
    nonisolated static func isWorthRecording(_ entry: BackupManifest.Entry,
                                             over existing: BackupManifest.Entry?,
                                             copied: Int) -> Bool {
        guard let existing else { return true }
        if copied > 0 { return true }
        return existing.files != entry.files || existing.bytes != entry.bytes
            || existing.source != entry.source || existing.kind != entry.kind
            || existing.emulator != entry.emulator
    }

    nonisolated static func readManifest(_ url: URL) -> BackupManifest? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(BackupManifest.self, from: data)
    }

    nonisolated static func writeManifest(_ manifest: BackupManifest, to url: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(manifest) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
