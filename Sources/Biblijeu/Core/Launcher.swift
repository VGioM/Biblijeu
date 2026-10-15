import AppKit
import Foundation

/// Starts games: an app bundle directly, a ROM through its emulator.
enum Launcher {

    enum LaunchError: LocalizedError {
        case noEmulator(GameSystem?)
        case missingFile(URL)
        case failed(String, underlying: String)
        case cannotResume(String)

        var errorDescription: String? {
            switch self {
            case .noEmulator(let system):
                let name = system?.name ?? "cette console"
                return "Aucun émulateur installé pour \(name)."
            case .missingFile(let url):
                return "Le fichier est introuvable :\n\(url.path)"
            case .failed(let name, let underlying):
                return "\(name) n'a pas pu démarrer.\n\(underlying)"
            case .cannotResume(let name):
                return "\(name) ne sait pas reprendre depuis une sauvegarde d'état en ligne de commande."
            }
        }

        var recoverySuggestion: String? {
            if case .noEmulator(let system) = self, let system {
                let names = system.emulators.compactMap { EmulatorCatalog.byID[$0]?.name }
                if !names.isEmpty {
                    return "Installez l'un de ces émulateurs : \(names.prefix(3).joined(separator: ", "))."
                }
            }
            return nil
        }
    }

    /// The file that should actually be handed to the emulator.
    static func playableURL(for item: GameItem, disc: URL? = nil) -> URL {
        disc ?? item.discs.first ?? item.url
    }

    static func launch(_ item: GameItem,
                       using emulator: InstalledEmulator?,
                       direct: Bool,
                       disc: URL? = nil,
                       resume: ResumeRequest = .fromStart,
                       completion: @escaping (Error?) -> Void) {

        // A native game or an emulator: just open it.
        guard item.kind == .rom else {
            if let gameID = item.steamGameID {
                Steam.launch(gameID: gameID, name: item.title, completion: completion)
            } else if item.url.pathExtension.lowercased() == "app" {
                open(app: item.url, arguments: [], completion: completion)
            } else if CrossOver.isShortcutStub(item.url) {
                // A start-menu entry of a bottle: a program to run, not a
                // document to hand to whatever claims the extension.
                CrossOver.launch(stub: item.url, name: item.title, completion: completion)
            } else if isShellScript(item.url) {
                // A script is meant to run, not to be opened in an editor --
                // which is what NSWorkspace would do with a .sh.
                runInTerminal(item.url, name: item.title, completion: completion)
            } else {
                // A script or a document: let macOS pick the handler, the way
                // a double-click in the Finder would.
                let opened = NSWorkspace.shared.open(item.url)
                completion(opened ? nil : LaunchError.failed(item.title, underlying: "Aucune application ne peut ouvrir ce fichier."))
            }
            return
        }

        let rom = playableURL(for: item, disc: disc)
        guard FileManager.default.fileExists(atPath: rom.path) else {
            completion(LaunchError.missingFile(rom)); return
        }
        guard let emulator else {
            completion(LaunchError.noEmulator(item.system)); return
        }

        guard let leading = emulator.spec.resumeArguments(for: resume) else {
            completion(LaunchError.cannotResume(emulator.name)); return
        }

        if let arguments = arguments(for: emulator.spec, rom: rom, direct: direct, leading: leading) {
            open(app: emulator.url, arguments: arguments, name: emulator.name, completion: completion)
        } else if leading.isEmpty {
            openDocument(rom, with: emulator.url, name: emulator.name, completion: completion)
        } else {
            completion(LaunchError.cannotResume(emulator.name))
        }
    }

    /// Some emulators need a different flag depending on the file.
    private static func arguments(for spec: EmulatorSpec, rom: URL, direct: Bool,
                                  leading: [String] = []) -> [String]? {
        guard var args = spec.arguments(for: rom, direct: direct, leading: leading) else { return nil }
        if spec.id == "uzdoom" || spec.id == "gzdoom" {
            // A pk3 is a mod loaded on top of an IWAD, not an IWAD itself.
            let ext = rom.pathExtension.lowercased()
            if ext != "wad" && ext != "iwad" {
                args = args.map { $0 == "-iwad" ? "-file" : $0 }
            }
        }
        return args
    }

