import Foundation

/// A throwaway folder tree for one test, removed when the test is done.
/// Nothing here ever touches the real library, settings or backups.
final class Fixture {
    let root: URL

    init(named name: String = "ROM") {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("biblijeu-tests-\(UUID().uuidString)")
            .appendingPathComponent(name)
        try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
    }

    /// Writes a file at `path` (relative to the root), creating its folders.
    @discardableResult
    func file(_ path: String, _ contents: String = "x") -> URL {
        let url = root.appendingPathComponent(path)
        try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try! Data(contents.utf8).write(to: url)
        return url
    }

    /// A sibling of the root, for a destination that must sit outside it.
    func sibling(_ name: String) -> URL {
        root.deletingLastPathComponent().appendingPathComponent(name)
    }
}
