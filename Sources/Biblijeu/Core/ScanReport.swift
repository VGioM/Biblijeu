import Foundation

/// `Biblijeu --scan [dossier…]` prints what the scanner sees and exits.
/// Handy when a ROM does not show up and you want to know why.
enum ScanReport {
    static func runIfRequested() {
        let args = CommandLine.arguments
        if args.contains("--updates") { runUpdateReport() }
        if args.contains("--install") { runInstall() }
        if args.contains("--sign") { runSign() }
        if args.contains("--saves") { runSaveReport() }
        guard args.contains("--scan") else { return }

        let folders = args.dropFirst().filter { !$0.hasPrefix("--") }
        let roots = folders.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
        let appFolders = ["/Applications",
                          FileManager.default.homeDirectoryForCurrentUser
                              .appendingPathComponent("Applications").path]
            .map { URL(fileURLWithPath: $0) }

        let emulators = ApplicationScanner.installedEmulators(in: appFolders)
        print("Émulateurs détectés (\(emulators.count)) :")
        for emulator in emulators {
            let systems = emulator.spec.systems.compactMap { SystemCatalog.system($0)?.shortName }
            print("  • \(emulator.name.padding(toLength: 22, withPad: " ", startingAt: 0)) \(systems.prefix(8).joined(separator: ", "))")
        }

        guard !roots.isEmpty else {
            print("\nAucun dossier fourni. Exemple : Biblijeu --scan ~/Documents/RetroArch/downloads/ROM")
            exit(0)
        }

        let items = RomScanner.scan(roots: roots, excluded: AppSettings.storedExcludedFolders) { _ in }
        print("\nJeux trouvés (\(items.count)) :")
        let bySystem = Dictionary(grouping: items, by: \.systemID)
        for systemID in bySystem.keys.sorted() {
            let system = SystemCatalog.system(systemID)
            print("\n  \(system?.name ?? systemID)")
            for item in bySystem[systemID]!.sorted(by: { $0.sortTitle < $1.sortTitle }) {
                let emulator = preferredEmulator(for: systemID, among: emulators)
                let discs = item.isMultiDisc ? " [\(item.discs.count) disques]" : ""
                let size = item.fileSize > 0
                    ? " — " + GameItem.sizeFormatter.string(fromByteCount: item.fileSize) : ""
                print("    \(item.title)\(discs)\(size)")
                print("      \(item.url.lastPathComponent)")
                let command = Launcher.commandPreview(for: item, emulator: emulator, direct: true)
                print("      → \(command ?? "aucun émulateur installé")")
                if let emulator, emulator.spec.resume.isSupported {
                    // The same choice the app makes: the state the emulator
                    // actually wrote for this game, on whichever disc, before
                    // falling back to "resume whatever you think is this game".
                    let found = StateHarvest.newestState(for: emulator.spec,
                                                         naming: item.discs.isEmpty ? [item.url] : item.discs)
                    let request: ResumeRequest = found.map { .file($0.url) } ?? .auto
                    // The disc the state was taken on, which is the one the
                    // app would actually boot.
                    let boot = found.map(\.disc)
                    // An emulator that only takes a state *path* has nothing to
                    // resume from until one is known: it would print the plain
                    // command again, which reads as a resume that is not one.
                    if emulator.spec.resumeArguments(for: request)?.isEmpty == false,
                       let resumed = Launcher.commandPreview(for: item, emulator: emulator,
                                                             direct: true, disc: boot, resume: request) {
                        print("      ↻ \(resumed)")
                    }
                    if let found {
                        print("        état : \(found.url.lastPathComponent) — \(dateFormatter.string(from: found.modified))")
                    }
                }
            }
        }
        if args.contains("--covers") {
            print("\nJaquettes :")
            let semaphore = DispatchSemaphore(value: 0)
            let sorted = items.sorted { $0.sortTitle < $1.sortTitle }
            Task.detached {
                for item in sorted {
                    let url = await ArtworkService.lookup(item, searchTitle: nil,
                                                          region: "Europe", apiKey: "")
                    print("  \(item.title)")
                    print("    \(url ?? "— aucune —")")
                }
                semaphore.signal()
            }
            semaphore.wait()
        }

        exit(0)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()

    /// Same order of preference the app uses when it launches a game.
    private static func preferredEmulator(for systemID: String,
                                          among installed: [InstalledEmulator]) -> InstalledEmulator? {
        guard let system = SystemCatalog.system(systemID) else { return nil }
        for id in system.emulators {
            if let match = installed.first(where: { $0.id == id }) { return match }
        }
        return installed.first { $0.spec.systems.contains(systemID) }
    }
}

// MARK: - Update report

/// `Biblijeu --updates` asks every installed emulator's project what it has
/// published, and prints the answer next to what is on disk. The same questions
/// the settings ask, with the reasoning visible.
extension ScanReport {
    static func runUpdateReport() {
        let appFolders = ["/Applications",
                          FileManager.default.homeDirectoryForCurrentUser
                              .appendingPathComponent("Applications").path]
            .map { URL(fileURLWithPath: $0) }
        let emulators = ApplicationScanner.installedEmulators(in: appFolders)

        // The same question the app asks, so the answers belong in the same
        // place: a round run from the command line is not a throwaway.
        let previous = UpdateChecker.cached()?.updates ?? [:]
        let report = runBlocking { await UpdateChecker.check(emulators, keeping: previous) }
        UpdateChecker.save(report)

        print("Mises à jour des émulateurs (\(report.updates.count) projets interrogés) :\n")
        for emulator in emulators.sorted(by: { $0.name < $1.name }) {
            let name = emulator.name.padding(toLength: 22, withPad: " ", startingAt: 0)
            let installed = (emulator.version ?? "—").padding(toLength: 24, withPad: " ", startingAt: 0)
            guard let update = report.updates[emulator.id] else {
                let why = emulator.spec.updates == nil ? "aucune source connue" : "projet injoignable"
                print("  • \(name) \(installed) \(why)")
                continue
            }
            let verdict: String
            let byDate = update.byDate == true ? " (par date)" : ""
            switch update.verdict {
            case .upToDate:  verdict = "à jour" + byDate
            case .available: verdict = "▲ \(update.latest) disponible" + byDate
            case .unsure:
                // Either side may be numbered in a way the other cannot be
                // lined up against; the publication date is what remains.
                let when = update.published.map { " le " + dateFormatter.string(from: $0) } ?? ""
                verdict = "non comparable — dernière build publiée\(when) : \(update.latest)"
            }
            print("  • \(name) \(installed) \(verdict)")
            let file = update.download.flatMap { URL(string: $0)?.lastPathComponent }
            print("    \(String(repeating: " ", count: 46))fichier : \(file ?? "aucun fichier macOS reconnu")")
        }
        exit(0)
    }

