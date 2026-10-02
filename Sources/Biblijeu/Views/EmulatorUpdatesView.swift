import SwiftUI

/// What each installed emulator's project has published, next to what is on
/// disk. A row whose project could be reached is a link: clicking it opens the
/// page the new build is downloaded from.
///
/// The same view serves the sidebar section and the settings tab, so the two
/// can never drift apart.
struct EmulatorUpdatesView: View {
    @ObservedObject var model: LibraryModel

    var body: some View {
        // A List rather than a Form: a grouped Form keeps a leading column free
        // for labels, which in the full-width sidebar view leaves a wide empty
        // band down the left of every row.
        List {
            Section { header }

            if !available.isEmpty {
                Section("À mettre à jour") {
                    ForEach(available) { row($0, tint: Theme.accentWarm,
                                             symbol: "arrow.down.circle.fill") }
                }
            }
            if !current.isEmpty {
                Section("À jour") {
                    ForEach(current) { row($0, tint: .secondary, symbol: "checkmark.circle") }
                }
            }
            if !rest.isEmpty {
                Section("Non vérifiables") {
                    ForEach(rest) { row($0, tint: .secondary, symbol: "questionmark.circle") }
                }
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
    }

    // MARK: - Rows

    /// An emulator and the answer its project gave, ready to draw.
    private struct Row: Identifiable {
        let emulator: InstalledEmulator
        let update: EmulatorUpdate?
        let note: String

        var id: String { emulator.id }
        /// Where clicking goes: the release page, or the project's home page
        /// when there is nothing better.
        var page: URL? {
            if let update, let url = URL(string: update.page) { return url }
            return emulator.spec.homepage.flatMap(URL.init(string:))
        }
    }

    private var rows: [Row] {
        model.installedEmulators.map { emulator in
            let update = model.emulatorUpdates[emulator.id]
            return Row(emulator: emulator, update: update,
                       note: note(for: emulator, update: update,
                                  stale: model.staleUpdates.contains(emulator.id)))
        }
    }

    private var available: [Row] { rows.filter { $0.update?.verdict == .available } }
    private var current: [Row] { rows.filter { $0.update?.verdict == .upToDate } }
    private var rest: [Row] {
        rows.filter { $0.update?.verdict != .available && $0.update?.verdict != .upToDate }
    }

    private func note(for emulator: InstalledEmulator,
                      update: EmulatorUpdate?, stale: Bool) -> String {
        guard let update else {
            return emulator.spec.updates == nil
                ? "Aucune source de mise à jour connue pour ce projet."
                : "Le projet n'a pas répondu."
        }
        let age = stale ? " (réponse d'un tour précédent)" : ""

        // Judged on dates because neither side numbers its builds usefully.
        // Said plainly: a file date is a weaker argument than a version number,
        // and the row should not pretend otherwise.
        if update.byDate == true {
            let when = update.published.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "?"
            let mine = update.installedOn.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "?"
            return update.verdict == .available
                ? "Build plus récente publiée le \(when) — la vôtre date du \(mine). Comparé par date : ce projet ne numérote pas ses builds.\(age)"
                : "Rien de plus récent que votre build du \(mine) — dernière publiée le \(when). Comparé par date : ce projet ne numérote pas ses builds.\(age)"
        }

        switch update.verdict {
        case .available:
            return "Version publiée : \(update.latest)\(age)"
        case .upToDate:
            return "C'est la version publiée\(age)."
        case .unsure:
            // The two are not numbered the same way -- a commit hash, a rolling
            // build -- so the date of the last build is the honest thing to show.
            let when = update.published.map {
                " du " + $0.formatted(date: .abbreviated, time: .omitted)
            } ?? ""
            return "Numérotation non comparable — dernière build\(when) : \(update.latest)\(age)"
        }
    }

    @ViewBuilder
    private func row(_ row: Row, tint: Color, symbol: String) -> some View {
        let content = HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(row.emulator.name).foregroundStyle(.primary)
                    if let version = row.emulator.version {
                        Text(version).font(.caption).foregroundStyle(.tertiary)
                    }
                }
                Text(row.note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if row.page != nil {
                Image(systemName: "arrow.up.right.square")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }

        if let page = row.page {
            Link(destination: page) { content }
                .buttonStyle(.plain)
                .help("Ouvrir \(page.host ?? "la page du projet")")
        } else {
            content
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(summary)
                Text(model.updatesCheckedAt.map {
                    "Vérifié le " + $0.formatted(date: .abbreviated, time: .shortened)
                } ?? "Les projets sont interrogés une fois par jour, au premier lancement.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if model.isCheckingUpdates {
                ProgressView().controlSize(.small)
            } else {
                Button("Vérifier maintenant") { model.checkForEmulatorUpdates(force: true) }
            }
        }
        .padding(.vertical, 4)
    }

    private var summary: String {
        guard model.updatesCheckedAt != nil else {
            return "Aucune vérification effectuée pour l'instant."
        }
        let late = model.outdatedEmulators
        if !late.isEmpty {
            let plural = late.count > 1 ? "s" : ""
            return "\(late.count) mise\(plural) à jour disponible\(plural)."
        }
        // "Everything is up to date" is only true when everyone answered.
        // Projects that stayed silent are not good news, and saying so is the
        // whole point of tracking them.
        let mute = model.unreachableEmulators.count
        if mute > 0 {
            let plural = mute > 1 ? "s n'ont" : " n'a"
            return "Rien à signaler, mais \(mute) projet\(plural) pas répondu."
        }
        return "Tous vos émulateurs sont à jour."
    }
}
