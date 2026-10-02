import Foundation

/// What asking an emulator's project about its latest build turned up.
struct EmulatorUpdate: Codable, Hashable {

    /// How the published build compares with the one on disk.
    ///
    /// `unsure` is not a failure. Several projects number their builds in a
    /// way that cannot be lined up with what the bundle declares -- MAME tags
    /// `mame0289`, DuckStation ships one rolling build called "latest" -- and
    /// saying so is worth more than a guess that would cry wolf every day.
    enum Verdict: String, Codable {
        case upToDate
        case available
        case unsure
    }

    let emulatorID: String
    /// What the installed bundle declares, when it declares anything.
    let installed: String?
    /// What the project calls its newest build.
    let latest: String
    let page: String
    let published: Date?
    let verdict: Verdict
    /// True when the verdict rests on publication dates rather than version
    /// numbers, because one side had nothing comparable to offer. Optional so
    /// a report written before this existed still decodes.
    var byDate: Bool?
    /// When the installed build landed on this Mac, for the rows that are
    /// judged by date and have to show their working.
    var installedOn: Date?
    /// The date a date-based verdict was actually weighed against: when the
    /// build's commit was tagged, not when the release was put up. Kept so a
    /// remembered answer can be weighed again the same way. Optional so a
    /// report written before this existed still decodes.
    var tagged: Date?
}

/// One round of questions, kept on disk so opening the settings twice in a
/// morning does not ask twenty projects twice.
struct UpdateReport: Codable {
    var checked: Date
    var updates: [String: EmulatorUpdate]
    /// Emulators whose answer is held over from an earlier round because their
    /// project could not be reached this time. Optional so a report written
    /// before this existed still decodes.
    var stale: Set<String>?

    var newer: [EmulatorUpdate] { updates.values.filter { $0.verdict == .available } }
}

/// Asks each emulator's project whether it has published something newer.
///
/// Everything here fails quietly, one emulator at a time: a project that moved,
/// went offline or answered nonsense costs its own line in the settings and
/// nothing else.
enum UpdateChecker {

    /// GitHub allows sixty unauthenticated questions an hour from one address.
    /// A full round costs one per emulator, so a round a day leaves the budget
    /// untouched even when the user also checks by hand a few times.
    ///
    /// "A day" means a calendar day, not twenty-four hours: the first launch of
    /// the day asks, every later launch that day does not, and tomorrow starts
    /// afresh at midnight. A rolling window would drift later each day until it
    /// landed in the middle of an evening's play.
    /// `now` is injectable so the rule can be played against an hour that is not
    /// the current one -- the interesting cases are all at the edges of a day.
    static func isDue(since checked: Date?, everyoneAnswered: Bool,
                      now: Date = Date()) -> Bool {
        guard let checked else { return true }
        // A round somebody stayed silent for is not a day's answer. Retry it
        // within the hour, which is also when GitHub's allowance comes back.
        guard everyoneAnswered else {
            return now.timeIntervalSince(checked) >= retryInterval
        }
        return !Calendar.current.isDate(checked, inSameDayAs: now)
    }

    static let retryInterval: TimeInterval = 3600

    /// How far a published build may sit ahead of the files it left on disk
    /// before that counts as something newer.
    ///
    /// A `.zip` or a `.dmg` carries its contents' own dates, so an app
    /// unpacked from one is stamped with the hour it was *built*, not the hour
    /// it was installed. Its release goes up after that -- the time a CI
    /// runner takes to upload -- so for the very build that is installed, the
    /// publication beats the file dates by minutes, every time. A bare
    /// `published > landed` therefore calls every rolling-release emulator
    /// outdated the moment after it has been updated, which is what KytyPS5
    /// and Xenia Edge did: four minutes and forty-eight seconds of gap.
    ///
    /// Weighing against the tagged commit rather than the publication removes
    /// most of that gap. This covers what is left, and costs nothing: projects
    /// that number their builds this way publish hours apart, not minutes.
    static let buildGrace: TimeInterval = 15 * 60

    private static var fileURL: URL {
        AppSettings.supportDirectory.appendingPathComponent("emulator-updates.json")
    }

