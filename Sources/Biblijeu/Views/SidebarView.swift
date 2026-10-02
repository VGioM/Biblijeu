import SwiftUI

/// Music-style source list: uppercase section headers, symbol + label rows.
struct SidebarView: View {
    @ObservedObject var model: LibraryModel
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var backups = BackupManager.shared

    var body: some View {
        List(selection: $model.selection) {
            Section("Bibliothèque") {
                row(.all)
                if (model.counts[.recent] ?? 0) > 0 { row(.recent) }
                if (model.counts[.favorites] ?? 0) > 0 { row(.favorites) }
                if (model.counts[.roms] ?? 0) > 0 { row(.roms) }
                if (model.counts[.games] ?? 0) > 0 { row(.games) }
                if (model.counts[.emulators] ?? 0) > 0 { row(.emulators) }
                if (model.counts[.other] ?? 0) > 0 { row(.other) }
                if (model.counts[.unplayable] ?? 0) > 0 { row(.unplayable) }
                row(.updates)
                row(.backups)
            }

            let systems = model.systemsWithGames
            if !systems.isEmpty {
                Section("Consoles") {
                    ForEach(systems) { system in
                        row(.system(system.id), title: system.name, symbol: system.symbol)
                    }
                }
            }

            if settings.romFolders.count > 1 {
                Section("Dossiers") {
                    ForEach(settings.romFolders, id: \.self) { path in
                        row(.source(path), title: (path as NSString).lastPathComponent, symbol: "folder")
                            .contextMenu {
                                Button("Retirer ce dossier") { model.removeRomFolder(path) }
                                Button("Afficher dans le Finder") {
                                    Launcher.reveal(URL(fileURLWithPath: path))
                                }
                            }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) { footer }
    }

    @ViewBuilder
    private func row(_ section: LibrarySection,
                     title: String? = nil,
                     symbol: String? = nil) -> some View {
        HStack {
            Label(title ?? section.title, systemImage: symbol ?? section.symbol)
                .lineLimit(1)
            Spacer()
            // The updates row counts what is waiting rather than what it holds,
            // and wears the warm colour so it reads at a glance.
            if section == .updates {
                let late = model.outdatedEmulators.count
                if late > 0 {
                    Text("\(late)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.accentWarm)
                        .monospacedDigit()
                        .help(model.outdatedEmulators.map(\.name).joined(separator: ", "))
                }
            } else if section == .backups {
                // Nothing to count here, but one thing is worth saying without
                // opening the tab: the automatic backup is on and the drive it
                // writes to is not there.
                if settings.autoBackup, !backups.isDestinationAvailable {
                    Image(systemName: "externaldrive.badge.xmark")
                        .font(.caption)
                        .foregroundStyle(Theme.accentWarm)
                        .help("Disque de sauvegarde absent — rien n'est copié pour l'instant.")
                }
            } else if let count = model.counts[section], count > 0 {
                Text("\(count)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
        }
        .tag(section)
    }

    private var footer: some View {
        VStack(spacing: 6) {
            Divider().opacity(0.5)
            Button {
                model.addRomFolder()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "folder.badge.plus")
                    Text(settings.romFolders.isEmpty ? "Ajouter un dossier de ROM…" : "Ajouter un dossier…")
                        .lineLimit(1)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
        }
    }
}
