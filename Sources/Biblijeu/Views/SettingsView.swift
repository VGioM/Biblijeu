import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: LibraryModel
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        TabView {
            SourcesSettings(model: model)
                .tabItem { Label("Sources", systemImage: "folder") }
            EmulatorSettings(model: model)
                .tabItem { Label("Émulateurs", systemImage: "cpu") }
            ArtworkSettings(model: model)
                .tabItem { Label("Jaquettes", systemImage: "photo") }
            EmulatorUpdatesView(model: model)
                .tabItem { Label("Mises à jour", systemImage: "arrow.down.circle") }
            BackupsView(model: model)
                .tabItem { Label("Sauvegarde", systemImage: "externaldrive.badge.timemachine") }
        }
        .frame(width: 520, height: 430)
    }
}

// MARK: - Sources

private struct SourcesSettings: View {
    @ObservedObject var model: LibraryModel
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        Form {
            Section("Dossiers de ROM") {
                if settings.romFolders.isEmpty {
                    Text("Aucun dossier. Ajoutez celui qui contient vos ROM.")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                }
                ForEach(settings.romFolders, id: \.self) { path in
                    HStack {
                        Image(systemName: "folder")
                            .foregroundStyle(.secondary)
                        Text((path as NSString).abbreviatingWithTildeInPath)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(path)
                        Spacer()
                        Button {
                            model.removeRomFolder(path)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }
                }
                Button("Ajouter un dossier…") { model.addRomFolder() }
            }

            Section {
                ForEach(settings.excludedFolders, id: \.self) { path in
                    HStack {
                        Image(systemName: FileManager.default.fileExists(atPath: path)
                              ? "folder.badge.minus" : "externaldrive.badge.xmark")
                            .foregroundStyle(.secondary)
                        Text((path as NSString).abbreviatingWithTildeInPath)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(path)
                        Spacer()
                        Button {
                            model.removeExcludedFolder(path)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }
                }
                Button("Exclure un dossier…") { model.addExcludedFolder() }
            } header: {
                Text("Dossiers exclus")
            } footer: {
                Text("Ni analysés ni surveillés. Les dossiers de build (« …noindex », « …_build »), de sauvegardes et de journaux le sont déjà d'office.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Dossiers d'applications") {
                Toggle("Répertorier les jeux et émulateurs installés", isOn: $settings.scanApplications)
                ForEach(settings.applicationFolders, id: \.self) { path in
                    HStack {
                        Image(systemName: FileManager.default.fileExists(atPath: path)
                              ? "folder" : "externaldrive.badge.xmark")
                            .foregroundStyle(.secondary)
                        Text((path as NSString).abbreviatingWithTildeInPath)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(path)
                        Spacer()
                        Button {
                            model.removeApplicationFolder(path)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }
                }
                .disabled(!settings.scanApplications)
                Button("Ajouter un dossier d'applications…") { model.addApplicationFolder() }
                    .disabled(!settings.scanApplications)
                Text("Les émulateurs sont cherchés ici, y compris un niveau plus bas. Ajoutez le dossier de votre disque externe si vos émulateurs y sont.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Applications ajoutées à la main") {
                ForEach(settings.manualApplications, id: \.self) { path in
                    HStack {
                        Image(systemName: FileManager.default.fileExists(atPath: path)
                              ? "app" : "externaldrive.badge.xmark")
                            .foregroundStyle(.secondary)
                        Text((path as NSString).abbreviatingWithTildeInPath)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(path)
                        Spacer()
                        Button {
                            model.removeManualApplication(path)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }
                }
                Button("Ajouter une application…") { model.addApplication() }
                Text("Pour un jeu ou un lanceur que l'analyse ne reconnaît pas : il apparaît dans « Jeux installés », où qu'il soit.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Lancement") {
                Toggle("Lancement direct (plein écran, sans interface)", isOn: $settings.directLaunch)
                Text("Quand c'est possible, l'émulateur démarre directement sur le jeu. Décochez pour ouvrir l'émulateur normalement.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Reprendre la sauvegarde d'état au lancement", isOn: $settings.resumeOnLaunch)
                Text("DuckStation reprend la partie en cours, PCSX2 charge un emplacement, Dolphin et PPSSPP chargent un fichier que vous désignez. Les autres émulateurs démarrent toujours depuis le début.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Surveiller les dossiers", isOn: $settings.watchFolders)
            }

            Section {
                HStack {
                    Button("Analyser à nouveau") { model.rescan() }
                    Spacer()
                    if model.isScanning { ProgressView().controlSize(.small) }
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Emulators

private struct EmulatorSettings: View {
    @ObservedObject var model: LibraryModel
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        Form {
            Section("Émulateurs détectés") {
                if model.installedEmulators.isEmpty {
                    Text("Aucun émulateur reconnu dans vos dossiers d'applications.")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                }
                ForEach(model.installedEmulators) { emulator in
                    HStack {
                        Image(systemName: "cpu").foregroundStyle(Theme.accent)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(emulator.name)
                            Text(emulator.spec.systems.compactMap { SystemCatalog.system($0)?.shortName }
                                    .prefix(6).joined(separator: ", "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        if let version = emulator.version {
                            Text(version).font(.caption).foregroundStyle(.tertiary)
                        }
                    }
                }
            }

            Section("Ajoutés à la main") {
                if settings.manualEmulators.isEmpty {
                    Text("Si un émulateur n'est pas reconnu, désignez-le ici et dites quelles consoles il fait tourner.")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                }
                ForEach(settings.manualEmulators.keys.sorted(), id: \.self) { path in
                    let systems = settings.manualEmulators[path] ?? []
                    HStack {
                        Image(systemName: FileManager.default.fileExists(atPath: path)
                              ? "cpu" : "externaldrive.badge.xmark")
                            .foregroundStyle(Theme.accent)
                        VStack(alignment: .leading, spacing: 1) {
                            Text((path as NSString).lastPathComponent
                                    .replacingOccurrences(of: ".app", with: ""))
                            Text(systems.isEmpty
                                 ? "Aucune console — inutilisable pour l'instant"
                                 : systems.compactMap { SystemCatalog.system($0)?.shortName }
                                    .joined(separator: ", "))
                                .font(.caption)
                                .foregroundStyle(systems.isEmpty ? Theme.accentWarm : .secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        Menu("Consoles") {
                            ForEach(SystemCatalog.all) { system in
                                Button {
                                    let updated = systems.contains(system.id)
                                        ? systems.filter { $0 != system.id }
                                        : systems + [system.id]
                                    model.setManualEmulatorSystems(updated, for: path)
                                } label: {
                                    Label(system.name,
                                          systemImage: systems.contains(system.id) ? "checkmark" : "")
                                }
                            }
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        Button {
                            model.removeManualEmulator(path)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }
                }
                Button("Ajouter un émulateur…") { model.addManualEmulator() }
            }

            Section("Émulateur par console") {
                let systems = model.systemsWithGames
                if systems.isEmpty {
                    Text("Analysez d'abord un dossier de ROM.")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                }
                ForEach(systems) { system in
                    let candidates = model.emulators(for: system.id)
                    Picker(system.name, selection: Binding(
                        get: { settings.emulatorForSystem[system.id] ?? "" },
                        set: { value in
                            if value.isEmpty { settings.emulatorForSystem[system.id] = nil }
                            else { settings.emulatorForSystem[system.id] = value }
                        })
                    ) {
                        Text(candidates.isEmpty ? "Aucun" : "Automatique").tag("")
                        ForEach(candidates) { candidate in
                            Text(candidate.name).tag(candidate.id)
                        }
                    }
                    .disabled(candidates.isEmpty)
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Artwork

private struct ArtworkSettings: View {
    @ObservedObject var model: LibraryModel
    @ObservedObject private var settings = AppSettings.shared

    @State private var keyStatus: String?
    @State private var isTesting = false
    @State private var cacheSize: String = "—"

    var body: some View {
        Form {
            Section("Recherche") {
                Toggle("Rechercher les jaquettes automatiquement", isOn: $settings.autoFetchArtwork)
                Picker("Région préférée", selection: $settings.preferredRegion) {
                    ForEach(AppSettings.regions, id: \.self) { Text($0).tag($0) }
                }
                Text("Les jaquettes rétro viennent de l'archive libretro, sans compte ni clé.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("SteamGridDB (facultatif)") {
                SecureField("Clé API", text: $settings.steamGridDBKey)
                HStack {
                    Button("Tester la clé") { testKey() }
                        .disabled(settings.steamGridDBKey.isEmpty || isTesting)
                    if isTesting { ProgressView().controlSize(.small) }
                    if let keyStatus {
                        Text(keyStatus).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Link("Obtenir une clé", destination: URL(string: "https://www.steamgriddb.com/profile/preferences/api")!)
                        .font(.caption)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("Sert aux jeux que l'archive libretro ne couvre pas : Switch, jeux Windows, jeux macOS.")
                    Text("1. Créez un compte sur steamgriddb.com (Steam, Google ou Discord suffisent).")
                    Text("2. Ouvrez Preferences → API, puis « Generate API key ».")
                    Text("3. Copiez la clé ici, puis « Tester la clé ».")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section("Affichage") {
                HStack {
                    Text("Taille des vignettes")
                    Slider(value: $settings.cardSize, in: 120...260, step: 4)
                    Text("\(Int(settings.cardSize))").monospacedDigit().foregroundStyle(.secondary)
                }
            }

            Section("Cache") {
                HStack {
                    Text("Images téléchargées")
                    Spacer()
                    Text(cacheSize).foregroundStyle(.secondary)
                }
                HStack {
                    Button("Vider le cache d'images") {
                        Task {
                            await ArtworkCache.shared.clear()
                            await refreshCacheSize()
                        }
                    }
                    Button("Rechercher toutes les jaquettes") {
                        PlayStore.shared.clearArtworkResolutions()
                        model.fetchArtwork(force: true)
                    }
                }
                Button("Réinitialiser l'index des jaquettes") {
                    Task { await LibretroThumbnails.shared.clearIndexCache() }
                }
                .font(.caption)
            }
        }
        .formStyle(.grouped)
        .task { await refreshCacheSize() }
    }

    private func testKey() {
        isTesting = true
        keyStatus = nil
        let key = settings.steamGridDBKey
        Task {
            let valid = await SteamGridDBProvider.shared.validate(key: key)
            isTesting = false
            keyStatus = valid ? "Clé valide ✓" : "Clé refusée"
        }
    }

    private func refreshCacheSize() async {
        let bytes = await ArtworkCache.shared.diskSize()
        cacheSize = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
