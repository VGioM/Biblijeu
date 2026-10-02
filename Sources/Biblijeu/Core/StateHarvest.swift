import Foundation

/// Looks at what an emulator actually wrote for a game.
///
/// Emulators name their save states after the serial of the disc in the drive,
/// not after the file Biblijeu handed them. A two-disc game therefore leaves
/// its progress under the *second* disc's serial, where "boot disc 1, then
/// resume" will never find it -- the player comes back to an old state and
/// their evening is gone.
///
/// A DuckStation state carries the path of the disc it was taken on, in clear
/// text near the start of the file, right after the title and the serial. That
/// is what lets us tell which state belongs to which game without guessing.
enum StateHarvest {

    /// How much of a state file is read looking for the disc it names.
    private static let headerLength = 8192

    /// Where this emulator keeps its states.
    ///
    /// Asked of the emulator's own configuration rather than assumed, so a
    /// state folder moved onto an external drive is followed without Biblijeu
    /// needing a setting of its own -- there is exactly one place where that
    /// folder is chosen, and it is the emulator's.
    static func directory(for spec: EmulatorSpec) -> URL? {
        guard let data = spec.resume.dataFolder,
              let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                                     in: .userDomainMask).first else { return nil }
        let root = support.appendingPathComponent(data)

        var url = root.appendingPathComponent(spec.resume.stateFolder)
        if let settings = spec.resume.settingsFile,
           let configured = ConfigFile.iniValue(spec.resume.stateKey, section: "Folders",
                                                in: root.appendingPathComponent(settings)) {
            // An absolute path means the folder was moved somewhere else
            // entirely; a relative one still hangs off the emulator's data.
            url = configured.hasPrefix("/") ? URL(fileURLWithPath: configured)
                                            : root.appendingPathComponent(configured)
        }
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// One save state, tied back to the disc of the game it was taken on.
    struct Found {
        let url: URL
        let modified: Date
        /// The game's disc this state belongs to, at its path *today*. The
        /// state names the disc it was taken on, but with the path it had then
        /// -- which is stale the moment the library moves to another drive.
        let disc: URL
    }

    /// The most recent state this emulator wrote for one of `files` -- any disc
    /// of the game, not only the one Biblijeu would boot.
    ///
    /// Backups (`.bak`) are skipped: they are the *previous* state, kept aside
    /// as the new one is written, so resuming from one would lose a save.
    static func newestState(for spec: EmulatorSpec, naming files: [URL]) -> Found? {
        guard spec.resume.statesNameTheirDisc, let directory = directory(for: spec) else { return nil }
        let extensions = Set(spec.resume.extensions.map { $0.lowercased() })
        let discs = files.filter { !$0.lastPathComponent.isEmpty }
        guard !extensions.isEmpty, !discs.isEmpty else { return nil }

        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]) else { return nil }

        // Newest first, so the first file that names one of our discs wins and
        // the rest are never opened.
        let candidates = entries
            .filter { extensions.contains($0.pathExtension.lowercased()) }
            .compactMap { url -> (url: URL, modified: Date)? in
                let values = try? url.resourceValues(forKeys: Set(keys))
                guard values?.isRegularFile == true,
                      let modified = values?.contentModificationDate else { return nil }
                return (url, modified)
            }
            .sorted { $0.modified > $1.modified }

        for candidate in candidates {
            guard let header = header(of: candidate.url) else { continue }
            // Matched on the file name alone: the folder around it is exactly
            // what a move changes, and the disc we hand back is the one we know
            // the current whereabouts of.
            guard let disc = discs.first(where: { header.contains($0.lastPathComponent) }) else { continue }
            return Found(url: candidate.url, modified: candidate.modified, disc: disc)
        }
        return nil
    }

    /// The readable start of a state file: enough to hold the title, the serial
    /// and the disc path. Undecodable bytes become replacement characters,
    /// which is harmless -- we only ever look for a filename in there.
    private static func header(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: headerLength) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