    /// `Biblijeu --sign <app>…` does what the automatic signing does, and says
    /// what it did.
    static func runSign() {
        let apps = CommandLine.arguments.drop { $0 != "--sign" }.dropFirst()
            .filter { !$0.hasPrefix("--") }
        var failed = false
        for path in apps {
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            do {
                switch try AppSigner.repair(url) {
                case .untouched:     print("  • \(url.lastPathComponent) : signature valide, rien à faire")
                case .unquarantined: print("  • \(url.lastPathComponent) : signature valide, quarantaine levée")
                case .resigned:      print("  • \(url.lastPathComponent) : signé à nouveau localement")
                }
            } catch {
                failed = true
                print("  ✗ \(url.lastPathComponent) : \(error.localizedDescription)")
            }
        }
        exit(failed ? 1 : 0)
    }

    /// `Biblijeu --install <émulateur> [app]` installs the newest build the way
    /// the button does. With an app path, that copy is the one replaced --
    /// the way to try an install on a duplicate before trusting it with the
    /// real thing. An emulator that is not installed is installed afresh, into
    /// /Applications or into the folder given instead of an app.
    static func runInstall() {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--install"), index + 1 < args.count else {
            print("Usage : Biblijeu --install <id> [chemin de l'app ou dossier]"); exit(2)
        }
        let id = args[index + 1]
        let given = index + 2 < args.count
            ? URL(fileURLWithPath: (args[index + 2] as NSString).expandingTildeInPath) : nil
        let target: InstalledEmulator?
        if let given, given.pathExtension.lowercased() == "app" {
            target = ApplicationScanner.emulator(at: given)
        } else {
            let appFolders = ["/Applications",
                              FileManager.default.homeDirectoryForCurrentUser
                                  .appendingPathComponent("Applications").path]
                .map { URL(fileURLWithPath: $0) }
            target = given == nil
                ? ApplicationScanner.installedEmulators(in: appFolders).first { $0.id == id }
                : nil
        }
        if target == nil, given?.pathExtension.lowercased() != "app",
           let spec = EmulatorCatalog.byID[id] {
            runInstallNew(spec, into: given ?? URL(fileURLWithPath: "/Applications"))
        }
        guard let emulator = target, emulator.id == id else {
            print("« \(id) » introuvable."); exit(1)
        }
        let outcome: Result<URL, Error> = runBlocking {
            guard let update = await UpdateChecker.update(for: emulator),
                  let link = update.download.flatMap(URL.init(string:)) else {
                return .failure(EmulatorInstaller.Failure(message: "Aucun fichier macOS reconnu."))
            }
            print("\(emulator.name) \(emulator.version ?? "?") → \(update.latest)\n  \(link)")
            do {
                return .success(try await EmulatorInstaller.install(emulator, from: link, sign: true) {
                    print("  \($0)")
                })
            } catch {
                return .failure(error)
            }
        }
        reportInstall(outcome)
    }

