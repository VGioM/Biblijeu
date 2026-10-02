import Foundation

/// Copies a folder of saves onto another folder, file by file.
///
/// Deliberately a copy and not a synchronisation: nothing is ever deleted at
/// the destination. A save the emulator loses -- a corrupted memory card, a
/// profile reset, a game uninstalled -- stays in the backup, which is the
/// whole reason to keep one. The cost is an old file lingering, which is a
/// price worth paying for never destroying a save.
enum BackupEngine {

    /// What one folder's copy came to.
    struct Outcome: Sendable {
        var copied = 0
        var identical = 0
        var bytes: Int64 = 0
        /// Readable reasons, capped: a folder of unreadable files should not
        /// produce a thousand-line report.
        var failures: [String] = []
        var cancelled = false

        var isEmpty: Bool { copied == 0 && identical == 0 && failures.isEmpty }

        static func + (a: Outcome, b: Outcome) -> Outcome {
            Outcome(copied: a.copied + b.copied,
                    identical: a.identical + b.identical,
                    bytes: a.bytes + b.bytes,
                    failures: Array((a.failures + b.failures).prefix(maxFailures)),
                    cancelled: a.cancelled || b.cancelled)
        }
    }

    private static let maxFailures = 8

    /// Files that belong to the Finder rather than to a game.
    private static let ignored: Set<String> = [".DS_Store", "Icon\r", ".localized"]

    /// Symbolic links are never followed, and never copied.
    ///
    /// A Windows bottle links its "My Documents" straight at the Mac's own
    /// Documents folder: following one would quietly copy a whole home folder
    /// into the backup. Copying the link itself is no better -- restored onto
    /// another Mac it would point at a path that is somebody else's.
    private static func isSymbolicLink(_ values: URLResourceValues) -> Bool {
        values.isSymbolicLink == true
    }

    /// Which of a folder's files are saves.
    ///
    /// An emulator's own folder holds nothing but its own business, so all of
    /// it is copied. A ROM folder is the opposite: the saves an emulator wrote
    /// beside the games sit among the games themselves, and copying those would
    /// turn a backup of a few kilobytes into one of several hundred gigabytes.
    struct Filter: Sendable, Hashable {
        /// File names never copied.
        var excluding: Set<String> = []
        /// Extensions to copy, lowercased. Empty means the whole folder.
        var onlyExtensions: Set<String> = []

        var copiesEverything: Bool { onlyExtensions.isEmpty }

        func wants(_ url: URL) -> Bool {
            if excluding.contains(url.lastPathComponent) { return false }
            return copiesEverything || onlyExtensions.contains(url.pathExtension.lowercased())
        }

        static let everything = Filter()
    }

