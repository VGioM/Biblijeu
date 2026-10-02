import SwiftUI

/// Where every emulator keeps its saves, and the two buttons that move them:
/// onto the backup drive, or back from it.
///
/// The same view serves the sidebar section and the settings tab, the way the
/// updates view does, so the two can never drift apart.
struct BackupsView: View {
    @ObservedObject var model: LibraryModel
    @ObservedObject private var backups = BackupManager.shared
    @ObservedObject private var settings = AppSettings.shared

    /// The emulator a restore is being confirmed for; nil for all of them.
    @State private var restoring: RestoreRequest?

    /// The interval as it is being typed, which is not yet a number: "3" on the
    /// way to "30" must not become a backup every three minutes.
    @State private var intervalText = ""
    @FocusState private var intervalFocused: Bool

    private struct RestoreRequest: Identifiable {
        let emulatorID: String?
        var id: String { emulatorID ?? "*" }
        let name: String
    }

    var body: some View {
        List {
            Section { destinationRow }

            Section("Automatique") { automatic }

            Section {
                ForEach(SaveKind.allCases, id: \.self) { kind in
                    kindRow(kind)
                }
            } header: {
                Text("Ce qui est copié")
            } footer: {
                Text("Les ROM ne sont jamais copiées, quelle que soit la case cochée : dans un dossier de ROM, seuls les fichiers de sauvegarde sont lus.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                if backups.groups.isEmpty {
                    Text(backups.isScanning
                         ? "Recherche des dossiers de sauvegarde…"
                         : "Aucun dossier de sauvegarde trouvé. Lancez un jeu une fois : l'émulateur créera le sien.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                ForEach(backups.groups) { group in
                    emulatorRow(group)
                }
            } header: {
                HStack {
                    Text("Dossiers détectés")
                    Spacer()
                    if backups.isScanning { ProgressView().controlSize(.small) }
                    Button("Actualiser") { backups.refresh() }
                        .font(.caption)
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.accent)
                }
            } footer: {
                Text("Les emplacements sont ceux que les émulateurs déclarent : un dossier déplacé est suivi. La liste se relit d'elle-même à chaque retour dans Biblijeu et avant chaque copie, donc un émulateur essayé pour la première fois apparaît tout seul. Les copies vont dans « \(BackupManager.folderName) », à l'intérieur du dossier choisi.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !backups.lastFailures.isEmpty {
                Section("Échecs de la dernière copie") {
                    ForEach(backups.lastFailures, id: \.self) { failure in
                        Label(failure, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(Theme.accentWarm)
                    }
                }
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .task { backups.refresh() }
        .confirmationDialog(
            restoring.map { "Restaurer les sauvegardes de \($0.name) ?" } ?? "Restaurer ?",
            isPresented: Binding(get: { restoring != nil },
                                 set: { if !$0 { restoring = nil } }),
            titleVisibility: .visible
        ) {
            Button("Restaurer", role: .destructive) {
                let request = restoring
                restoring = nil
                backups.run(.toEmulator, emulatorID: request?.emulatorID)
            }
            Button("Annuler", role: .cancel) { restoring = nil }
        } message: {
            Text("Les fichiers du disque de sauvegarde seront copiés par-dessus ceux des émulateurs. Une partie plus récente sur ce Mac sera remplacée par celle de la sauvegarde. Rien n'est supprimé.")
        }
        .alert("Sauvegarde", isPresented: Binding(
            get: { backups.message != nil },
            set: { if !$0 { backups.message = nil } })
        ) {
            Button("OK") { backups.message = nil }
        } message: {
            Text(backups.message ?? "")
        }
    }

    // MARK: - Destination

    @ViewBuilder
    private var destinationRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: symbol)
                    .foregroundStyle(tint)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    if let destination = backups.destination {
                        Text((destination.path as NSString).abbreviatingWithTildeInPath)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(destination.path)
                        Text(status)
                            .font(.caption)
                            .foregroundStyle(backups.isDestinationAvailable ? AnyShapeStyle(.secondary)
                                                                       : AnyShapeStyle(Theme.accentWarm))
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text("Aucun dossier de sauvegarde")
                        Text("Choisissez un dossier sur votre disque externe : c'est là que les sauvegardes de tous vos émulateurs seront copiées.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer()
            }

            HStack(spacing: 8) {
                Button(backups.destination == nil ? "Choisir un dossier…" : "Changer…") {
                    backups.chooseDestination()
                }
                if backups.destination != nil {
                    if backups.isRunning {
                        ProgressView().controlSize(.small)
                        Button("Arrêter") { backups.cancel() }
                    } else {
                        Button("Sauvegarder maintenant") { backups.run(.toBackup) }
                            .disabled(!backups.isDestinationAvailable)
                        Button("Tout restaurer…") {
                            restoring = RestoreRequest(emulatorID: nil, name: "tous vos émulateurs")
                        }
                        .disabled(!backups.isDestinationAvailable)
                    }
                    Spacer()
                    if backups.isDestinationAvailable {
                        Button {
                            if let root = backups.root { Launcher.reveal(root) }
                        } label: {
                            Image(systemName: "arrow.up.forward.app")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Afficher le dossier de sauvegarde dans le Finder")
                    }
                }
            }

            if !backups.progress.isEmpty {
                Text(backups.progress)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.vertical, 2)
    }

    private var symbol: String {
        guard backups.destination != nil else { return "externaldrive.badge.questionmark" }
        return backups.isDestinationAvailable ? "externaldrive.fill.badge.checkmark"
                                              : "externaldrive.badge.xmark"
    }

    private var tint: Color {
        guard backups.destination != nil, backups.isDestinationAvailable else { return Theme.accentWarm }
        return Theme.accent
    }

    private var status: String {
        guard backups.isDestinationAvailable else {
            return "Dossier introuvable — le disque n'est pas branché. Les sauvegardes automatiques sont ignorées jusqu'à son retour."
        }
        if let summary = backups.lastSummary { return summary }
        if let last = backups.lastRun {
            return "Dernière sauvegarde le " + last.formatted(date: .abbreviated, time: .shortened)
        }
        let size = BackupEngine.size(backups.totalBytes)
        return "Jamais sauvegardé — \(size) à copier."
    }

    // MARK: - Automatic

    @ViewBuilder
    private var automatic: some View {
        Toggle("Sauvegarder automatiquement", isOn: $settings.autoBackup)
            .disabled(backups.destination == nil)

        Toggle("Régulièrement, tant que Biblijeu est ouvert", isOn: $settings.backupOnInterval)
            .disabled(!settings.autoBackup)

        HStack(spacing: 6) {
            Text("Toutes les")
            TextField("30", text: $intervalText)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 56)
                .focused($intervalFocused)
                .onSubmit { commitInterval() }
                .onChange(of: intervalFocused) { _, focused in
                    if !focused { commitInterval() }
                }
            Stepper("", value: $settings.backupIntervalMinutes,
                    in: AppSettings.backupIntervalRange, step: 5)
                .labelsHidden()
            Text("minutes")
            Spacer()
        }
        .padding(.leading, 18)
        .disabled(!settings.autoBackup || !settings.backupOnInterval)
        // Typed into, the field is the truth until it is left. Any other way of
        // changing the number -- the stepper, another window -- is written back
        // into it, so the two never disagree.
        .onAppear { intervalText = String(settings.backupIntervalMinutes) }
        .onChange(of: settings.backupIntervalMinutes) { _, minutes in
            if !intervalFocused { intervalText = String(minutes) }
        }

        Toggle("Au lancement de Biblijeu", isOn: $settings.backupOnLaunch)
            .disabled(!settings.autoBackup)
        Toggle("À la fermeture de Biblijeu", isOn: $settings.backupOnQuit)
            .disabled(!settings.autoBackup)

        if settings.autoBackup && !settings.backupOnInterval
            && !settings.backupOnLaunch && !settings.backupOnQuit {
            Label("Aucun moment choisi : rien ne sera copié tout seul.",
                  systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(Theme.accentWarm)
        }

        Text("L'automatique ne va que dans un sens : des émulateurs vers le disque. Restaurer se demande à la main, car cela remplace une partie par une plus ancienne.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

        Text("Chaque copie compare la taille et la date de modification de chaque fichier : ce qui n'a pas changé n'est pas recopié. Une sauvegarde qui ne trouve rien de nouveau n'écrit rien du tout sur le disque.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Takes what was typed, or puts back what was there.
    ///
    /// An empty field, a word, a zero: all mean the same thing -- nothing was
    /// said -- and the answer is the number that was already set, not a timer
    /// firing as fast as it can.
    private func commitInterval() {
        let digits = intervalText.filter(\.isNumber)
        guard let typed = Int(digits), typed > 0 else {
            intervalText = String(settings.backupIntervalMinutes)
            return
        }
        let clamped = min(max(typed, AppSettings.backupIntervalRange.lowerBound),
                          AppSettings.backupIntervalRange.upperBound)
        settings.backupIntervalMinutes = clamped
        intervalText = String(clamped)
    }

    // MARK: - One kind of folder

    @ViewBuilder
    private func kindRow(_ kind: SaveKind) -> some View {
        let total = backups.total(for: kind)
        HStack(alignment: .top, spacing: 8) {
            Toggle("", isOn: Binding(
                get: { backups.isIncluded(kind) },
                set: { backups.setIncluded($0, for: kind) }))
                .labelsHidden()
                .toggleStyle(.checkbox)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Image(systemName: kind.symbol)
                        .font(.caption)
                        .foregroundStyle(backups.isIncluded(kind) ? AnyShapeStyle(Theme.accent)
                                                                  : AnyShapeStyle(.tertiary))
                    Text(kind.label)
                    if total.folders > 0 {
                        Text("\(total.folders) dossier\(total.folders > 1 ? "s" : "") — \(BackupEngine.size(total.bytes))")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    } else {
                        Text("rien trouvé")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                Text(kind.explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(.vertical, 1)
    }

    // MARK: - One emulator

    @ViewBuilder
    private func emulatorRow(_ group: EmulatorSaves) -> some View {
        DisclosureGroup {
            if group.emulatorID == SaveCatalog.romsID {
                Text("ares, melonDS, mGBA et VBA-M écrivent la sauvegarde à côté du jeu, dans votre dossier de ROM. Seuls les fichiers de sauvegarde sont copiés — jamais les ROM — et ils sont remis exactement là où ils étaient.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 2)
            }
            ForEach(group.folders) { state in
                folderRow(state)
            }
            HStack(spacing: 8) {
                // Copying needs the drive; opening a folder does not, so the
                // two are disabled apart. A drive left at home must not stop
                // somebody looking at where their saves are.
                Group {
                    Button("Sauvegarder") { backups.run(.toBackup, emulatorID: group.emulatorID) }
                    Button("Restaurer…") {
                        restoring = RestoreRequest(emulatorID: group.emulatorID, name: group.name)
                    }
                }
                .disabled(backups.isRunning || !backups.isDestinationAvailable)

                // The two ends of this emulator's backup, side by side: where
                // the saves live now, and where their copies are on the drive.
                Button("Ouvrir l'original") {
                    Launcher.reveal(group.folders.map(\.folder.url))
                }
                if let folder = backups.backupFolder(forEmulator: group.emulatorID) {
                    Button("Ouvrir la copie") { Launcher.reveal(folder) }
                }
                Spacer()
            }
            .font(.caption)
            .padding(.top, 2)
        } label: {
            HStack(spacing: 8) {
                Toggle("", isOn: Binding(
                    get: { backups.isIncluded(group.emulatorID) },
                    set: { backups.setIncluded($0, for: group.emulatorID) }))
                    .labelsHidden()
                    .toggleStyle(.checkbox)
                    .help("Inclure cet émulateur dans la sauvegarde automatique")

                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(group.name)
                        if !group.isInstalled {
                            Text("émulateur absent")
                                .font(.caption2)
                                .foregroundStyle(Theme.accentWarm)
                        }
                    }
                    Text(subtitle(for: group))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
            }
        }
    }

    private func subtitle(for group: EmulatorSaves) -> String {
        let size = BackupEngine.size(group.bytes)
        let folders = group.folders.count
        // The folder's own name, not its kind: two of an emulator's folders can
        // share a kind, and "Sauvegardes, Sauvegardes" says nothing.
        let kinds = group.folders.map(\.folder.title)
        let dates = group.folders.compactMap(\.backed?.date)
        var text = "\(folders) dossier\(folders > 1 ? "s" : "") — \(size)"
        if folders <= 2 { text += " — " + kinds.joined(separator: ", ") }
        if let newest = dates.max() {
            text += " — sauvegardé le " + newest.formatted(date: .abbreviated, time: .shortened)
        } else if backups.isDestinationAvailable {
            text += " — jamais sauvegardé"
        }
        return text
    }

    @ViewBuilder
    private func folderRow(_ state: FolderState) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: state.folder.kind.symbol)
                .foregroundStyle(.secondary)
                .font(.caption)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(state.folder.title)
                    .font(.caption)
                Text((state.folder.url.path as NSString).abbreviatingWithTildeInPath)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(state.folder.url.path)
                Text(detail(for: state))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            reveal(state.folder.url, symbol: "arrow.up.forward.app",
                   help: "Afficher le dossier d'origine dans le Finder")
            reveal(backups.backupFolder(for: state.folder), symbol: "externaldrive",
                   help: "Afficher la copie sur le disque de sauvegarde")
        }
        .padding(.vertical, 1)
    }

    /// A Finder button, or the room one would take.
    ///
    /// Kept in place when there is nothing to open -- a folder never copied --
    /// so the buttons of the rows above and below stay in one column instead of
    /// sliding sideways from row to row.
    @ViewBuilder
    private func reveal(_ url: URL?, symbol: String, help: String) -> some View {
        Button {
            if let url { Launcher.reveal(url) }
        } label: {
            Image(systemName: symbol)
                .opacity(url == nil ? 0 : 1)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.tertiary)
        .disabled(url == nil)
        .help(url == nil ? "Pas encore copié sur le disque de sauvegarde" : help)
        .frame(width: 16)
    }

    private func detail(for state: FolderState) -> String {
        let size = BackupEngine.size(state.bytes)
        var text = "\(state.files) fichier\(state.files > 1 ? "s" : "") — \(size)"
        if !backups.isIncluded(state.folder.kind) {
            text += " — non copié (\(state.folder.kind.label) décoché)"
        }
        guard let backed = state.backed else { return text }
        let when = backed.date.formatted(date: .abbreviated, time: .shortened)
        let backedSize = BackupEngine.size(backed.bytes)
        return text + " · copie du \(when) : \(backed.files) fichier(s), \(backedSize)"
    }
}