    private static func runInstallNew(_ spec: EmulatorSpec, into folder: URL) -> Never {
        let outcome: Result<URL, Error> = runBlocking {
            guard let build = await UpdateChecker.latestBuild(for: spec),
                  let link = build.download.flatMap(URL.init(string:)) else {
                return .failure(EmulatorInstaller.Failure(message: "Aucun fichier macOS reconnu."))
            }
            print("\(spec.name) (non installé) → \(build.version)\n  \(link)")
            do {
                return .success(try await EmulatorInstaller.installNew(spec, into: folder, from: link) {
                    print("  \($0)")
                })
            } catch {
                return .failure(error)
            }
        }
        reportInstall(outcome)
    }

    private static func reportInstall(_ outcome: Result<URL, Error>) -> Never {
        switch outcome {
        case .success(let app):
            // The cache still holds the replaced bundle's Info.plist.
            ApplicationScanner.clearCache()
            let version = ApplicationScanner.bundleInfo(at: app)["CFBundleShortVersionString"] as? String
            let signed = AppSigner.isSignatureValid(app) ? "signature valide" : "signature invalide"
            print("✓ Installé : \(app.path) (\(version ?? "?"), \(signed))"); exit(0)
        case .failure(let error):
            print("✗ \(error.localizedDescription)"); exit(1)
        }
    }

    /// `runIfRequested` is called before the app has a run loop, so the async
    /// work needs somewhere to land.
    private static func runBlocking<T>(_ work: @escaping () async -> T) -> T {
        let semaphore = DispatchSemaphore(value: 0)
        var result: T?
        Task {
            result = await work()
            semaphore.signal()
        }
        semaphore.wait()
        return result!
    }
}


// MARK: - Save report