    // MARK: - Reading and writing the last round

    static func cached() -> UpdateReport? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(UpdateReport.self, from: data)
    }

    static func save(_ report: UpdateReport) {
        guard let data = try? JSONEncoder().encode(report) else { return }
        try? FileManager.default.createDirectory(at: AppSettings.supportDirectory,
                                                 withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }

    // MARK: - Asking

    /// Asks about every emulator that has a source, one project at a time.
    ///
    /// Sequential on purpose: a round is a dozen-odd questions and takes a few
    /// seconds either way, while four at once is a burst that a rate limiter
    /// can read as abuse. Nothing here is waiting on the answer.
    ///
    /// `keeping` holds what the last round found. A project that cannot be
    /// reached this time -- GitHub allows sixty questions an hour and a busy
    /// morning can spend them -- keeps its previous answer rather than
    /// vanishing, which would read as "nothing to update".
    ///
    /// What is on disk is consulted too, not only what the caller remembers: a
    /// round is never allowed to replace knowledge with ignorance, whichever of
    /// the two happens to be poorer.
    static func check(_ emulators: [InstalledEmulator],
                      keeping previous: [String: EmulatorUpdate] = [:]) async -> UpdateReport {
        let asked = emulators.filter { $0.spec.updates != nil }
        var updates: [String: EmulatorUpdate] = [:]

        for emulator in asked {
            if Task.isCancelled { break }
            if let answer = await update(for: emulator) {
                updates[answer.emulatorID] = answer
            }
        }

        // Anything unanswered falls back on what the caller remembers, then on
        // what the last saved round knew.
        let onDisk = cached()?.updates ?? [:]
        var stale: Set<String> = []
        for emulator in asked where updates[emulator.id] == nil {
            guard let remembered = previous[emulator.id] ?? onDisk[emulator.id],
                  let carried = rejudged(remembered, for: emulator) else { continue }
            updates[emulator.id] = carried
            stale.insert(emulator.id)
        }
        return UpdateReport(checked: Date(), updates: updates, stale: stale)
    }

    /// Answers remembered from an earlier round, weighed again against what is
    /// installed right now.
    ///
    /// Without this, updating an emulator by hand would leave it flagged as
    /// outdated until the next round of questions happened to succeed.
    static func rejudged(_ updates: [String: EmulatorUpdate],
                         for emulators: [InstalledEmulator]) -> [String: EmulatorUpdate] {
        var judged: [String: EmulatorUpdate] = [:]
        for emulator in emulators {
            guard let remembered = updates[emulator.id],
                  let carried = rejudged(remembered, for: emulator) else { continue }
            judged[emulator.id] = carried
        }
        return judged
    }

    private static func rejudged(_ update: EmulatorUpdate,
                                 for emulator: InstalledEmulator) -> EmulatorUpdate? {
        guard let source = emulator.spec.updates else { return nil }
        return judged(emulator, source: source, latest: update.latest,
                      page: update.page, published: update.published,
                      tagged: update.tagged)
    }

    private static func update(for emulator: InstalledEmulator) async -> EmulatorUpdate? {
        guard let source = emulator.spec.updates,
              let build = try? await latestBuild(from: source) else { return nil }
        return judged(emulator, source: source, latest: build.version,
                      page: build.page ?? source.page, published: build.published,
                      tagged: build.tagged)
    }

    /// Weighs one answer. Version numbers decide whenever they can; only when
    /// they cannot does the calendar get a say.
    private static func judged(_ emulator: InstalledEmulator, source: UpdateSource,
                               latest: String, page: String, published: Date?,
                               tagged: Date?) -> EmulatorUpdate {
        var verdict = compare(installed: emulator.version, latest: latest, from: source)
        var byDate = false
        let landed = installedOn(emulator.url)
        // The commit's date when the project gives one, because that is the
        // side of the build the files on disk can honestly be held against;
        // the publication only otherwise. See `buildGrace`.
        let theirs = tagged ?? published

        if verdict == .unsure, let theirs, let landed {
            // Neither side numbers its builds in a way the other can be lined
            // up against -- a rolling `latest`, a commit hash, an app that
            // declares no version at all. What is left is when each appeared.
            verdict = theirs > landed.addingTimeInterval(buildGrace) ? .available : .upToDate
            byDate = true
        }

        return EmulatorUpdate(emulatorID: emulator.id,
                              installed: emulator.version,
                              latest: latest,
                              page: page,
                              published: published,
                              verdict: verdict,
                              byDate: byDate,
                              installedOn: byDate ? landed : nil,
                              tagged: tagged)
    }

    /// When the build now installed landed on this Mac.
    ///
    /// The latest date any of three places carries, because each lies on its
    /// own: an app dragged in once keeps only its creation date; one that
    /// updates itself in place -- DuckStation does -- keeps a creation date
    /// from the first install ever; and a bundle whose contents were replaced
    /// can keep a folder date years older than the binary inside it, which is
    /// what ares.app does. The executable is the closest thing to "which build
    /// is this", so it has the final say by being part of the maximum.
    private static func installedOn(_ app: URL) -> Date? {
        var dates: [Date] = []
        let keys: Set<URLResourceKey> = [.creationDateKey, .contentModificationDateKey]

        if let values = try? app.resourceValues(forKeys: keys) {
            dates.append(contentsOf: [values.creationDate, values.contentModificationDate]
                .compactMap { $0 })
        }
        let info = ApplicationScanner.bundleInfo(at: app)
        if let name = info["CFBundleExecutable"] as? String {
            let executable = app.appendingPathComponent("Contents/MacOS/\(name)")
            if let values = try? executable.resourceValues(forKeys: keys) {
                dates.append(contentsOf: [values.creationDate, values.contentModificationDate]
                    .compactMap { $0 })
            }
        }
        return dates.max()
    }

    // MARK: - The sources

    private struct Build {
        let version: String
        let page: String?
        let published: Date?
        /// When the build's commit was tagged, for the sources that say.
        let tagged: Date?
    }

    private static func latestBuild(from source: UpdateSource) async throws -> Build {
        switch source {
        case .github(let repo):  return try await githubBuild(repo)
        case .dolphin:           return try await dolphinBuild()
        }
    }

    /// A GitHub release. The *name* is read before the tag: projects tag things
    /// their own way (`mame0289`, `astris-1.0.27`, `g4.14.2`) while the name is
    /// almost always the plain version ("MAME 0.289", "1.0.27+e70414f9").
    private struct GitHubRelease: Decodable {
        let tagName: String
        let name: String?
        let htmlURL: String?
        let publishedAt: Date?
        /// The tagged commit's date -- when the build started rather than when
        /// its files finished uploading.
        let createdAt: Date?

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case name
            case htmlURL = "html_url"
            case publishedAt = "published_at"
            case createdAt = "created_at"
        }

        /// The name when it carries numbers, the tag otherwise -- a name like
        /// "Latest Rolling Release" says less than the tag it hangs on.
        var version: String {
            if let name, !name.isEmpty, numbers(in: name) != nil { return name }
            return tagName
        }
    }

    private static func githubBuild(_ repo: String) async throws -> Build {
        let headers = ["Accept": "application/vnd.github+json",
                       "User-Agent": "Biblijeu"]
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let release: GitHubRelease
        do {
            let stable = try await HTTP.data(
                from: URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!,
                headers: headers)
            release = try decoder.decode(GitHubRelease.self, from: stable)
        } catch let failure as HTTP.Failure where failure.status == 404 {
            // 404 here means "no stable release", not "no such project": the
            // project ships nightlies only, and its newest build of any kind is
            // the honest answer. Any other refusal -- 403 when the hourly
            // allowance is spent above all -- is not worth a second request.
            //
            // The list comes back ordered by the tagged commit, which for a
            // project that builds its nightlies from a queue is not the order
            // they went up in: KytyPS5 has handed back 07:00, 11:19 and 08:37
            // in that order. Asking for one and keeping it would pick a build
            // half a day old, so a handful are asked for and the newest kept.
            let any = try await HTTP.data(
                from: URL(string: "https://api.github.com/repos/\(repo)/releases?per_page=10")!,
                headers: headers)
            let recent = try decoder.decode([GitHubRelease].self, from: any)
            guard let newest = recent.max(by: {
                ($0.publishedAt ?? .distantPast) < ($1.publishedAt ?? .distantPast)
            }) else {
                throw URLError(.resourceUnavailable)
            }
            release = newest
        }
        return Build(version: release.version, page: release.htmlURL,
                     published: release.publishedAt, tagged: release.createdAt)
    }

    private struct DolphinBuild: Decodable {
        let shortrev: String
        let date: String?
    }

    private static func dolphinBuild() async throws -> Build {
        let data = try await HTTP.data(
            from: URL(string: "https://dolphin-emu.org/update/latest/beta/")!)
        let build = try JSONDecoder().decode(DolphinBuild.self, from: data)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        // Dolphin's feed names one build and dates it; there is no commit date
        // to prefer, so the publication is what the calendar gets to weigh.
        return Build(version: build.shortrev, page: nil,
                     published: build.date.flatMap { formatter.date(from: $0) },
                     tagged: nil)
    }

    // MARK: - Comparing

    /// Whether `latest` is newer than `installed`.
    ///
    /// The rule is deliberately timid. Two version strings only mean something
    /// next to each other when they are numbered the same way, so a comparison
    /// is trusted when both sides yield the same run of numbers -- padding
    /// "2.6" out to "2.6.0" so Cemu does not look outdated against its own
    /// release -- and abandoned when they do not.
    static func compare(installed: String?, latest: String, from source: UpdateSource) -> EmulatorUpdate.Verdict {
        guard let installed, !installed.isEmpty else { return .unsure }
        if installed.compare(latest, options: .caseInsensitive) == .orderedSame { return .upToDate }

        // A feed that only ever names the build of the day: anything that is
        // not what we run is newer, by construction.
        if source.namesOnlyTheCurrentBuild { return .available }

        guard var mine = numbers(in: installed), var theirs = numbers(in: latest) else {
            return .unsure
        }
        let differentShapes = mine.count != theirs.count
        let width = max(mine.count, theirs.count)
        mine += Array(repeating: 0, count: width - mine.count)
        theirs += Array(repeating: 0, count: width - theirs.count)

        if mine == theirs { return .upToDate }
        // Different lengths *and* different numbers: the two are not counted
        // the same way at all, so neither can be called the newer one.
        if differentShapes { return .unsure }
        // Running ahead of the last stable release -- a nightly -- is not being
        // out of date.
        return theirs.lexicographicallyPrecedes(mine) ? .upToDate : .available
    }

    /// The run of dot-separated numbers that looks most like a version.
    ///
    /// The longest run wins, earliest first when two are the same length.
    /// Taking the *first* run instead would read "Snes9x 1.63" as version 9,
    /// and product names carry digits far too often for that to be safe.
    ///
    ///     "MAME 0.289"             -> [0, 289]
    ///     "Snes9x 1.63"            -> [1, 63]
    ///     "1.0.27+e70414f92"       -> [1, 0, 27]
    ///     "v148"                   -> [148]
    ///     "Latest Rolling Release" -> nil
    static func numbers(in text: String) -> [Int]? {
        var runs: [[Int]] = []
        var current: [Int] = []
        var digits = ""

        func endNumber() {
            guard !digits.isEmpty else { return }
            current.append(Int(digits) ?? 0)
            digits = ""
        }
        func endRun() {
            endNumber()
            if !current.isEmpty { runs.append(current) }
            current = []
        }

        for character in text {
            if character.isNumber {
                digits.append(character)
            } else if character == "." && !digits.isEmpty {
                endNumber()
            } else {
                endRun()
            }
        }
        endRun()

        guard let best = runs.max(by: { $0.count < $1.count }) else { return nil }
        // A lone number among several runs is almost certainly not a version:
        // it is a commit hash (`1d46d61`) or a date-stamped build name
        // (`KytyPS5-2026-09-14-a9ae04c`). Reading one as "version 1" and
        // calling it equal to the installed 1.0 is the invented answer this
        // whole comparison exists to avoid.
        if best.count == 1 && runs.count > 1 { return nil }
        return best
    }
}