    /// Sizes as this feature shows them. ByteCountFormatter spells an empty
    /// folder "Zero KB", which reads like a fault rather than like nothing.
    static func size(_ bytes: Int64) -> String {
        bytes <= 0 ? "0 octet" : ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// What a folder holds of what the filter wants, for the sake of showing it
    /// before anything is copied.
    static func measure(_ url: URL, filter: Filter = .everything) -> (files: Int, bytes: Int64) {
        var files = 0
        var bytes: Int64 = 0
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey,
                                      .isDirectoryKey]
        guard let walker = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: keys, options: []) else { return (0, 0) }
        for case let child as URL in walker {
            if ignored.contains(child.lastPathComponent) { continue }
            guard let values = try? child.resourceValues(forKeys: Set(keys)),
                  !isSymbolicLink(values) else { continue }
            if values.isDirectory == true {
                if filter.excluding.contains(child.lastPathComponent) { walker.skipDescendants() }
                continue
            }
            guard values.isRegularFile == true, filter.wants(child) else { continue }
            files += 1
            bytes += Int64(values.fileSize ?? 0)
        }
        return (files, bytes)
    }

    /// Copies everything under `source` into `destination`.
    ///
    /// A file already there with the same size and the same modification date
    /// is left alone, so a backup that runs every ten minutes costs a directory
    /// walk and nothing else.
    static func copy(from source: URL, to destination: URL,
                     filter: Filter = .everything) -> Outcome {
        var outcome = Outcome()
        let fm = FileManager.default

        guard let values = try? source.resourceValues(forKeys: [.isDirectoryKey]),
              values.isDirectory == true else {
            outcome.failures.append("Dossier introuvable : \(source.path)")
            return outcome
        }

        do {
            try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        } catch {
            outcome.failures.append("Impossible de créer \(destination.path) : \(error.localizedDescription)")
            return outcome
        }

        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .fileSizeKey,
                                      .contentModificationDateKey, .isSymbolicLinkKey]
        guard let walker = fm.enumerator(at: source, includingPropertiesForKeys: keys, options: []) else {
            outcome.failures.append("Dossier illisible : \(source.path)")
            return outcome
        }

        let root = source.standardizedFileURL.path
        // A ROM folder on the backup drive can hold the backup itself. Walking
        // into it would copy the copies, and keep finding more of them.
        let ownDestination = destination.standardizedFileURL.path

        for case let child as URL in walker {
            if Task.isCancelled {
                outcome.cancelled = true
                return outcome
            }
            let name = child.lastPathComponent
            if ignored.contains(name) { continue }
            if filter.excluding.contains(name) {
                // An excluded name that is a folder takes its contents with it.
                walker.skipDescendants()
                continue
            }
            guard let values = try? child.resourceValues(forKeys: Set(keys)) else { continue }
            if isSymbolicLink(values) { continue }
            guard let relative = relativePath(of: child, under: root) else { continue }
            let target = destination.appendingPathComponent(relative)

            if values.isDirectory == true {
                if child.standardizedFileURL.path == ownDestination {
                    walker.skipDescendants()
                    continue
                }
                // Mirrored eagerly only when the whole folder is being copied:
                // an emulator's empty state folder is worth keeping as it is,
                // while a filtered copy must not rebuild a whole ROM library's
                // tree of folders to hold a handful of saves.
                if filter.copiesEverything {
                    try? fm.createDirectory(at: target, withIntermediateDirectories: true)
                }
                continue
            }
            guard values.isRegularFile == true, filter.wants(child) else { continue }

            if isUpToDate(target, size: values.fileSize, modified: values.contentModificationDate) {
                outcome.identical += 1
                continue
            }
            do {
                try fm.createDirectory(at: target.deletingLastPathComponent(),
                                       withIntermediateDirectories: true)
                // Replace rather than write over: a half-written save is worse
                // than an old one, and removeItem + copyItem is atomic enough
                // for files this size.
                if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
                try fm.copyItem(at: child, to: target)
                outcome.copied += 1
                outcome.bytes += Int64(values.fileSize ?? 0)
            } catch {
                if outcome.failures.count < maxFailures {
                    outcome.failures.append("\(relative) : \(error.localizedDescription)")
                }
            }
        }
        return outcome
    }

    /// True when the destination already holds this exact file.
    ///
    /// Size and modification date, not content: reading both sides of a
    /// gigabyte of memory cards every ten minutes to find nothing changed would
    /// keep the disc awake for no reason. `copyItem` carries the date over, so
    /// the comparison holds from one run to the next.
    private static func isUpToDate(_ target: URL, size: Int?, modified: Date?) -> Bool {
        guard let values = try? target.resourceValues(forKeys: [.fileSizeKey,
                                                                .contentModificationDateKey]),
              let theirSize = values.fileSize, let theirDate = values.contentModificationDate,
              let size, let modified else { return false }
        // A second of tolerance: not every file system stores the same precision.
        return theirSize == size && abs(theirDate.timeIntervalSince(modified)) < 1
    }

    private static func relativePath(of url: URL, under root: String) -> String? {
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(root + "/") else { return nil }
        return String(path.dropFirst(root.count + 1))
    }
}