/// `Biblijeu --saves [--to <dossier>]` prints where every emulator keeps its
/// saves and how much there is, and with `--to` copies the lot there.
///
/// The same catalogue the Sauvegarde tab reads, so a folder missing from the
/// tab can be chased here -- and an emulator whose folder is wrong shows up as
/// "rien trouvé" rather than as a silently empty backup.
extension ScanReport {
    static func runSaveReport() {
        let appFolders = ["/Applications",
                          FileManager.default.homeDirectoryForCurrentUser
                              .appendingPathComponent("Applications").path]
            .map { URL(fileURLWithPath: $0) }
        let installed = Set(ApplicationScanner.installedEmulators(in: appFolders).map(\.id))

        // `--to <dossier>` copies as well as counts: the same copy the tab
        // makes, driven from a terminal -- which is also the only way to try it
        // on a folder before trusting a drive to it.
        let args = CommandLine.arguments
        let destination = args.firstIndex(of: "--to").flatMap { index -> URL? in
            guard index + 1 < args.count else { return nil }
            return URL(fileURLWithPath: (args[index + 1] as NSString).expandingTildeInPath)
        }
        let root = destination?.appendingPathComponent(BackupManager.folderName, isDirectory: true)
        var manifest = root.flatMap { BackupManager.readManifest($0.appendingPathComponent(BackupManifest.fileName)) }
            ?? BackupManifest(updated: Date(), machine: Host.current().localizedName, entries: [:])

        // The same categories the tab copies: a report that copied more than
        // the app does would be a report about something else.
        let kinds = Set(AppSettings.storedBackupKinds.compactMap(SaveKind.init(rawValue:)))

        var totalFiles = 0
        var totalBytes: Int64 = 0
        var copied = 0
        var failures: [String] = []
        var manifestChanged = false
        var found = 0
        var silent: [String] = []

        if let destination {
            print("Dossiers de sauvegarde — copie vers \(destination.path)\n")
        } else {
            print("Dossiers de sauvegarde\n")
        }
        for id in SaveCatalog.knownEmulatorIDs.sorted() {
            let name = SaveCatalog.standaloneNames[id] ?? EmulatorCatalog.byID[id]?.name ?? id
            let folders = SaveCatalog.folders(forEmulator: id)
            guard !folders.isEmpty else {
                silent.append(name + (installed.contains(id) ? " (installé)" : ""))
                continue
            }
            found += 1
            print("  \(name)\(installed.contains(id) || SaveCatalog.standaloneNames[id] != nil ? "" : "  — émulateur absent")")
            for folder in folders {
                let measured = BackupEngine.measure(folder.url, filter: folder.filter)
                totalFiles += measured.files
                totalBytes += measured.bytes
                let size = BackupEngine.size(measured.bytes)
                let kind = folder.title.padding(toLength: 26, withPad: " ", startingAt: 0)
                print("    • \(kind) \(measured.files) fichier(s), \(size)")
                print("      \((folder.url.path as NSString).abbreviatingWithTildeInPath)")
                print("      → \(folder.backupSubpath)")

                guard kinds.contains(folder.kind) else {
                    print("      — non copié (\(folder.kind.label) décoché)")
                    continue
                }
                guard let root else { continue }
                let copy = BackupManager.copy(folder, direction: .toBackup, root: root)
                copied += copy.outcome.copied
                failures.append(contentsOf: copy.outcome.failures)
                if let entry = copy.entry,
                   BackupManager.isWorthRecording(entry, over: manifest.entries[folder.backupSubpath],
                                                  copied: copy.outcome.copied) {
                    manifest.entries[folder.backupSubpath] = entry
                    manifestChanged = true
                }
                let done = copy.outcome.copied == 0
                    ? "déjà à jour (\(copy.outcome.identical) fichier(s))"
                    : "copié : \(copy.outcome.copied) fichier(s), \(BackupEngine.size(copy.outcome.bytes))"
                print("      ✓ \(done)")
            }
        }

        // The saves an emulator writes beside the game: ares, melonDS, mGBA and
        // VBA-M all do, and no folder of their own would ever show them.
        let beside = SaveCatalog.folders(besideRomsIn: AppSettings.storedRomFolders)
        if beside.isEmpty {
            print("  À côté des ROM — aucun dossier de ROM configuré")
        } else {
            print("  À côté des ROM")
            for folder in beside {
                let measured = BackupEngine.measure(folder.url, filter: folder.filter)
                totalFiles += measured.files
                totalBytes += measured.bytes
                let kind = folder.title.padding(toLength: 26, withPad: " ", startingAt: 0)
                print("    • \(kind) \(measured.files) fichier(s), \(BackupEngine.size(measured.bytes))")
                print("      \((folder.url.path as NSString).abbreviatingWithTildeInPath)")
                print("      → \(folder.backupSubpath)")

                guard kinds.contains(folder.kind) else {
                    print("      — non copié (\(folder.kind.label) décoché)")
                    continue
                }
                guard let root else { continue }
                let copy = BackupManager.copy(folder, direction: .toBackup, root: root)
                copied += copy.outcome.copied
                failures.append(contentsOf: copy.outcome.failures)
                if let entry = copy.entry,
                   BackupManager.isWorthRecording(entry, over: manifest.entries[folder.backupSubpath],
                                                  copied: copy.outcome.copied) {
                    manifest.entries[folder.backupSubpath] = entry
                    manifestChanged = true
                }
                let done = copy.outcome.copied == 0
                    ? "déjà à jour (\(copy.outcome.identical) fichier(s))"
                    : "copié : \(copy.outcome.copied) fichier(s), \(BackupEngine.size(copy.outcome.bytes))"
                print("      ✓ \(done)")
            }
        }

        // Written once, after both loops -- the folders beside the ROM belong in
        // the manifest too -- and only when something actually moved, so a
        // report run against a drive that is already up to date never writes
        // to it.
        if let root, manifestChanged {
            manifest.updated = Date()
            BackupManager.writeManifest(manifest, to: root.appendingPathComponent(BackupManifest.fileName))
        }

        let size = BackupEngine.size(totalBytes)
        print("\n\(found) émulateur(s) avec des sauvegardes — \(totalFiles) fichier(s), \(size)")
        if root != nil {
            print("\(copied) fichier(s) copié(s)\(failures.isEmpty ? "" : ", \(failures.count) échec(s)")")
            for failure in failures.prefix(8) { print("  ! \(failure)") }
        }
        if !silent.isEmpty {
            print("\nRien trouvé pour : \(silent.joined(separator: ", "))")
        }
        exit(0)
    }
}