    static func open(app url: URL, arguments: [String], name: String? = nil,
                     completion: @escaping (Error?) -> Void) {
        let config = NSWorkspace.OpenConfiguration()
        config.arguments = arguments
        config.activates = true
        // Launching the same emulator twice with different ROMs should start a
        // second copy rather than bring the running game to the front.
        config.createsNewApplicationInstance = !arguments.isEmpty

        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, error in
            DispatchQueue.main.async {
                if let error {
                    completion(LaunchError.failed(name ?? url.deletingPathExtension().lastPathComponent,
                                                  underlying: error.localizedDescription))
                } else {
                    completion(nil)
                }
            }
        }
    }

    private static func openDocument(_ document: URL, with app: URL, name: String,
                                     completion: @escaping (Error?) -> Void) {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.open([document], withApplicationAt: app, configuration: config) { _, error in
            DispatchQueue.main.async {
                if let error {
                    completion(LaunchError.failed(name, underlying: error.localizedDescription))
                } else {
                    completion(nil)
                }
            }
        }
    }

    static func isShellScript(_ url: URL) -> Bool {
        ["sh", "command", "zsh", "bash"].contains(url.pathExtension.lowercased())
    }

    /// Hands the script to Terminal, the way running it by hand would.
    private static func runInTerminal(_ script: URL, name: String,
                                      completion: @escaping (Error?) -> Void) {
        let terminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        guard FileManager.default.fileExists(atPath: terminal.path) else {
            let opened = NSWorkspace.shared.open(script)
            completion(opened ? nil : LaunchError.failed(name, underlying: "Terminal est introuvable."))
            return
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.open([script], withApplicationAt: terminal, configuration: config) { _, error in
            DispatchQueue.main.async {
                completion(error.map { LaunchError.failed(name, underlying: $0.localizedDescription) })
            }
        }
    }

    static func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Several at once, as one Finder selection.
    ///
    /// An emulator can keep its saves in more than one place, and opening them
    /// one window at a time -- or picking one and hiding the rest -- would say
    /// less than the truth.
    static func reveal(_ urls: [URL]) {
        var seen = Set<String>()
        let unique = urls.filter { seen.insert($0.standardizedFileURL.path).inserted }
        guard !unique.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(unique)
    }

    /// The command line Biblijeu would run -- shown in the info panel so the
    /// user can see exactly what happens, and copy it to a terminal.
    static func commandPreview(for item: GameItem, emulator: InstalledEmulator?, direct: Bool,
                               disc: URL? = nil, resume: ResumeRequest = .fromStart) -> String? {
        guard item.kind == .rom else {
            if let gameID = item.steamGameID { return Steam.commandPreview(gameID: gameID) }
            if CrossOver.isShortcutStub(item.url) { return quoted(item.url.path) }
            return "open \(quoted(item.url.path))"
        }
        guard let emulator else { return nil }
        let rom = playableURL(for: item, disc: disc)
        let executable = executablePath(in: emulator.url)
        let leading = emulator.spec.resumeArguments(for: resume) ?? []
        if let args = arguments(for: emulator.spec, rom: rom, direct: direct, leading: leading) {
            return ([quoted(executable)] + args.map(quoted)).joined(separator: " ")
        }
        return "open -a \(quoted(emulator.url.path)) \(quoted(rom.path))"
    }

    private static func executablePath(in app: URL) -> String {
        let info = ApplicationScanner.bundleInfo(at: app)
        let name = info["CFBundleExecutable"] as? String ?? app.deletingPathExtension().lastPathComponent
        return app.appendingPathComponent("Contents/MacOS/\(name)").path
    }

    private static func quoted(_ path: String) -> String {
        path.contains(" ") || path.contains("'") ? "\"\(path)\"" : path
    }
}
