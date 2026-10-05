import AppKit
import Foundation

/// Makes an emulator launchable on this Mac without a trip to the Terminal.
///
/// Most emulators ship ad hoc signed or not signed at all, and a freshly
/// downloaded copy comes with the quarantine flag: Gatekeeper then refuses it
/// without a word, or with a dialog that has no "Open" button. The fix is the
/// one done by hand after every update -- clear the extended attributes, sign
/// again locally -- and it is done here the same way, but only as far as it is
/// needed:
///
/// - a bundle whose signature holds keeps it, Developer ID included: only the
///   quarantine flag is lifted;
/// - a bundle whose signature is broken, or missing, is signed again ad hoc,
///   keeping the entitlements it declared (JIT, above all).
enum AppSigner {

    enum Outcome: Equatable {
        /// Nothing needed doing.
        case untouched
        /// The signature was sound; only the quarantine flag was lifted.
        case unquarantined
        /// The bundle was signed again, locally.
        case resigned
    }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Lifts quarantine and signs again when the signature does not hold.
    /// Blocking: several seconds for a large bundle. Call it off the main thread.
    static func repair(_ app: URL) throws -> Outcome {
        let quarantined = hasQuarantine(app)
        if isSignatureValid(app) {
            guard quarantined else { return .untouched }
            _ = try? Shell.run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", app.path])
            return .unquarantined
        }

        // "Resource fork, Finder information, or similar detritus not allowed"
        // is what codesign says about a bundle carrying extended attributes --
        // Ryujinx does -- so they all go before signing.
        _ = try? Shell.run("/usr/bin/xattr", ["-cr", app.path])
        let signed = try Shell.run("/usr/bin/codesign",
                                   ["--force", "--deep", "--sign", "-",
                                    "--preserve-metadata=entitlements", app.path])
        if signed.status == 0, isSignatureValid(app) { return .resigned }

        // `--deep` gives up on a framework it cannot make sense of -- Azahar's
        // Qt frameworks are "ambiguous (could be app or framework)" -- and
        // leaves the rest unsigned. What the system checks at launch is each
        // binary it loads, so each binary is signed on its own, innermost
        // first, and the bundle last.
        var failures: [String] = []
        for binary in machOFiles(in: app) {
            let result = try Shell.run("/usr/bin/codesign",
                                       ["--force", "--sign", "-",
                                        "--preserve-metadata=entitlements", binary.path])
            if result.status != 0, !signAlone(binary) { failures.append(binary.lastPathComponent) }
        }
        guard failures.isEmpty else {
            throw Failure(message: "La signature a échoué : " + failures.joined(separator: ", "))
        }
        // The bundle's own seal, last. It can still be refused when a nested
        // framework is malformed; that seal is only consulted by Gatekeeper's
        // assessment of a quarantined app, which this one no longer is, while
        // every binary the app loads now carries a valid signature -- the
        // Azahar whose frameworks were flattened starts this way.
        _ = try? Shell.run("/usr/bin/codesign",
                           ["--force", "--sign", "-",
                            "--preserve-metadata=entitlements", app.path])
        return .resigned
    }

    /// Signs a binary away from the folder it sits in, then puts it back.
    ///
    /// A framework whose symbolic links were flattened by a copy -- the binary
    /// sitting both at its top and under `Versions/A` -- makes codesign refuse
    /// the file in place, taking it for a bundle it cannot read. On its own, a
    /// binary is just a binary.
    private static func signAlone(_ binary: URL) -> Bool {
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let copy = folder.appendingPathComponent(binary.lastPathComponent)
        defer { try? fm.removeItem(at: folder) }
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            try fm.copyItem(at: binary, to: copy)
            let result = try Shell.run("/usr/bin/codesign",
                                       ["--force", "--sign", "-",
                                        "--preserve-metadata=entitlements", copy.path])
            guard result.status == 0 else { return false }
            _ = try fm.replaceItemAt(binary, withItemAt: copy)
            return true
        } catch {
            return false
        }
    }

    /// Every executable or library inside `app`, deepest first, links skipped.
    private static func machOFiles(in app: URL) -> [URL] {
        let contents = app.appendingPathComponent("Contents")
        let enumerator = FileManager.default.enumerator(
            at: contents, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        var found: [URL] = []
        while let url = enumerator?.nextObject() as? URL {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values?.isRegularFile == true, values?.isSymbolicLink != true,
                  isMachO(url) else { continue }
            found.append(url)
        }
        return found.sorted { $0.pathComponents.count > $1.pathComponents.count }
    }

    private static func isMachO(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 4), head.count == 4 else { return false }
        let magic = head.withUnsafeBytes { $0.load(as: UInt32.self) }
        // 64- and 32-bit, either byte order, and universal binaries.
        return [0xfeedfacf, 0xcffaedfe, 0xfeedface, 0xcefaedfe, 0xcafebabe, 0xbebafeca]
            .contains(magic)
    }

    static func isSignatureValid(_ app: URL) -> Bool {
        (try? Shell.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path]))?.status == 0
    }

    static func hasQuarantine(_ app: URL) -> Bool {
        getxattr(app.path, "com.apple.quarantine", nil, 0, 0, 0) >= 0
    }
}

