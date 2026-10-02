import SwiftUI

/// The main content area: cover grid, or a guidance state when there's nothing to show.
struct LibraryGridView: View {
    @ObservedObject var model: LibraryModel
    @ObservedObject private var settings = AppSettings.shared
    @State private var keyBannerDismissed = false
    @State private var correcting: GameItem?

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: settings.cardSize, maximum: settings.cardSize * 1.4), spacing: 16)]
    }

    var body: some View {
        Group {
            if !model.hasSources {
                EmptyStateView(
                    symbol: "folder.badge.questionmark",
                    title: "Aucune source",
                    message: "Ajoutez le dossier qui contient vos ROM — par exemple ~/Documents/RetroArch/downloads/ROM. Biblijeu reconnaîtra les consoles, retrouvera les jaquettes et lancera chaque jeu avec le bon émulateur.",
                    actionTitle: "Ajouter un dossier…") { model.addRomFolder() }
            } else if model.isScanning && model.items.isEmpty {
                VStack(spacing: 14) {
                    ProgressView().controlSize(.large)
                    Text(model.scanProgress.isEmpty ? "Analyse…" : model.scanProgress)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.visibleItems.isEmpty {
                EmptyStateView(
                    symbol: model.searchText.isEmpty ? "gamecontroller" : "magnifyingglass",
                    title: model.searchText.isEmpty ? "Rien à afficher ici" : "Aucun résultat",
                    message: model.searchText.isEmpty
                        ? "Aucun jeu ne correspond à cette catégorie."
                        : "Aucun jeu ne correspond à « \(model.searchText) ».",
                    actionTitle: nil, action: nil)
            } else {
                grid
            }
        }
        .background(
            Theme.contentBackground
                .contentShape(Rectangle())
                .onTapGesture { model.clearSelection() })
        .safeAreaInset(edge: .top, spacing: 0) { banner }
        .sheet(item: $correcting) { item in
            ArtworkCorrectionSheet(
                model: model, item: item,
                initialTitle: PlayStore.shared.state(for: item.id).searchTitle ?? item.title) {
                    correcting = nil
                }
        }
    }

    private var banner: some View {
        VStack(spacing: 0) {
            offlineBanner
            emulatorBanner
            keyBanner
        }
    }

    /// A library on an external drive disappears when the drive does. Say so,
    /// rather than showing an empty grid that looks like a lost library.
    @ViewBuilder
    private var offlineBanner: some View {
        let missing = model.unavailableFolders
        if !missing.isEmpty {
            HStack(spacing: 11) {
                Image(systemName: "externaldrive.badge.xmark")
                    .foregroundStyle(Theme.accentWarm)
                VStack(alignment: .leading, spacing: 1) {
                    Text(missing.count == 1 ? "Dossier indisponible" : "\(missing.count) dossiers indisponibles")
                        .font(.system(size: 12.5, weight: .semibold))
                    Text(missing.map { ($0 as NSString).lastPathComponent }.joined(separator: ", ")
                         + " — disque débranché ou renommé. Les jeux reviendront tout seuls au rebranchement.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 8)
                Button("Analyser à nouveau") { model.rescan() }
                    .controlSize(.small)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background(.ultraThinMaterial)
            .overlay(alignment: .bottom) { Divider().opacity(0.6) }
        }
    }

    /// Switch, Windows and macOS titles are outside libretro's archive, so
    /// without a SteamGridDB key they simply have no cover to find.
    @ViewBuilder
    private var keyBanner: some View {
        let uncovered = model.itemsNeedingExternalArtwork
        if !settings.hasSteamGridDBKey, uncovered > 0, !keyBannerDismissed,
           !model.isScanning {
            HStack(spacing: 11) {
                Image(systemName: "photo.badge.exclamationmark")
                    .foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(uncovered) jeu\(uncovered > 1 ? "x" : "") sans jaquette")
                        .font(.system(size: 12.5, weight: .semibold))
                    Text("L'archive libretro ne couvre pas la Switch, ni les jeux Windows et macOS. Une clé SteamGridDB gratuite complète le reste.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                SettingsLink { Text("Ajouter une clé…") }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
                    .controlSize(.small)
                Button {
                    keyBannerDismissed = true
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background(.ultraThinMaterial)
            .overlay(alignment: .bottom) { Divider().opacity(0.6) }
        }
    }

    /// A console with no emulator is the other problem worth interrupting for.
    @ViewBuilder
    private var emulatorBanner: some View {
        let orphans = model.counts[.unplayable] ?? 0
        if orphans > 0, case .unplayable = model.selection {
            HStack(spacing: 11) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.accentWarm)
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(orphans) jeu\(orphans > 1 ? "x" : "") sans émulateur")
                        .font(.system(size: 12.5, weight: .semibold))
                    Text("Installez l'émulateur correspondant, puis relancez l'analyse.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button("Analyser à nouveau") { model.rescan() }
                    .controlSize(.small)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background(.ultraThinMaterial)
            .overlay(alignment: .bottom) { Divider().opacity(0.6) }
        }
    }

    private var grid: some View {
        // The tap-to-close area has to be as tall as the window, not as tall as
        // the tiles: a short shelf leaves most of the grid empty, and clicking
        // that emptiness is the obvious way to dismiss the info panel.
        GeometryReader { proxy in
            ScrollView {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 18) {
                    ForEach(model.visibleItems) { item in
                        GameCard(
                            item: item,
                            isSelected: model.selectedItemID == item.id,
                            emulator: model.emulator(for: item),
                            onPlay: { model.play(item) },
                            onInfo: { model.select(item) })
                        .onTapGesture(count: 2) { model.play(item) }
                        .onTapGesture { model.select(item) }
                        .contextMenu { contextMenu(for: item) }
                    }
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 18)
                .frame(maxWidth: .infinity,
                       minHeight: max(0, proxy.size.height - proxy.safeAreaInsets.top
                                      - proxy.safeAreaInsets.bottom),
                       alignment: .topLeading)
                // A tap that misses every tile lands here and clears the
                // selection, which closes the info panel. Tiles handle their
                // own taps first.
                .contentShape(Rectangle())
                .onTapGesture { model.clearSelection() }
            }
        }
    }

    @ViewBuilder
    private func contextMenu(for item: GameItem) -> some View {
        let emulator = model.emulator(for: item)
        let canResume = model.canResume(item)
        Button(item.kind == .rom ? (canResume && settings.resumeOnLaunch ? "Reprendre" : "Jouer") : "Ouvrir") {
            model.play(item)
        }
        .disabled(item.kind == .rom && emulator == nil)

        if canResume {
            Button("Jouer depuis le début") { model.play(item, resume: .fromStart) }
            if emulator?.spec.resume.slot != nil {
                Menu("Reprendre l'emplacement") {
                    ForEach(1...10, id: \.self) { slot in
                        Button("Emplacement \(slot)") { model.play(item, resume: .slot(slot)) }
                    }
                }
            }
        }

        if item.isMultiDisc {
            Menu("Lancer un disque") {
                ForEach(Array(item.discs.enumerated()), id: \.offset) { index, disc in
                    Button("Disque \(index + 1)") { model.play(item, disc: disc) }
                }
            }
        }

        let alternatives = model.emulators(for: item.systemID)
        if item.kind == .rom, alternatives.count > 1 {
            Menu("Ouvrir avec") {
                ForEach(alternatives) { candidate in
                    Button(candidate.name) { model.play(item, with: candidate) }
                }
            }
        }

        Divider()

        Button(PlayStore.shared.isFavorite(item.id) ? "Retirer des favoris" : "Ajouter aux favoris") {
            PlayStore.shared.toggleFavorite(item.id)
        }
        Button("Masquer") { PlayStore.shared.setHidden(true, for: item.id) }

        Divider()

        Button("Rechercher la jaquette") { model.refetchArtwork(for: item) }
        Button("Corriger la jaquette…") {
            model.select(item)
            correcting = item
        }
        Button("Choisir une image…") { model.chooseArtwork(for: item) }

        Menu("Classer comme") {
            ForEach(GameKind.allCases) { kind in
                Button {
                    model.setKind(kind == model.scannedKind(for: item) ? nil : kind, for: item)
                } label: {
                    // A tick on the kind in force, whether detected or chosen.
                    Label(kind.label, systemImage: item.kind == kind ? "checkmark" : "")
                }
            }
            Divider()
            Button("Détection automatique") {
                model.setKind(nil, for: item)
                model.setSystem(nil, for: item)
            }
        }

        Divider()

        Button("Afficher dans le Finder") { model.reveal(item) }
        Button("Copier le chemin") { model.copyPath(item) }
        if item.kind == .rom, emulator != nil {
            Button("Copier la commande de lancement") { model.copyCommand(item) }
        }
    }
}

struct EmptyStateView: View {
    let symbol: String
    let title: String
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 13) {
            Image(systemName: symbol)
                .font(.system(size: 46, weight: .thin))
                .foregroundStyle(.tertiary)
            Text(title).font(.title3.weight(.semibold))
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
                    .controlSize(.large)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
