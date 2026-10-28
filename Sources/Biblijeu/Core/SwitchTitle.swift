import Foundation

/// Tells a Switch base game from the update and DLC packages stored next to it.
///
/// Updates and DLC are skipped when they sit in an `Updates`/`DLC` folder, but a
/// game kept in its own folder often has them alongside, under names that do not
/// say what they are ("Guardian of Remembrance.nsp"). Their title ID does: a base
/// game's ends in 000, an update's in 800, a DLC's in anything else.
enum SwitchTitle {

    /// Whether the file is a base game; unknown title IDs count as games.
    static func isBaseGame(_ url: URL) -> Bool {
        guard let id = titleID(of: url) else { return true }
        return id & 0xFFF == 0
    }

    /// The ticket's title ID inside an NSP/NSZ (file-name tags can be wrong), else the `[title ID]` tag.
    static func titleID(of url: URL) -> UInt64? {
        if let id = ticketTitleID(url) { return id }
        let name = url.lastPathComponent
        guard let r = name.range(of: #"\[[0-9A-Fa-f]{16}\]"#, options: .regularExpression) else { return nil }
        return UInt64(name[r].dropFirst().dropLast(), radix: 16)
    }

    /// An NSP is a PFS0 archive; its ticket is named `<rights ID>.tik`, and the
    /// rights ID starts with the title ID. Reads only the archive's file table.
    private static func ticketTitleID(_ url: URL) -> UInt64? {
        guard let handle = FileHandle(forReadingAtPath: url.path) else { return nil }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 16), head.count == 16,
              head.prefix(4) == Data("PFS0".utf8) else { return nil }
        let bytes = [UInt8](head)
        let count = Int(le32(bytes, 4)), tableSize = Int(le32(bytes, 8))
        guard count > 0, count < 4096, tableSize < 1 << 20,
              let rest = try? handle.read(upToCount: count * 0x18 + tableSize),
              rest.count == count * 0x18 + tableSize else { return nil }
        let table = [UInt8](rest)
        let names = Array(table[(count * 0x18)...])
        for i in 0..<count {
            let offset = Int(le32(table, i * 0x18 + 0x10))
            guard offset < names.count else { continue }
            let end = names[offset...].firstIndex(of: 0) ?? names.count
            guard let name = String(bytes: names[offset..<end], encoding: .utf8),
                  name.count == 36, name.hasSuffix(".tik") else { continue }
            return UInt64(name.prefix(16), radix: 16)
        }
        return nil
    }

    private static func le32(_ b: [UInt8], _ at: Int) -> UInt32 {
        UInt32(b[at]) | UInt32(b[at + 1]) << 8 | UInt32(b[at + 2]) << 16 | UInt32(b[at + 3]) << 24
    }
}
