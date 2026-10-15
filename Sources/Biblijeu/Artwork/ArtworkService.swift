import Foundation

/// One cover the user may pick in the correction sheet.
struct ArtworkCandidate: Identifiable, Hashable {
    /// The image URL is what identifies a proposal: the same picture offered by
    /// two searches is one proposal.
    var id: String { imageURL }
    let title: String
    let source: String
    let imageURL: String
}

/// Decides which picture a game shows, and goes looking for it when there is none.
@MainActor
enum ArtworkService {

    /// What to display right now, without touching the network.
    static func reference(for item: GameItem) -> ArtworkRef {
        let state = PlayStore.shared.state(for: item.id)
        if let path = state.customArtworkPath, !path.isEmpty {
            return .file(URL(fileURLWithPath: path))
        }
        if let url = state.artworkURL, !url.isEmpty {
            return .remote(url)
        }
        // A cover the scan already had on disk: CrossOver's own icon for a
        // Windows game, which beats the generic launcher icon by a mile.
        if let local = item.localArtwork { return .file(local) }
        // An installed app already has a perfectly good icon.
        // A Steam game started from its folder or its .exe has no icon worth
        // showing -- a folder, a blank program -- so it waits for a cover.
        if item.kind != .rom && item.steamGameID == nil { return .appIcon(item.url) }
        return .none
    }

    /// True when the game shows no cover at all, whether or not a previous
    /// lookup already came back empty. This is what "search the missing covers"
    /// means when the user asks for it by hand.
    static func hasNoCover(_ item: GameItem) -> Bool {
        guard item.kind == .rom || item.steamGameID != nil else { return false }
        if item.localArtwork != nil { return false }
        let state = PlayStore.shared.state(for: item.id)
        if state.customArtworkPath != nil { return false }
        if let url = state.artworkURL, !url.isEmpty { return false }
        return true
    }

    /// True when a lookup would be pointless (already found, or already failed).
    /// Used by the automatic pass, which must not hammer the network on every scan.
    static func needsLookup(_ item: GameItem) -> Bool {
        hasNoCover(item) && !PlayStore.shared.state(for: item.id).artworkMissing
    }

    /// Looks up cover art for `items`, writing results into `PlayStore` as they
    /// arrive so the grid fills in progressively. Returns how many covers were found.
    @discardableResult
    static func fetchCovers(for items: [GameItem],
                            progress: @escaping @Sendable (Double) -> Void) async -> Int {
        let pending = items.filter(hasNoCover)
        guard !pending.isEmpty else { progress(1); return 0 }

        let region = AppSettings.shared.preferredRegion
        let key = AppSettings.shared.steamGridDBKey
        // Read the per-game overrides up front: the task group runs off the
        // main actor and must not reach back into the store for every lookup.
        let jobs: [(item: GameItem, searchTitle: String?)] = pending.map {
            ($0, PlayStore.shared.state(for: $0.id).searchTitle)
        }
        let total = Double(jobs.count)

        // Four at a time: enough to keep the connection busy, gentle on a
        // public archive that asks for nothing in return.
        var found = 0
        await withTaskGroup(of: (String, String?).self) { group in
            var index = 0
            var done = 0.0

            func addNext() {
                guard index < jobs.count else { return }
                let job = jobs[index]
                index += 1
                group.addTask {
                    let url = await lookup(job.item, searchTitle: job.searchTitle,
                                           region: region, apiKey: key)
                    return (job.item.id, url)
                }
            }

            for _ in 0..<4 { addNext() }
            while let (id, url) = await group.next() {
                await MainActor.run { PlayStore.shared.setArtwork(url, for: id) }
                if url != nil { found += 1 }
                done += 1
                progress(done / total)
                addNext()
            }
        }
        progress(1)
        return found
    }

    /// One game, one lookup: libretro first, SteamGridDB as the fallback.
    nonisolated static func lookup(_ item: GameItem, searchTitle: String?,
                       region: String, apiKey: String) async -> String? {
        if let system = item.system, system.libretroFolder != nil {
            let name = searchTitle ?? item.rawName
            if let match = await LibretroThumbnails.shared.match(
                rawName: name, system: system, preferredRegion: region),
               let url = match.url(.boxart) {
                return url
            }
            // A dump named nothing like the archive still matches on its title.
            if searchTitle == nil, item.title != item.rawName,
               let match = await LibretroThumbnails.shared.match(
                rawName: item.title, system: system, preferredRegion: region),
               let url = match.url(.boxart) {
                return url
            }
        }
        guard !apiKey.isEmpty else { return nil }
        return await SteamGridDBProvider.shared.cover(for: searchTitle ?? item.title, apiKey: apiKey)
    }

    /// Forces a fresh search for one game, optionally under a different title.
    static func refetch(_ item: GameItem, searchTitle: String? = nil) async -> Bool {
        if let searchTitle {
            PlayStore.shared.update(item.id) { $0.searchTitle = searchTitle }
        }
        let region = AppSettings.shared.preferredRegion
        let key = AppSettings.shared.steamGridDBKey
        let title = searchTitle ?? PlayStore.shared.state(for: item.id).searchTitle
        let url = await lookup(item, searchTitle: title, region: region, apiKey: key)
        PlayStore.shared.setArtwork(url, for: item.id)
        return url != nil
    }

    /// Every cover worth offering for `item`, best first: the archive entries
    /// that resemble the ROM's name, then whatever SteamGridDB knows about the
    /// title. Ranking cannot settle "Tekken 3" against "Tekken 3 (Alt)", and a
    /// wrong cover is best fixed by pointing at the right one.
    static func candidates(for item: GameItem, searchTitle: String?) async -> [ArtworkCandidate] {
        let region = AppSettings.shared.preferredRegion
        let key = AppSettings.shared.steamGridDBKey
        var result: [ArtworkCandidate] = []
        var seen = Set<String>()

        if let system = item.system, system.libretroFolder != nil {
            let matches = await LibretroThumbnails.shared.candidates(
                rawName: searchTitle ?? item.rawName, system: system, preferredRegion: region)
            for match in matches {
                guard let url = match.url(.boxart), seen.insert(url).inserted else { continue }
                result.append(ArtworkCandidate(
                    title: (match.filename as NSString).deletingPathExtension,
                    source: "libretro", imageURL: url))
            }
        }

        if !key.trimmingCharacters(in: .whitespaces).isEmpty {
            let grids = await SteamGridDBProvider.shared.candidates(
                for: searchTitle ?? item.title, apiKey: key)
            for grid in grids where seen.insert(grid.url).inserted {
                result.append(ArtworkCandidate(title: grid.name,
                                               source: "SteamGridDB", imageURL: grid.url))
            }
        }
        return result
    }

    /// The screenshot shown behind the info panel, when the archive has one.
    static func snapshotURL(for item: GameItem) async -> String? {
        guard let system = item.system, system.libretroFolder != nil else { return nil }
        let searchTitle = PlayStore.shared.state(for: item.id).searchTitle
        let match = await LibretroThumbnails.shared.match(
            rawName: searchTitle ?? item.rawName, system: system,
            preferredRegion: AppSettings.shared.preferredRegion)
        return match?.url(.snap)
    }
}
