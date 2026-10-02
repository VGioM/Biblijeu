import AppKit
import Foundation

/// Where a tile's picture comes from.
enum ArtworkRef: Hashable {
    case none
    /// Downloaded once, then kept on disk.
    case remote(String)
    /// A file the user chose.
    case file(URL)
    /// The icon macOS already has for an .app bundle.
    case appIcon(URL)

    var cacheKey: String {
        switch self {
        case .none: return ""
        case .remote(let s): return "r:" + s
        case .file(let url): return "f:" + url.path
        case .appIcon(let url): return "a:" + url.path
        }
    }

    var isEmpty: Bool { if case .none = self { return true }; return false }
}

/// Downloads cover art once and keeps it on disk, so the grid is instant on relaunch.
actor ArtworkCache {
    static let shared = ArtworkCache()

    private let directory: URL
    private let memory = NSCache<NSString, NSImage>()
    private var inFlight: [String: Task<NSImage?, Never>] = [:]

    init() {
        directory = AppSettings.supportDirectory.appendingPathComponent("Artwork", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        memory.countLimit = 400
    }

    private func filename(for key: String) -> URL {
        var hash: UInt64 = 5381
        for byte in key.utf8 { hash = (hash &* 33) &+ UInt64(byte) }
        return directory.appendingPathComponent(String(hash, radix: 36) + ".img")
    }

    func image(for ref: ArtworkRef) async -> NSImage? {
        guard !ref.isEmpty else { return nil }
        let key = ref.cacheKey
        if let hit = memory.object(forKey: key as NSString) { return hit }

        switch ref {
        case .none:
            return nil

        case .appIcon(let url):
            // NSWorkspace already has this; no need to touch the disk cache.
            let icon = await MainActor.run { NSWorkspace.shared.icon(forFile: url.path) }
            icon.size = NSSize(width: 512, height: 512)
            memory.setObject(icon, forKey: key as NSString)
            return icon

        case .file(let url):
            guard let image = NSImage(contentsOf: url) else { return nil }
            memory.setObject(image, forKey: key as NSString)
            return image

        case .remote(let urlString):
            guard let remote = URL(string: urlString) else { return nil }
            let file = filename(for: key)
            if let data = try? Data(contentsOf: file), let img = NSImage(data: data) {
                memory.setObject(img, forKey: key as NSString)
                return img
            }
            if let running = inFlight[key] { return await running.value }

            let task = Task<NSImage?, Never> { [file] in
                guard let data = try? await HTTP.data(from: remote),
                      let img = NSImage(data: data) else { return nil }
                try? data.write(to: file, options: .atomic)
                return img
            }
            inFlight[key] = task
            let result = await task.value
            inFlight[key] = nil
            if let result { memory.setObject(result, forKey: key as NSString) }
            return result
        }
    }

    func clear() {
        memory.removeAllObjects()
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func diskSize() -> Int64 {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        return files.reduce(Int64(0)) { total, url in
            total + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }
}
