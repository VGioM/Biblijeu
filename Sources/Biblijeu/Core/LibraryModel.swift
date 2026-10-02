import AppKit
import Combine
import Foundation

/// Where the sidebar can point.
enum LibrarySection: Hashable, Identifiable {
    case all
    case recent
    case favorites
    case roms
    case games
    case emulators
    case other
    case unplayable
    /// Not a shelf of games: the emulators, and what their projects have
    /// published since. Its own view replaces the grid.
    case updates
    /// Not a shelf of games either: where each emulator keeps its saves, and
    /// the drive they are copied onto.
    case backups
    case system(String)
    case source(String)

    var id: String {
        switch self {
        case .all: return "all"
        case .recent: return "recent"
        case .favorites: return "favorites"
        case .roms: return "roms"
        case .games: return "games"
        case .emulators: return "emulators"
        case .other: return "other"
        case .unplayable: return "unplayable"
        case .updates: return "updates"
        case .backups: return "backups"
        case .system(let s): return "system:\(s)"
        case .source(let p): return "source:\(p)"
        }
    }

    var title: String {
        switch self {
        case .all: return "Tout"
        case .recent: return "Joués récemment"
        case .favorites: return "Favoris"
        case .roms: return "ROM installées"
        case .games: return "Jeux installés"
        case .emulators: return "Émulateurs"
        case .other: return "Autres"
        case .unplayable: return "Sans émulateur"
        case .updates: return "Mises à jour"
        case .backups: return "Sauvegarde"
        case .system(let id): return SystemCatalog.system(id)?.name ?? id
        case .source(let path): return (path as NSString).lastPathComponent
        }
    }

    /// False for the sections that replace the grid with a view of their own.
    var showsGames: Bool {
        switch self {
        case .updates, .backups: return false
        default: return true
        }
    }

    var symbol: String {
        switch self {
        case .all: return "square.grid.2x2"
        case .recent: return "clock.arrow.circlepath"
        case .favorites: return "heart"
        case .roms: return "opticaldisc"
        case .games: return "app.badge"
        case .emulators: return "cpu"
        case .other: return "doc.text"
        case .unplayable: return "exclamationmark.triangle"
        case .updates: return "arrow.down.circle"
        case .backups: return "externaldrive.badge.timemachine"
        case .system(let id): return SystemCatalog.system(id)?.symbol ?? "gamecontroller"
        case .source: return "folder"
        }
    }
}

@MainActor
final class LibraryModel: ObservableObject {
    @Published private(set) var items: [GameItem] = []
    @Published private(set) var installedEmulators: [InstalledEmulator] = []
    /// The CrossOver bottles found on this Mac, and what their start menus hold.
    @Published private(set) var crossOverBottles: [CrossOverBottle] = []
    @Published private(set) var crossOverShortcuts: [CrossOverShortcut] = []

    @Published var selection: LibrarySection = .all
    @Published var searchText = ""
    @Published var sortOrder: GameSortOrder = .title
    @Published var selectedItemID: String?
    /// The info panel follows the selection: clicking a game opens it, clicking
    /// between games closes it. The toolbar button still forces it either way.
    @Published var showInspector = true

    @Published private(set) var isScanning = false
    @Published private(set) var scanProgress = ""
    @Published private(set) var isFetchingArtwork = false
    @Published private(set) var artworkProgress: Double = 0
    @Published var errorMessage: String?
    @Published var infoMessage: String?
    /// What each emulator's project answered when last asked about its
    /// newest build, keyed by emulator id.
    @Published private(set) var emulatorUpdates: [String: EmulatorUpdate] = [:]
    @Published private(set) var updatesCheckedAt: Date?
    /// Emulators whose answer is held over because their project did not answer
    /// the last time it was asked.
    @Published private(set) var staleUpdates: Set<String> = []
    @Published private(set) var isCheckingUpdates = false

    private let settings = AppSettings.shared
    private let play = PlayStore.shared
    private let watcher = FolderWatcher()
    private var cancellables = Set<AnyCancellable>()
    private var artworkTask: Task<Void, Never>?
    private var updateTask: Task<Void, Never>?
    private var hasScanned = false
    private var lastScan = Date.distantPast
    /// What the last scan found, before the user's corrections are applied.
    private var scannedItems: [GameItem] = []
    private var scannedEmulators: [InstalledEmulator] = []

    init() {
        // The grid reflects favourites, play dates and freshly found covers.
        play.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        settings.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        // A library kept on an external drive comes and goes with the drive.
        // Rescan when one is plugged in, and again when one is pulled out, so
        // the grid matches what is actually reachable without anyone asking.
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            center.publisher(for: name)
                .debounce(for: .seconds(2), scheduler: DispatchQueue.main)
                .sink { [weak self] _ in self?.rescan() }
                .store(in: &cancellables)
        }