/// Remembers which build of each emulator has already been looked at, so the
/// signature is checked once per build rather than on every scan.
///
/// Keyed by the bundle's path, valued by its executable's modification date: a
/// build replaced by hand, by Biblijeu or by the emulator's own updater shows up
/// as a new date.
enum SignatureLedger {

    private static var fileURL: URL {
        AppSettings.supportDirectory.appendingPathComponent("signatures.json")
    }

    static func load() -> [String: Date]? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode([String: Date].self, from: data)
    }

    static func save(_ ledger: [String: Date]) {
        guard let data = try? JSONEncoder().encode(ledger) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    /// Records the build now at `app` as checked. Never creates the ledger:
    /// its absence is what tells the first check to only take note.
    static func note(_ app: URL) {
        guard var ledger = load(), let stamp = stamp(of: app) else { return }
        ledger[app.standardizedFileURL.path] = stamp
        save(ledger)
    }

    /// What identifies the build at `app`: its executable's modification date.
    static func stamp(of app: URL) -> Date? {
        // Read fresh rather than from the scanner's cache: the bundle at this
        // path may have just been replaced.
        let plist = app.appendingPathComponent("Contents/Info.plist")
        let info = NSDictionary(contentsOf: plist) as? [String: Any] ?? [:]
        let name = info["CFBundleExecutable"] as? String
            ?? app.deletingPathExtension().lastPathComponent
        let executable = app.appendingPathComponent("Contents/MacOS/\(name)")
        return (try? executable.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate
    }
}

/// Which build of each emulator was last installed without being asked, so a
/// build that does not take is not downloaded again at every launch.
enum AutoInstallLog {
    private static var fileURL: URL {
        AppSettings.supportDirectory.appendingPathComponent("auto-installs.json")
    }

    static func load() -> [String: String] {
        guard let data = try? Data(contentsOf: fileURL) else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }

    static func save(_ log: [String: String]) {
        guard let data = try? JSONEncoder().encode(log) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

/// Downloads an emulator's new build and puts it where the old one was.
///
/// The old bundle goes to the Trash rather than away for good: a new build that
/// turns out worse is one drag back.
enum EmulatorInstaller {

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Where the work happens. One folder per install, removed afterwards.
    private static func stagingFolder() throws -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("Biblijeu-installs", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    /// True while the app at `url` is running: replacing it under a running
    /// game would lose whatever has not been saved.
    @MainActor
    static func isRunning(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        return NSWorkspace.shared.runningApplications.contains {
            $0.bundleURL?.standardizedFileURL.path == path
        }
    }

    /// Downloads, unpacks, checks and installs. Returns the new bundle.
    ///
    /// `progress` gets a short French status line as things move along.
    static func install(_ emulator: InstalledEmulator, from link: URL, sign: Bool,
                        progress: @escaping @Sendable (String) -> Void) async throws -> URL {
        let staging = try stagingFolder()
        defer { try? FileManager.default.removeItem(at: staging) }

        progress("Téléchargement…")
        let archive = try await Downloader.fetch(link, into: staging) { fraction in
            progress("Téléchargement \(Int(fraction * 100)) %")
        }

        progress("Décompression…")
        let unpacked = staging.appendingPathComponent("unpacked", isDirectory: true)
        try FileManager.default.createDirectory(at: unpacked, withIntermediateDirectories: true)
        try unpack(archive, into: unpacked, depth: 0)

        let wanted = bundleIDs(for: emulator)
        guard let fresh = findApp(in: unpacked, matching: wanted) else {
            throw Failure(message: "Le fichier téléchargé ne contient pas \(emulator.name).")
        }

        progress("Installation…")
        let installed = try replace(emulator.url, with: fresh)

        if sign {
            progress("Signature…")
            _ = try AppSigner.repair(installed)
        } else {
            // A download through URLSession carries no quarantine flag, but an
            // archive can bring one along inside it.
            _ = try? Shell.run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", installed.path])
        }

        // The bundle is stamped with the hour it arrived. Left alone it keeps
        // the dates of the archive, and a zip stores those without a time
        // zone: a KytyPS5 built at 06:40 UTC unpacks here as 04:40 UTC, older
        // than its own release, and would be called outdated the moment it was
        // installed. The bundle folder is not part of the signature.
        try? FileManager.default.setAttributes([.modificationDate: Date()],
                                               ofItemAtPath: installed.path)
        return installed
    }

    /// The bundle identifiers the new build must carry: the catalogue's, and
    /// whatever the installed copy declares, which covers emulators the
    /// catalogue only inferred.
    private static func bundleIDs(for emulator: InstalledEmulator) -> Set<String> {
        var ids = Set(emulator.spec.bundleIDs.map { $0.lowercased() })
        if let own = ApplicationScanner.bundleInfo(at: emulator.url)["CFBundleIdentifier"] as? String {
            ids.insert(own.lowercased())
        }
        return ids
    }

    // MARK: - Unpacking

    /// Opens whatever came down. An archive inside an archive -- a `.tar.gz`
    /// shipped in a zip to keep its permissions -- is opened in turn.
    private static func unpack(_ file: URL, into folder: URL, depth: Int) throws {
        let name = file.lastPathComponent.lowercased()
        if name.hasSuffix(".dmg") {
            try copyOutOfDiskImage(file, into: folder)
        } else if name.hasSuffix(".zip") {
            try check(Shell.run("/usr/bin/ditto", ["-x", "-k", file.path, folder.path]), "ditto")
        } else {
            try check(Shell.run("/usr/bin/tar", ["-xf", file.path, "-C", folder.path]), "tar")
        }

        guard depth < 2, findApp(in: folder, matching: nil) == nil else { return }
        for inner in archives(in: folder) {
            let next = folder.appendingPathComponent("inner-\(depth)-\(inner.lastPathComponent)",
                                                     isDirectory: true)
            try FileManager.default.createDirectory(at: next, withIntermediateDirectories: true)
            try unpack(inner, into: next, depth: depth + 1)
        }
    }

    private static func copyOutOfDiskImage(_ image: URL, into folder: URL) throws {
        let mount = folder.deletingLastPathComponent().appendingPathComponent("mount", isDirectory: true)
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        // "Y" answers a licence agreement, for the images that show one.
        try check(Shell.run("/usr/bin/hdiutil",
                            ["attach", "-nobrowse", "-noautoopen", "-readonly",
                             "-mountpoint", mount.path, image.path],
                            input: "Y\n"), "hdiutil")
        defer { _ = try? Shell.run("/usr/bin/hdiutil", ["detach", "-force", mount.path]) }

        let contents = (try? FileManager.default.contentsOfDirectory(
            at: mount, includingPropertiesForKeys: nil)) ?? []
        // Everything but the shortcut to /Applications most images carry.
        for item in contents where !isSymlink(item) {
            try check(Shell.run("/usr/bin/ditto",
                                [item.path, folder.appendingPathComponent(item.lastPathComponent).path]),
                      "ditto")
        }
    }

    private static func isSymlink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true
    }

    private static func archives(in folder: URL) -> [URL] {
        let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)
        var found: [URL] = []
        while let url = enumerator?.nextObject() as? URL {
            if url.pathExtension.lowercased() == "app" { enumerator?.skipDescendants(); continue }
            let name = url.lastPathComponent.lowercased()
            if UpdateChecker.installableExtensions.contains(where: { name.hasSuffix($0) }) {
                found.append(url)
            }
        }
        return found
    }

    /// The first `.app` under `folder` carrying one of `ids` -- any app at all
    /// when `ids` is nil.
    private static func findApp(in folder: URL, matching ids: Set<String>?) -> URL? {
        let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension.lowercased() == "app" else { continue }
            enumerator?.skipDescendants()
            guard let ids else { return url }
            let plist = url.appendingPathComponent("Contents/Info.plist")
            let info = NSDictionary(contentsOf: plist) as? [String: Any]
            if let id = info?["CFBundleIdentifier"] as? String, ids.contains(id.lowercased()) {
                return url
            }
        }
        return nil
    }

    // MARK: - Replacing

    /// Puts `fresh` next to `old`, under the new build's own name -- PCSX2
    /// names its bundle after its version -- and sends `old` to the Trash.
    /// Should the move fail, the old bundle is put back where it was.
    private static func replace(_ old: URL, with fresh: URL) throws -> URL {
        let fm = FileManager.default
        let folder = old.deletingLastPathComponent()
        let destination = folder.appendingPathComponent(fresh.lastPathComponent)

        if destination.standardizedFileURL != old.standardizedFileURL,
           fm.fileExists(atPath: destination.path) {
            throw Failure(message: "« \(destination.lastPathComponent) » existe déjà à côté de l'ancienne version.")
        }

        // Moved aside first rather than trashed, so it can come back.
        let aside = folder.appendingPathComponent(".\(old.lastPathComponent).biblijeu-old")
        try? fm.removeItem(at: aside)
        do {
            try fm.moveItem(at: old, to: aside)
        } catch {
            throw Failure(message: "Impossible de déplacer l'ancienne version (\(error.localizedDescription)).")
        }
        do {
            // `ditto` rather than a move: the staging folder may sit on another
            // volume than the emulator, and ditto keeps permissions and links.
            try check(Shell.run("/usr/bin/ditto", [fresh.path, destination.path]), "ditto")
        } catch {
            try? fm.removeItem(at: destination)
            try? fm.moveItem(at: aside, to: old)
            throw error
        }

        if (try? fm.trashItem(at: aside, resultingItemURL: nil)) == nil {
            try? fm.removeItem(at: aside)
        }
        // Finder and Launch Services catch up with the new bundle.
        LSRegisterURL(destination as CFURL, true)
        return destination
    }

    private static func check(_ result: Shell.Result, _ tool: String) throws {
        guard result.status == 0 else {
            let last = result.output.split(separator: "\n").last.map(String.init) ?? ""
            throw Failure(message: "\(tool) a échoué. \(last)")
        }
    }
}

/// A download that reports how far along it is, with no time limit beyond the
/// network's own: an emulator is a hundred megabytes, and a slow VPN can take
/// minutes over it.
private final class Downloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {

    private let destination: URL
    private let progress: @Sendable (Double) -> Void
    private var continuation: CheckedContinuation<URL, Error>?
    private var lastReported = -1

    private init(destination: URL, progress: @escaping @Sendable (Double) -> Void) {
        self.destination = destination
        self.progress = progress
    }

    static func fetch(_ url: URL, into folder: URL,
                      progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let target = folder.appendingPathComponent(url.lastPathComponent)
        let downloader = Downloader(destination: target, progress: progress)
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 3 * 3600
        let session = URLSession(configuration: config, delegate: downloader, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        var request = URLRequest(url: url)
        request.setValue("Biblijeu", forHTTPHeaderField: "User-Agent")
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                downloader.continuation = continuation
                session.downloadTask(with: request).resume()
            }
        } onCancel: {
            session.invalidateAndCancel()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let percent = Int(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite) * 100)
        guard percent != lastReported else { return }
        lastReported = percent
        progress(Double(percent) / 100)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        if let http = downloadTask.response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            finish(.failure(HTTP.Failure(status: http.statusCode)))
            return
        }
        do {
            // The temporary file disappears when this method returns.
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            finish(.success(destination))
        } catch {
            finish(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(.failure(error)) }
    }

    private func finish(_ result: Result<URL, Error>) {
        continuation?.resume(with: result)
        continuation = nil
    }
}

/// Runs a command-line tool and waits for it.
enum Shell {
    struct Result {
        let status: Int32
        let output: String
    }

    static func run(_ tool: String, _ arguments: [String], input: String? = nil) throws -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        if let input {
            let stdin = Pipe()
            process.standardInput = stdin
            try process.run()
            stdin.fileHandleForWriting.write(Data(input.utf8))
            try? stdin.fileHandleForWriting.close()
        } else {
            process.standardInput = FileHandle.nullDevice
            try process.run()
        }
        // Read before waiting: a tool that fills the pipe would otherwise wait
        // for us while we wait for it.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Result(status: process.terminationStatus,
                      output: String(decoding: data, as: UTF8.self))
    }
}
