import Foundation

/// Reads one setting out of an emulator's own configuration file.
///
/// Emulators are the authority on where they keep their files: a folder moved
/// onto an external drive is written down in exactly one place, and it is
/// theirs. Asking beats assuming, so every folder Biblijeu shows can be
/// traced back to something the emulator said.
enum ConfigFile {

    /// One key out of one section of an ini file (`[Folders]` and friends).
    ///
    /// Returns nil for a missing file, a missing section, a missing key or an
    /// empty value -- all of which mean the same thing to a caller: nothing was
    /// said, fall back to the default location.
    static func iniValue(_ key: String, section: String, in file: URL) -> String? {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        var inSection = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") {
                inSection = trimmed.caseInsensitiveCompare("[\(section)]") == .orderedSame
                continue
            }
            guard inSection, let equals = trimmed.firstIndex(of: "=") else { continue }
            let name = trimmed[..<equals].trimmingCharacters(in: .whitespaces)
            guard name.caseInsensitiveCompare(key) == .orderedSame else { continue }
            let value = trimmed[trimmed.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            return value.isEmpty ? nil : value
        }
        return nil
    }

    /// One key out of a bml file, the indented format ares writes:
    ///
    ///     Paths
    ///       Saves: /Volumes/Jeux/ares
    ///
    /// A key present but valueless ("Saves" alone on its line) counts as
    /// nothing said, which is how ares spells "use the default".
    static func bmlValue(_ key: String, section: String, in file: URL) -> String? {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        var inSection = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let indented = line.hasPrefix(" ") || line.hasPrefix("\t")
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if !indented {
                // A top-level line ends the section we were reading.
                inSection = trimmed.caseInsensitiveCompare(section) == .orderedSame
                    || trimmed.lowercased().hasPrefix(section.lowercased() + ":")
                continue
            }
            guard inSection else { continue }
            guard let colon = trimmed.firstIndex(of: ":") else { continue }
            let name = trimmed[..<colon].trimmingCharacters(in: .whitespaces)
            guard name.caseInsensitiveCompare(key) == .orderedSame else { continue }
            let value = trimmed[trimmed.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            return value.isEmpty ? nil : value
        }
        return nil
    }
}