        // Coming back to the app is the other moment worth checking: folder
        // watching stops at the edge of what FSEvents saw while we ran.
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in
                self?.rescanIfStale()
                // The emulator has just been quit: pick up the state it wrote
                // before the player asks to carry on.
                self?.harvestStates()
            }
            .store(in: &cancellables)
    }

    // MARK: - Sources

    var romFolders: [URL] { settings.romFolders.map { URL(fileURLWithPath: $0) } }
    var applicationFolders: [URL] { settings.applicationFolders.map { URL(fileURLWithPath: $0) } }
    var hasSources: Bool { !settings.romFolders.isEmpty || settings.scanApplications }

    func addRomFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Ajouter"
        panel.message = "Choisissez un dossier contenant vos ROM ou vos jeux."
        guard panel.runModal() == .OK else { return }
        var folders = settings.romFolders
        for url in panel.urls where !folders.contains(url.path) {
            folders.append(url.path)
        }
        settings.romFolders = folders
        rescan()
    }

    func removeRomFolder(_ path: String) {
        settings.romFolders.removeAll { $0 == path }
        if case .source(let current) = selection, current == path { selection = .all }
        rescan()
    }

    /// Where to look for emulators and installed games. Worth changing when the
    /// emulators live on the same external drive as the ROM.
    func addApplicationFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Ajouter"
        panel.message = "Choisissez un dossier contenant des applications ou des émulateurs."
        guard panel.runModal() == .OK else { return }
        var folders = settings.applicationFolders
        for url in panel.urls where !folders.contains(url.path) {
            folders.append(url.path)
        }
        settings.applicationFolders = folders
        rescan()
    }

    func removeApplicationFolder(_ path: String) {
        settings.applicationFolders.removeAll { $0 == path }
        rescan()
    }

    // MARK: - Scanning

    func rescanIfNeeded() {
        guard !hasScanned else { return }
        hasScanned = true
        rescan()
    }

    /// Used when the app comes forward: worth a look, but not on every switch.
    private func rescanIfStale(after interval: TimeInterval = 60) {
        guard hasScanned, Date().timeIntervalSince(lastScan) > interval else { return }
        rescan()
    }

    /// ROM folders that are configured but not reachable right now -- an
    /// external drive that is asleep, unplugged, or renamed.
    var unavailableFolders: [String] {
        settings.romFolders.filter { !FileManager.default.fileExists(atPath: $0) }
    }

    func rescan() {
        guard !isScanning else { return }
        isScanning = true
        scanProgress = "Analyse…"

        let romRoots = romFolders
        let appRoots = applicationFolders
        let scanApps = settings.scanApplications

        Task.detached(priority: .userInitiated) {
            ApplicationScanner.clearCache()

            let report: @Sendable (String) -> Void = { text in
                Task { @MainActor in self.scanProgress = text }
            }

            var scanned = RomScanner.scan(roots: romRoots, progress: report)

            // CrossOver knows more about a Windows game than the folder it sits
            // in does: which bottle it is installed in, and what its icon is.
            let bottles = CrossOver.bottles()
            if !bottles.isEmpty { report("Lecture des bouteilles CrossOver…") }
            let shortcuts = CrossOver.shortcuts(in: bottles)
            scanned = CrossOver.merge(shortcuts, into: scanned)

            if scanApps {
                scanned.append(contentsOf: ApplicationScanner.scan(folders: appRoots, progress: report))
            }
            let found = scanned
            let emulators = ApplicationScanner.installedEmulators(in: appRoots)

            await MainActor.run {
                self.crossOverBottles = bottles
                self.crossOverShortcuts = shortcuts
                self.apply(items: found, emulators: emulators)
            }
        }
    }

    private func apply(items found: [GameItem], emulators: [InstalledEmulator]) {
        // Games used to be identified by their full path. Anything recorded
        // under that identity is claimed here, once, while the files are still
        // where they were -- after which moving them changes nothing.
        play.adopt(legacy: found.map { ($0.id, GameItem.legacyIdentifier(for: $0.url)) })

        // Two folders can point at the same file; keep one of each.
        var seen = Set<String>()
        scannedItems = found.filter { seen.insert($0.id).inserted }
            .sorted { $0.sortTitle.localizedStandardCompare($1.sortTitle) == .orderedAscending }

        scannedEmulators = emulators
        refreshOverrides()
        isScanning = false
        scanProgress = ""
        lastScan = Date()
        startWatching()
        if settings.autoFetchArtwork { fetchArtwork() }
    }

    /// Re-applies the user's corrections on top of the scan. Cheap enough to
    /// run on every change, so nothing has to be rescanned to reclassify a tile.
    private func refreshOverrides() {
        items = scannedItems.map { item in
            var item = item
            let state = play.state(for: item.id)
            if let raw = state.kindOverride, let kind = GameKind(rawValue: raw) { item.kind = kind }
            if let system = state.systemOverride, SystemCatalog.system(system) != nil {
                item.systemID = system
            }
            return item
        }
        refreshEmulators()
    }

    /// Which emulators can actually be used to start a game right now: the ones
    /// found in the application folders, plus any app the user pointed at --
    /// one sitting in a ROM folder, or one the scanner failed to recognise and
    /// the user declared an emulator by hand.
    private func refreshEmulators() {
        // An app the user says is *not* an emulator stops being offered.
        let disowned = Set(items.filter { $0.kind != .emulator }
            .map(\.url.standardizedFileURL.path))

        var all: [InstalledEmulator] = []
        var knownIDs = Set<String>()
        var knownPaths = Set<String>()

        func add(_ emulator: InstalledEmulator, respectingDisowned: Bool = true) {
            let path = emulator.url.standardizedFileURL.path
            guard !emulator.spec.systems.isEmpty,
                  !(respectingDisowned && disowned.contains(path)),
                  knownPaths.insert(path).inserted,
                  knownIDs.insert(emulator.id).inserted else { return }
            all.append(emulator)
        }

        // Added by hand: the user's word beats every heuristic, and the app may
        // not even be somewhere the scan looks.
        for (path, systems) in settings.manualEmulators {
            let url = URL(fileURLWithPath: path)
            guard FileManager.default.fileExists(atPath: path) else { continue }
            let known = ApplicationScanner.emulator(at: url)
            let spec = known.map { systems.isEmpty ? $0.spec : $0.spec.withSystems(systems) }
                ?? EmulatorSpec(id: "manual:" + path,
                                name: url.deletingPathExtension().lastPathComponent,
                                bundleIDs: [], executableNames: [], systems: systems,
                                launch: .document, directLaunch: nil, homepage: nil)
            add(InstalledEmulator(spec: spec, url: url, version: known?.version),
                respectingDisowned: false)
        }

        for emulator in scannedEmulators { add(withChosenSystems(emulator)) }

        // An app in the library the user declared an emulator -- one sitting in
        // a ROM folder, or one the scanner filed as a game.
        for item in items where item.kind == .emulator && item.url.pathExtension.lowercased() == "app" {
            guard let emulator = userEmulator(for: item) else { continue }
            add(withChosenSystems(emulator))
        }

        installedEmulators = all.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }

        // Now that we know what is installed, find out whether any of it has
        // been superseded. Nothing happens when the last round is recent.
        checkForEmulatorUpdates()

        // And where each of them keeps its saves. The backup at launch waits
        // for this: before the emulators are known there is nothing to copy.
        BackupManager.shared.update(installed: installedEmulators)
        BackupManager.shared.runAtLaunchIfNeeded()
    }

    // MARK: - Emulator updates

    /// Asks each emulator's project about its newest build.
    ///
    /// Left alone this runs once a day: the answers are kept on disk, and the
    /// projects are asked again only when they have gone stale. `force` is the
    /// button in the settings, for when the user wants to know now.
    func checkForEmulatorUpdates(force: Bool = false) {
        if emulatorUpdates.isEmpty, let cached = UpdateChecker.cached() {
            // Weighed again against what is installed now: an emulator updated
            // by hand since that round must not stay flagged.
            emulatorUpdates = UpdateChecker.rejudged(cached.updates, for: installedEmulators)
            updatesCheckedAt = cached.checked
            staleUpdates = cached.stale ?? []
        }
        guard !isCheckingUpdates else { return }
        // Once per calendar day, on the first launch of the day -- unless the
        // last round left somebody unanswered, which is worth retrying sooner.
        guard force || UpdateChecker.isDue(since: updatesCheckedAt,
                                           everyoneAnswered: unreachableEmulators.isEmpty)
        else { return }

        let emulators = installedEmulators
        guard emulators.contains(where: { $0.spec.updates != nil }) else { return }

        isCheckingUpdates = true
        updateTask = Task { [weak self] in
            let remembered = await MainActor.run { self?.emulatorUpdates ?? [:] }
            let report = await UpdateChecker.check(emulators, keeping: remembered)
            let cancelled = Task.isCancelled
            if !cancelled { UpdateChecker.save(report) }
            await MainActor.run {
                guard let self else { return }
                // Lowered whatever happened: a round left raised would block
                // every later one, and the button with it.
                self.isCheckingUpdates = false
                guard !cancelled else { return }
                self.emulatorUpdates = report.updates
                self.updatesCheckedAt = report.checked
                self.staleUpdates = report.stale ?? []
            }
        }
    }

    /// Jump to the updates view -- used by the sidebar and by the settings.
    func showUpdates() { selection = .updates }

    /// The emulators with something newer published, named for a summary.
    var outdatedEmulators: [InstalledEmulator] {
        installedEmulators.filter { emulatorUpdates[$0.id]?.verdict == .available }
    }

    /// Emulators whose project has a source but did not answer -- offline, moved,
    /// or GitHub's hourly allowance spent. Worth naming: silence from all of them
    /// otherwise reads as "everything is up to date".
    var unreachableEmulators: [InstalledEmulator] {
        installedEmulators.filter {
            guard $0.spec.updates != nil else { return false }
            return emulatorUpdates[$0.id] == nil || staleUpdates.contains($0.id)
        }
    }

    /// Applies the console list the user set on this app, when they set one.
    private func withChosenSystems(_ emulator: InstalledEmulator) -> InstalledEmulator {
        guard let item = items.first(where: {
                  $0.url.standardizedFileURL == emulator.url.standardizedFileURL }),
              let chosen = play.state(for: item.id).emulatorSystems,
              !chosen.isEmpty, Set(chosen) != Set(emulator.spec.systems)
        else { return emulator }
        return InstalledEmulator(spec: emulator.spec.withSystems(chosen),
                                 url: emulator.url, version: emulator.version)
    }

    // MARK: - Emulators added by hand

    /// For the emulator nothing recognises: point at the app, then say what it
    /// runs. It then behaves like any other emulator, including in the
    /// "Émulateur par console" preference.
    func addManualEmulator() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Ajouter"
        panel.message = "Choisissez l'application de l'émulateur."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let detected = ApplicationScanner.emulator(at: url)?.spec.systems ?? []
        settings.manualEmulators[url.standardizedFileURL.path] = detected
        refreshEmulators()
        if detected.isEmpty {
            infoMessage = "\(url.deletingPathExtension().lastPathComponent) est ajouté. "
                + "Indiquez maintenant les consoles qu'il fait tourner, sinon aucun jeu ne lui sera proposé."
        }
    }

    func removeManualEmulator(_ path: String) {
        settings.manualEmulators[path] = nil
        refreshEmulators()
    }

    func setManualEmulatorSystems(_ systems: [String], for path: String) {
        settings.manualEmulators[path] = systems
        refreshEmulators()
    }

    /// The emulator an app declared by the user amounts to. A recognised app
    /// keeps its command line; an unknown one is handed the ROM as a document,
    /// which is the only way to start a game without knowing its options.
    private func userEmulator(for item: GameItem) -> InstalledEmulator? {
        if let known = ApplicationScanner.emulator(at: item.url) { return known }
        let systems = play.state(for: item.id).emulatorSystems ?? []
        guard !systems.isEmpty else { return nil }
        let spec = EmulatorSpec(id: "user:" + item.id, name: item.title,
                                bundleIDs: [item.bundleID].compactMap { $0 },
                                executableNames: [], systems: systems,
                                launch: .document, directLaunch: nil, homepage: nil)
        return InstalledEmulator(spec: spec, url: item.url, version: item.appVersion)
    }

    /// The consoles this app is offered for. Empty for an unrecognised app that
    /// the user has not described yet -- it can be declared an emulator, but it
    /// cannot run anything until it is told what it runs.
    func emulatorSystems(for item: GameItem) -> [String] {
        if let chosen = play.state(for: item.id).emulatorSystems, !chosen.isEmpty { return chosen }
        return ApplicationScanner.emulator(at: item.url)?.spec.systems ?? []
    }

    func setEmulatorSystems(_ systems: [String], for item: GameItem) {
        play.setEmulatorSystems(systems, for: item.id)
        refreshEmulators()
    }

    /// True when nothing but the user can say what this app runs.
    func isUnknownEmulator(_ item: GameItem) -> Bool {
        item.kind == .emulator && ApplicationScanner.emulator(at: item.url) == nil
    }

    // MARK: - Corrections

    /// "This is not a game, it is an emulator" -- and the four other ways the
    /// scanner can be wrong. nil restores what the scan decided.
    func setKind(_ kind: GameKind?, for item: GameItem) {
        play.setKind(kind, for: item.id)
        refreshOverrides()
    }

    func setSystem(_ systemID: String?, for item: GameItem) {
        play.setSystem(systemID, for: item.id)
        refreshOverrides()
    }

    /// What the scan itself concluded, to show the automatic choice next to the
    /// correction.
    func scannedKind(for item: GameItem) -> GameKind {
        scannedItems.first { $0.id == item.id }?.kind ?? item.kind
    }

    func scannedSystemID(for item: GameItem) -> String {
        scannedItems.first { $0.id == item.id }?.systemID ?? item.systemID
    }

    private func startWatching() {
        guard settings.watchFolders else { watcher.stop(); return }
        // A game installed into a bottle after launch should show up the same
        // way a ROM copied into a folder does.
        let paths = settings.romFolders.filter { FileManager.default.fileExists(atPath: $0) }
            + CrossOver.watchPaths(for: crossOverBottles)
        watcher.start(paths: paths) { [weak self] in
            Task { @MainActor in self?.rescan() }
        }
    }

    // MARK: - Artwork

    /// `force` is the menu command: it retries the games whose lookup already
    /// came back empty, and always says what it did. The automatic pass after a
    /// scan leaves those alone and stays silent.
    func fetchArtwork(force: Bool = false) {
        guard !isFetchingArtwork else {
            if force { infoMessage = "Une recherche de jaquettes est déjà en cours." }
            return
        }
        let pending = items.filter(force ? ArtworkService.hasNoCover : ArtworkService.needsLookup)
        guard !pending.isEmpty else {
            if force { infoMessage = "Aucune jaquette manquante : tous les jeux en ont une." }
            return
        }

        isFetchingArtwork = true
        artworkProgress = 0
        artworkTask?.cancel()
        let total = pending.count
        artworkTask = Task { [weak self] in
            let found = await ArtworkService.fetchCovers(for: pending) { progress in
                Task { @MainActor in self?.artworkProgress = progress }
            }
            await MainActor.run {
                guard let self else { return }
                self.isFetchingArtwork = false
                self.artworkProgress = 0
                if force { self.infoMessage = Self.artworkSummary(found: found, of: total) }
            }
        }
    }

    private static func artworkSummary(found: Int, of total: Int) -> String {
        guard found > 0 else {
            return "Aucune jaquette trouvée pour \(total) jeu\(total > 1 ? "x" : ""). "
                + "Corrigez le titre de recherche dans le panneau d'informations, "
                + "ou choisissez une image à la main."
        }
        if found == total {
            return "\(found) jaquette\(found > 1 ? "s" : "") trouvée\(found > 1 ? "s" : "")."
        }
        return "\(found) jaquette\(found > 1 ? "s" : "") trouvée\(found > 1 ? "s" : "") sur \(total). "
            + "Les autres sont introuvables dans l'archive libretro et sur SteamGridDB."
    }

    func refetchArtwork(for item: GameItem, title: String? = nil) {
        Task {
            let found = await ArtworkService.refetch(item, searchTitle: title)
            if !found {
                infoMessage = "Aucune jaquette trouvée pour « \(title ?? item.title) »."
            }
        }
    }

    /// The covers offered by the "Corriger" sheet.
    func artworkCandidates(for item: GameItem, title: String?) async -> [ArtworkCandidate] {
        let trimmed = title?.trimmingCharacters(in: .whitespaces)
        return await ArtworkService.candidates(for: item,
                                               searchTitle: (trimmed?.isEmpty == false) ? trimmed : nil)
    }

    /// The user pointed at the right cover: keep it, and remember the title they
    /// searched with so the next automatic pass agrees.
    func applyArtwork(_ candidate: ArtworkCandidate, to item: GameItem, searchTitle: String?) {
        let trimmed = searchTitle?.trimmingCharacters(in: .whitespaces)
        if let trimmed, !trimmed.isEmpty, trimmed != item.title {
            play.update(item.id) { $0.searchTitle = trimmed }
        }
        play.setCustomArtwork(nil, for: item.id)
        play.setArtwork(candidate.imageURL, for: item.id)
    }

    func chooseArtwork(for item: GameItem) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image]
        panel.prompt = "Utiliser"
        panel.message = "Choisissez une image pour \(item.title)."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        play.setCustomArtwork(url.path, for: item.id)
    }

    // MARK: - Emulators

    /// The emulator Biblijeu would use for this game right now.
    func emulator(for item: GameItem) -> InstalledEmulator? {
        guard item.kind == .rom else { return nil }
        if let override = play.state(for: item.id).emulatorID,
           let match = installedEmulators.first(where: { $0.id == override }) { return match }
        guard let system = item.system else { return nil }
        if let preferred = settings.emulatorForSystem[system.id],
           let match = installedEmulators.first(where: { $0.id == preferred }) { return match }
        for id in system.emulators {
            if let match = installedEmulators.first(where: { $0.id == id }) { return match }
        }
        return installedEmulators.first { $0.spec.systems.contains(system.id) }
    }

    /// Every installed emulator that can run this system.
    func emulators(for systemID: String) -> [InstalledEmulator] {
        installedEmulators.filter { $0.spec.systems.contains(systemID) }
    }

    /// Games whose cover can only come from SteamGridDB.
    var itemsNeedingExternalArtwork: Int {
        items.filter { item in
            guard !play.isHidden(item.id) else { return false }
            let state = play.state(for: item.id)
            guard state.customArtworkPath == nil, state.artworkURL == nil else { return false }
            guard item.kind == .rom else { return false }
            return item.system?.libretroFolder == nil || state.artworkMissing
        }.count
    }

    var systemsWithGames: [GameSystem] {
        let ids = Set(items.filter { $0.kind.belongsToSystem }.map(\.systemID))
        return SystemCatalog.all.filter { ids.contains($0.id) }
            .sorted { ($0.manufacturer, $0.year) < ($1.manufacturer, $1.year) }
    }

    // MARK: - Launching

    /// Can "Reprendre" actually do something for this game right now?
    ///
    /// Not the same question as "does the emulator have save states": Dolphin
    /// and PPSSPP only take a state *path*, so without one there is nothing to
    /// resume from and the game simply starts.
    func canResume(_ item: GameItem) -> Bool {
        if case .fromStart = resumeRequest(for: item) { return false }
        return true
    }

    /// What "Reprendre" means for this game: the state file the user picked,
    /// the slot they chose, or whatever the emulator considers most recent.
    func resumeRequest(for item: GameItem) -> ResumeRequest {
        guard let spec = emulator(for: item)?.spec else { return .fromStart }
        let state = self.play.state(for: item.id)

        var wanted: [ResumeRequest] = []
        if let path = state.stateFilePath, !path.isEmpty {
            wanted.append(.file(URL(fileURLWithPath: path)))
        }
        if let slot = state.resumeSlot { wanted.append(.slot(slot)) }
        // The state the emulator actually wrote beats asking it for "this
        // game's" state: states are filed under the serial of the disc that was
        // in the drive, which for a multi-disc game is not the disc Biblijeu
        // would boot -- disc 2's progress would be invisible.
        if let path = autoStateFile(for: item) { wanted.append(.file(URL(fileURLWithPath: path))) }
        wanted.append(.auto)

        // Anything the emulator cannot be told on the command line means
        // starting the game, not refusing to launch it.
        return wanted.first { spec.resumeArguments(for: $0) != nil } ?? .fromStart
    }

    /// The state Biblijeu spotted in the emulator's own folder, when it is
    /// still there and this emulator can be pointed at a file.
    func autoStateFile(for item: GameItem) -> String? {
        guard let path = play.state(for: item.id).autoStateFile, !path.isEmpty,
              emulator(for: item)?.spec.resume.file != nil,
              FileManager.default.fileExists(atPath: path) else { return nil }
        return path
    }

    /// Notices the state the emulator wrote for this game, on whichever disc.
    func harvestState(for item: GameItem) {
        guard let spec = emulator(for: item)?.spec,
              let found = StateHarvest.newestState(for: spec, naming: discFiles(of: item)) else { return }
        play.setAutoState(found.url.path, disc: found.disc.path, at: found.modified, for: item.id)
    }

    /// Every file this game may be sitting on: each of its discs, and the file
    /// the scanner picked when it is not a multi-disc set.
    private func discFiles(of item: GameItem) -> [URL] {
        item.discs.isEmpty ? [item.url] : item.discs
    }

    /// The emulator has just been quit: pick up what it wrote before the player
    /// asks to carry on. Only the game that was launched last can have changed.
    func harvestStates() {
        guard let item = lastLaunchedItem else { return }
        harvestState(for: item)
    }

    /// The game whose session may still be running, or has just ended.
    private var lastLaunchedItem: GameItem? {
        items.compactMap { item -> (GameItem, Date)? in
            play.lastPlayed(item.id).map { (item, $0) }
        }
        .max { $0.1 < $1.1 }?.0
    }

    /// The button in the toolbar and on each tile.
    func play(_ item: GameItem, disc: URL? = nil) {
        harvestState(for: item)
        let request = settings.resumeOnLaunch && canResume(item)
            ? resumeRequest(for: item) : ResumeRequest.fromStart
        // Resuming a state means booting the disc that state was taken on, not
        // the first one -- and at the path that disc has now, so the library
        // can move to another drive without the state pointing into thin air.
        play(item, disc: disc ?? stateDisc(for: item, resuming: request), resume: request)
    }

    /// The disc behind the state Biblijeu spotted, when that is what we are
    /// about to resume from.
    private func stateDisc(for item: GameItem, resuming request: ResumeRequest) -> URL? {
        guard case .file(let state) = request, state.path == autoStateFile(for: item),
              let disc = play.state(for: item.id).autoStateDisc,
              FileManager.default.fileExists(atPath: disc) else { return nil }
        return URL(fileURLWithPath: disc)
    }

    func play(_ item: GameItem, disc: URL? = nil, resume: ResumeRequest) {
        launch(item, using: emulator(for: item), disc: disc, resume: resume)
    }


    func play(_ item: GameItem, with emulator: InstalledEmulator) {
        launch(item, using: emulator, disc: nil, resume: .fromStart)
    }

    private func launch(_ item: GameItem, using emulator: InstalledEmulator?,
                        disc: URL?, resume: ResumeRequest) {
        if let emulator, emulator.spec.id == "crossover", item.kind == .rom {
            launchInBottle(item, using: emulator, disc: disc)
            return
        }
        Launcher.launch(item, using: emulator, direct: settings.directLaunch,
                        disc: disc, resume: resume) { [weak self] error in
            self?.finish(item, error: error)
        }
    }

    /// Windows games go through CrossOver's command line rather than through
    /// "open with": handed an `.exe` as a document, CrossOver asks which bottle
    /// to install it into, when the game is already installed in one.
    private func launchInBottle(_ item: GameItem, using emulator: InstalledEmulator, disc: URL?) {
        let executable = Launcher.playableURL(for: item, disc: disc)
        guard FileManager.default.fileExists(atPath: executable.path) else {
            finish(item, error: Launcher.LaunchError.missingFile(executable)); return
        }

        guard let plan = crossOverPlan(for: item) else {
            // No bottle at all: CrossOver's own window is where one is made,
            // so let it open and say so itself.
            guard !crossOverBottles.isEmpty else {
                Launcher.launch(item, using: emulator, direct: settings.directLaunch,
                                disc: disc) { [weak self] error in
                    self?.finish(item, error: error)
                }
                return
            }
            finish(item, error: CrossOver.Failure.ambiguousBottle(
                item.title, crossOverBottles.map(\.name)))
            return
        }

        // The start-menu entry knows the game's own launcher and working
        // directory; falling back to the scanned executable is second best.
        if let shortcut = plan.shortcut {
            CrossOver.launch(shortcut) { [weak self] error in self?.finish(item, error: error) }
        } else {
            CrossOver.run(executable, in: plan.bottle, name: item.title) { [weak self] error in
                self?.finish(item, error: error)
            }
        }
    }

    private func finish(_ item: GameItem, error: Error?) {
        if let error {
            errorMessage = (error as? LocalizedError).map {
                [$0.errorDescription, $0.recoverySuggestion].compactMap { $0 }.joined(separator: "\n\n")
            } ?? error.localizedDescription
        } else {
            play.recordPlay(item.id)
        }
    }

    // MARK: - CrossOver

    /// Where a Windows game should run, and the start-menu entry to use for it.
    ///
    /// The bottle the user named wins; failing that, the entry CrossOver made
    /// when the game was installed says where it belongs, then the bottle whose
    /// own disk holds the executable, and finally the only bottle there is.
    func crossOverPlan(for item: GameItem) -> (bottle: CrossOverBottle, shortcut: CrossOverShortcut?)? {
        guard !crossOverBottles.isEmpty else { return nil }
        let shortcut = crossOverShortcut(for: item)

        if let chosen = play.state(for: item.id).crossOverBottle,
           let bottle = crossOverBottles.first(where: { $0.name == chosen }) {
            return (bottle, shortcut?.bottle == bottle ? shortcut : nil)
        }
        if let shortcut { return (shortcut.bottle, shortcut) }
        if let bottle = crossOverBottles.first(where: {
            item.url.standardizedFileURL.path.hasPrefix($0.url.appendingPathComponent("drive_c").path + "/")
        }) { return (bottle, nil) }
        return crossOverBottles.count == 1 ? (crossOverBottles[0], nil) : nil
    }

    /// The start-menu entry that starts this game, if CrossOver made one: the
    /// entry whose program lives in the game's own folder.
    func crossOverShortcut(for item: GameItem) -> CrossOverShortcut? {
        if let match = crossOverShortcuts.first(where: { $0.launchURL == item.url }) { return match }
        let folder = item.url.deletingLastPathComponent().standardizedFileURL.path + "/"
        let matches = crossOverShortcuts.filter {
            $0.target?.standardizedFileURL.path.hasPrefix(folder) == true
        }
        return matches.first { !$0.name.lowercased().contains("updat") } ?? matches.first
    }

    /// The command line "Copier la commande de lancement" hands over, and the
    /// one the info panel shows.
    func commandPreview(for item: GameItem) -> String? {
        let emulator = emulator(for: item)
        if let emulator, emulator.spec.id == "crossover", item.kind == .rom,
           let plan = crossOverPlan(for: item) {
            if let shortcut = plan.shortcut { return CrossOver.commandPreview(for: shortcut) }
            return CrossOver.commandPreview(for: Launcher.playableURL(for: item), in: plan.bottle)
        }
        let request = settings.resumeOnLaunch && canResume(item)
            ? resumeRequest(for: item) : ResumeRequest.fromStart
        return Launcher.commandPreview(
            for: item, emulator: emulator, direct: settings.directLaunch,
            disc: stateDisc(for: item, resuming: request), resume: request)
    }

    /// Lets the user point at a save state produced by Dolphin or PPSSPP,
    /// which can only resume from an explicit path.
    func chooseStateFile(for item: GameItem) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.prompt = "Utiliser"
        panel.message = "Choisissez le fichier de sauvegarde d'état de \(item.title)."
        if let directory = stateDirectory(for: item) {
            panel.directoryURL = directory
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        self.play.setStateFile(url.path, for: item.id)
    }

    /// Where the emulator keeps its states, so the open panel starts there.
    func stateDirectory(for item: GameItem) -> URL? {
        guard let emulator = emulator(for: item) else { return nil }
        return StateHarvest.directory(for: emulator.spec)
    }

    func reveal(_ item: GameItem) { Launcher.reveal(item.url) }

    func copyPath(_ item: GameItem) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(item.url.path, forType: .string)
    }

    func copyCommand(_ item: GameItem) {
        guard let command = commandPreview(for: item) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
        infoMessage = "Commande copiée."
    }

    // MARK: - Selection

    /// Clicking a tile. Reopens the panel even when the same game is clicked
    /// again after the panel was closed by hand.
    func select(_ item: GameItem) {
        selectedItemID = item.id
        showInspector = true
    }

    /// Clicking beside the tiles.
    func clearSelection() {
        selectedItemID = nil
    }

    // MARK: - Filtering

    var selectedItem: GameItem? {
        guard let id = selectedItemID else { return nil }
        return items.first { $0.id == id }
    }

    var visibleItems: [GameItem] {
        var result = items.filter { !play.isHidden($0.id) }

        switch selection {
        case .all:
            break
        case .recent:
            result = result.filter { play.lastPlayed($0.id) != nil }
        case .favorites:
            result = result.filter { play.isFavorite($0.id) }
        case .roms:
            result = result.filter { $0.kind == .rom }
        case .games:
            result = result.filter { $0.kind == .game }
        case .emulators:
            result = result.filter { $0.kind == .emulator }
        case .other:
            result = result.filter { $0.kind == .other }
        case .unplayable:
            result = result.filter { $0.kind == .rom && emulator(for: $0) == nil }
        case .updates, .backups:
            // Nothing here is a game; these sections show their own view.
            result = []
        case .system(let id):
            result = result.filter { $0.systemID == id && $0.kind.belongsToSystem }
        case .source(let path):
            result = result.filter { $0.sourceRoot?.path.hasPrefix(path) == true }
        }

        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        if !query.isEmpty {
            let words = query.split(separator: " ").map(String.init)
            result = result.filter { item in
                let haystack = item.searchHaystack
                return words.allSatisfy { haystack.contains($0) }
            }
        }

        return sorted(result)
    }

    private func sorted(_ list: [GameItem]) -> [GameItem] {
        switch sortOrder {
        case .title:
            return list.sorted { $0.sortTitle.localizedStandardCompare($1.sortTitle) == .orderedAscending }
        case .recentlyPlayed:
            return list.sorted {
                (play.lastPlayed($0.id) ?? .distantPast) > (play.lastPlayed($1.id) ?? .distantPast)
            }
        case .recentlyAdded:
            return list.sorted { $0.dateAdded > $1.dateAdded }
        case .system:
            return list.sorted {
                let l = SystemCatalog.system($0.systemID)
                let r = SystemCatalog.system($1.systemID)
                if l?.id != r?.id { return (l?.sortKey ?? "") < (r?.sortKey ?? "") }
                return $0.sortTitle.localizedStandardCompare($1.sortTitle) == .orderedAscending
            }
        case .size:
            return list.sorted { $0.fileSize > $1.fileSize }
        }
    }

    var counts: [LibrarySection: Int] {
        var result: [LibrarySection: Int] = [:]
        let visible = items.filter { !play.isHidden($0.id) }
        result[.all] = visible.count
        result[.recent] = visible.filter { play.lastPlayed($0.id) != nil }.count
        result[.favorites] = visible.filter { play.isFavorite($0.id) }.count
        result[.roms] = visible.filter { $0.kind == .rom }.count
        result[.games] = visible.filter { $0.kind == .game }.count
        result[.emulators] = visible.filter { $0.kind == .emulator }.count
        result[.other] = visible.filter { $0.kind == .other }.count
        result[.unplayable] = visible.filter { $0.kind == .rom && emulator(for: $0) == nil }.count
        for system in systemsWithGames {
            result[.system(system.id)] = visible.filter { $0.systemID == system.id && $0.kind.belongsToSystem }.count
        }
        for path in settings.romFolders {
            result[.source(path)] = visible.filter { $0.sourceRoot?.path.hasPrefix(path) == true }.count
        }
        return result
    }
}
