import SwiftUI

/// What each installed emulator's project has published, next to what is on
/// disk. A row whose new build Biblijeu can fetch has an « Installer » button;
/// the page the build comes from stays one click away on the arrow.
///
/// The same view serves the sidebar section and the settings tab, so the two
/// can never drift apart.
struct EmulatorUpdatesView: View {
    @ObservedObject var model: LibraryModel
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        // A List rather than a Form: a grouped Form keeps a leading column free
        // for labels, which in the full-width sidebar view leaves a wide empty
        // band down the left of every row.
        List {
            Section { header }

            Section {
                Toggle("Installer automatiquement les mises à jour", isOn: $settings.autoInstallUpdates)
                    .help("Télécharge la nouvelle version depuis la page du projet et remplace l'ancienne, qui part dans la Corbeille. Un émulateur ouvert n'est jamais remplacé.")
                Toggle("Signer automatiquement les émulateurs", isOn: $settings.autoSignEmulators)
                    .help("Après chaque nouvelle version, lève la quarantaine et, si la signature ne tient plus, signe l'app localement (comme codesign --force --deep --sign -).")
            }

            if !available.isEmpty {
                Section {
                    ForEach(available) { row($0, tint: Theme.accentWarm,
                                             symbol: "arrow.down.circle.fill") }
                } header: {
                    HStack {
                        Text("À mettre à jour")
                        Spacer()
                        let installable = available.map(\.emulator).filter(model.canInstallUpdate)
                        if installable.count > 1 {
                            Button("Tout installer") { model.installUpdates(installable) }
                                .controlSize(.small)
                                .disabled(installable.contains { model.emulatorActivity[$0.id] != nil })
                        }
                    }
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
            let missing = model.missingEmulators
            if !missing.isEmpty {
                Section("Non installés") {
                    ForEach(missing) { missingRow($0) }
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

    private func row(_ row: Row, tint: Color, symbol: String) -> some View {
        let id = row.emulator.id
        let activity = model.emulatorActivity[id]
        let problem = model.emulatorProblems[id]
        let done = model.emulatorNotes[id]

        return HStack(alignment: .top, spacing: 10) {
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
                if let activity {
                    Text(activity).font(.caption).foregroundStyle(Theme.accentWarm)
                } else if let problem {
                    Label(problem, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                } else if let done {
                    Label(done, systemImage: "checkmark.seal")
                        .font(.caption)
                        .foregroundStyle(.green)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            if activity != nil {
                ProgressView().controlSize(.small)
            } else if row.update?.verdict == .available, model.canInstallUpdate(row.emulator) {
                Button("Installer") { model.installUpdates([row.emulator]) }
                    .controlSize(.small)
                    .help("Télécharger \(row.update?.latest ?? "la nouvelle version") et remplacer celle-ci")
            }
            if let page = row.page {
                Link(destination: page) {
                    Image(systemName: "arrow.up.right.square")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Ouvrir \(page.host ?? "la page du projet")")
            }
        }
        .contextMenu {
            if row.update?.verdict == .available, model.canInstallUpdate(row.emulator) {
                Button("Installer la mise à jour") { model.installUpdates([row.emulator]) }
            }
            Button("Vérifier et signer l'app") { model.signEmulator(row.emulator) }
                .disabled(activity != nil)
            if let page = row.page {
                Link("Ouvrir la page du projet", destination: page)
            }
            Button("Afficher dans le Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([row.emulator.url])
            }
        }
    }

    /// An emulator of the catalogue this Mac does not have, which Biblijeu
    /// can fetch from its project, install and sign.
    private func missingRow(_ spec: EmulatorSpec) -> some View {
        let activity = model.emulatorActivity[spec.id]
        let problem = model.emulatorProblems[spec.id]
        let page = spec.homepage.flatMap(URL.init(string:))
            ?? spec.updates.flatMap { URL(string: $0.page) }
        let consoles = spec.systems.compactMap { SystemCatalog.system($0)?.name }

        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: "arrow.down.app").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(spec.name).foregroundStyle(.primary)
                Text(consoles.count > 4
                     ? consoles.prefix(4).joined(separator: ", ") + "…"
                     : consoles.joined(separator: ", "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let activity {
                    Text(activity).font(.caption).foregroundStyle(Theme.accentWarm)
                } else if let problem {
                    Label(problem, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            if activity != nil {
                ProgressView().controlSize(.small)
            } else {
                Button("Installer") { model.installMissing(spec) }
                    .controlSize(.small)
                    .disabled(!model.emulatorActivity.isEmpty)
                    .help("Télécharger la dernière version de \(spec.name), l'installer et la signer")
            }
            if let page {
                Link(destination: page) {
                    Image(systemName: "arrow.up.right.square")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Ouvrir \(page.host ?? "la page du projet")")
            }
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
