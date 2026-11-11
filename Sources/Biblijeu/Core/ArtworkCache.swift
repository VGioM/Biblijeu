import AppKit
import CoreImage
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
    private let backdrops = NSCache<NSString, NSImage>()
    private let context = CIContext(options: [.cacheIntermediates: false])
    private var inFlight: [String: Task<NSImage?, Never>] = [:]

    init() {
        directory = AppSettings.supportDirectory.appendingPathComponent("Artwork", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        memory.countLimit = 400
        backdrops.countLimit = 400
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

    /// The blurred copy of a cover that fills the space around it on its tile.
    ///
    /// Made once, small, and kept: the tile used to blur the full-size cover
    /// live (a 22-point Gaussian blur on a picture often 600x900), a GPU filter
    /// every visible tile paid again on each redraw and each scroll step. A
    /// 40-pixel copy blurred once and stretched to the tile looks the same --
    /// behind the cover, dimmed -- for next to nothing.
    func backdrop(for ref: ArtworkRef, from image: NSImage) -> NSImage? {
        let key = ref.cacheKey as NSString
        if let hit = backdrops.object(forKey: key) { return hit }
        guard let source = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              source.width > 0, source.height > 0 else { return nil }

        let width = 40
        let height = max(1, Int((Double(source.height) * Double(width) / Double(source.width)).rounded()))
        guard let small = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        small.interpolationQuality = .medium
        small.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let reduced = small.makeImage() else { return nil }

        // 22 points on a ~168-point tile is about 13 % of its width.
        let input = CIImage(cgImage: reduced)
        guard let blurred = input.clampedToExtent()
                .applyingGaussianBlur(sigma: Double(width) * 0.13)
                .cropped(to: input.extent) as CIImage?,
              let output = context.createCGImage(blurred, from: input.extent) else { return nil }

        let result = NSImage(cgImage: output, size: NSSize(width: width, height: height))
        backdrops.setObject(result, forKey: key)
        return result
    }

    func clear() {
        backdrops.removeAllObjects()
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
