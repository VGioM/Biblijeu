import SwiftUI

/// The inspector on the right: cover, how this game will be launched, and the
/// handful of controls that only make sense for one game at a time.
struct DetailView: View {
    @ObservedObject var model: LibraryModel
    let item: GameItem

    @ObservedObject private var play = PlayStore.shared
    @ObservedObject private var settings = AppSettings.shared
    @State private var isRenamingSearch = false
    @State private var searchDraft = ""
    @State private var isCorrectingArtwork = false

    private var emulator: InstalledEmulator? { model.emulator(for: item) }
    private var alternatives: [InstalledEmulator] { model.emulators(for: item.systemID) }
    private var state: GameState { play.state(for: item.id) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                cover
                header
                launchControls
                if item.isMultiDisc { discList }
                emulatorSection
                steamSection
                resumeSection
                fileSection
                artworkSection
                classificationSection
                emulatorConsolesSection
            }
            .padding(18)
        }
        .background(Theme.windowBackground)
        // Look at what the emulator wrote for this game, so the panel names the
        // save that "Reprendre" will really load.
        .task(id: item.id) { model.harvestState(for: item) }
        .sheet(isPresented: $isCorrectingArtwork) {
            ArtworkCorrectionSheet(model: model, item: item,
                                   initialTitle: state.searchTitle ?? item.title) {
                isCorrectingArtwork = false
            }
        }
    }

    // MARK: - Pieces

    private var cover: some View {
        ArtworkView(
            ref: ArtworkService.reference(for: item),
            seed: item.sortTitle,
            symbol: item.symbol,
            aspect: Theme.coverAspect,
            cornerRadius: 12)
        .frame(maxWidth: .infinity)
        .shadow(color: .black.opacity(0.5), radius: 14, y: 7)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(item.title)
                .font(.title3.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            Text(item.subtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if !item.languages.isEmpty {
                Text(item.languages.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            if let played = state.lastPlayed {
                Text("Joué \(played.formatted(.relative(presentation: .named))) · \(state.playCount) fois")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// True when the main button will pick up where the player left off.
    private var resumesOnPlay: Bool {
        settings.resumeOnLaunch && model.canResume(item)
    }

    private var launchControls: some View {
        HStack(spacing: 8) {
            Button {
                model.play(item)
            } label: {
                Label(primaryLabel, systemImage: resumesOnPlay ? "play.circle.fill" : "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.accent)
            .controlSize(.large)
            .disabled(item.kind == .rom && emulator == nil)

            if resumesOnPlay {
                Button {
                    model.play(item, resume: .fromStart)
                } label: {
                    Image(systemName: "backward.end.fill")
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .help("Démarrer depuis le début, sans charger de sauvegarde")
            }

            Button {
                play.toggleFavorite(item.id)
            } label: {
                Image(systemName: play.isFavorite(item.id) ? "heart.fill" : "heart")
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .help("Ajouter aux favoris")
        }
    }

    private var primaryLabel: String {
        guard item.kind == .rom else { return "Ouvrir" }
        return resumesOnPlay ? "Reprendre" : "Jouer"
    }

    /// Save states, when the emulator can be told about them on the command line.
    @ViewBuilder
    private var resumeSection: some View {
        if item.kind == .rom, let emulator {
            section("Sauvegarde d'état") {
                let support = emulator.spec.resume
                if !support.isSupported {
                    Text("\(emulator.name) ne sait pas charger une sauvegarde d'état au démarrage. Le jeu démarrera depuis le début.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    if let auto = model.autoStateFile(for: item),
                       state.stateFilePath == nil, state.resumeSlot == nil {
                        // Naming the file matters: it is how the player sees
                        // that a two-disc game comes back on the right disc.
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Image(systemName: "clock.arrow.circlepath")
                                .foregroundStyle(Theme.accent)
                            VStack(alignment: .leading, spacing: 1) {
                                Text((auto as NSString).lastPathComponent)
                                    .font(.system(size: 11.5))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                if let date = state.autoStateDate {
                                    Text(date.formatted(date: .abbreviated, time: .shortened))
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }

                    if support.slot != nil {
                        Picker("", selection: Binding(
                            get: { state.resumeSlot ?? 0 },
                            set: { play.setResumeSlot($0 == 0 ? nil : $0, for: item.id) })
                        ) {
                            Text(support.auto != nil ? "Dernière sauvegarde" : "Emplacement 1").tag(0)
                            ForEach(1...10, id: \.self) { slot in
                                Text("Emplacement \(slot)").tag(slot)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                    } else if support.auto != nil {
                        Text("Reprend la sauvegarde la plus récente de ce jeu.")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                    }

                    if support.file != nil {
                        if let path = state.stateFilePath {
                            HStack(spacing: 6) {
                                Image(systemName: "doc").foregroundStyle(.secondary)
                                Text((path as NSString).lastPathComponent)
                                    .font(.system(size: 11.5))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                        ActionRow {
                            Button(state.stateFilePath == nil ? "Fichier d'état…" : "Changer…") {
                                model.chooseStateFile(for: item)
                            }
                            if state.stateFilePath != nil {
                                Button("Oublier") { play.setStateFile(nil, for: item.id) }
                            }
                        }
                    }

                    if !settings.resumeOnLaunch {
                        Text("« Reprendre au lancement » est désactivé dans les réglages : le bouton Jouer démarre depuis le début.")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private var discList: some View {
        section("Disques") {
            ForEach(Array(item.discs.enumerated()), id: \.offset) { index, disc in
                Button {
                    model.play(item, disc: disc)
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "opticaldisc")
                        Text("Disque \(index + 1)")
                        Spacer()
                        Image(systemName: "play.fill").font(.caption2)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .help(disc.lastPathComponent)
            }
        }
    }

    @ViewBuilder
    private var emulatorSection: some View {
        if item.kind == .rom {
            section("Émulateur") {
                if alternatives.isEmpty {
                    Text("Aucun émulateur installé pour \(item.system?.name ?? "cette console").")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    if let suggestions = suggestedEmulators {
                        Text("Suggestions : \(suggestions)")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.tertiary)
                    }
                } else {
                    Picker("", selection: Binding(
                        get: { state.emulatorID ?? emulator?.id ?? "" },
                        set: { play.setEmulator($0.isEmpty ? nil : $0, for: item.id) })
                    ) {
                        ForEach(alternatives) { candidate in
                            Text(candidate.name).tag(candidate.id)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)

                    bottleRow

                    if let command = model.commandPreview(for: item) {
                        Text(command)
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .textSelection(.enabled)
                            .lineLimit(4)
                            .truncationMode(.middle)
                    }
                }
            }
        }
    }

    /// How a game Steam knows is started: through Steam by default, which
    /// applies the compatibility tool picked there, or in a CrossOver bottle.
    @ViewBuilder
    private var steamSection: some View {
        if item.steamGameID != nil {
            section("Lancement") {
                if model.canRunSteamGameInBottle(item), !model.crossOverBottles.isEmpty {
                    Picker("", selection: Binding(
                        get: { state.crossOverBottle ?? "" },
                        set: { play.setCrossOverBottle($0.isEmpty ? nil : $0, for: item.id) })
                    ) {
                        Text("Via Steam").tag("")
                        ForEach(model.crossOverBottles) { bottle in
                            Text("Bouteille « \(bottle.name) »").tag(bottle.name)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                } else {
                    Text("Via Steam, avec l'outil de compatibilité choisi dans ses propriétés.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }

                if let command = model.commandPreview(for: item) {
                    Text(command)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                        .lineLimit(4)
                        .truncationMode(.middle)
                }
            }
        }
    }

    /// Which bottle a Windows game runs in. CrossOver can hold several, and
    /// only the person who installed the game knows which one it went into
    /// when nothing on disk says so.
    @ViewBuilder
    private var bottleRow: some View {
        if emulator?.spec.id == "crossover", !model.crossOverBottles.isEmpty {
            Picker("", selection: Binding(
                get: { state.crossOverBottle ?? "" },
                set: { play.setCrossOverBottle($0.isEmpty ? nil : $0, for: item.id) })
            ) {
                Text("Bouteille automatique").tag("")
                ForEach(model.crossOverBottles) { bottle in
                    Text(bottle.name).tag(bottle.name)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)

            if let plan = model.crossOverPlan(for: item) {
                Text(plan.shortcut.map { "Bouteille « \(plan.bottle.name) », raccourci « \($0.name) »" }
                     ?? "Bouteille « \(plan.bottle.name) »")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            } else {
                Text("Aucune bouteille reconnue pour ce jeu. Choisissez-en une ci-dessus.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.accentWarm)
            }
        }
    }

    private var suggestedEmulators: String? {
        guard let system = item.system else { return nil }
        let names = system.emulators.compactMap { EmulatorCatalog.byID[$0]?.name }
        return names.isEmpty ? nil : names.prefix(3).joined(separator: ", ")
    }

    private var fileSection: some View {
        section("Fichier") {
            infoRow("Console", item.system?.name ?? "—")
            if let region = item.region { infoRow("Région", region) }
            if let revision = item.revision { infoRow("Révision", revision) }
            if item.fileSize > 0 {
                infoRow("Taille", GameItem.sizeFormatter.string(fromByteCount: item.fileSize))
            }
            if let version = item.appVersion { infoRow("Version", version) }
            Text(item.url.path)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)
                .lineLimit(3)
                .truncationMode(.middle)
            ActionRow {
                Button("Finder") { model.reveal(item) }
                Button("Copier le chemin") { model.copyPath(item) }
            }
        }
    }

    private var artworkSection: some View {
        section("Jaquette") {
            if isRenamingSearch {
                TextField("Titre à rechercher", text: $searchDraft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { commitSearch() }
                ActionRow {
                    Button("Rechercher") { commitSearch() }
                    Button("Annuler") { isRenamingSearch = false }
                }
            } else {
                ActionRow {
                    Button("Rechercher") { model.refetchArtwork(for: item) }
                    Button("Corriger…") { isCorrectingArtwork = true }
                    Button("Autre titre…") {
                        searchDraft = state.searchTitle ?? item.title
                        isRenamingSearch = true
                    }
                    Button("Image…") { model.chooseArtwork(for: item) }
                    if state.customArtworkPath != nil {
                        Button("Jaquette auto") { play.setCustomArtwork(nil, for: item.id) }
                    }
                }
                if state.artworkMissing {
                    Text("Aucune jaquette trouvée. Essayez un autre titre, ou ajoutez une clé SteamGridDB dans les réglages.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    /// The scanner reads extensions and Info.plists; it is right most of the
    /// time and wrong in ways only the owner of the file can settle -- a script
    /// kept beside the games, an emulator that looks like a game, an `.iso`
    /// that could be four different consoles.
    private var classificationSection: some View {
        section("Type") {
            Picker("", selection: Binding(
                get: { item.kind },
                set: { model.setKind($0 == model.scannedKind(for: item) ? nil : $0, for: item) })
            ) {
                ForEach(GameKind.allCases) { kind in
                    Text(kind.label).tag(kind)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            // A game shelved by hand too: an app can wrap a Windows or DOS
            // game as well as be a native one.
            if item.kind.belongsToSystem {
                Picker("Console", selection: Binding(
                    get: { item.systemID },
                    set: { model.setSystem($0 == model.scannedSystemID(for: item) ? nil : $0, for: item) })
                ) {
                    ForEach(SystemCatalog.all) { system in
                        Text(system.name).tag(system.id)
                    }
                }
                .labelsHidden()
            }

            if state.kindOverride != nil || state.systemOverride != nil {
                ActionRow {
                    Button("Détection automatique") {
                        model.setKind(nil, for: item)
                        model.setSystem(nil, for: item)
                    }
                }
            } else {
                Text(item.kind == .other
                     ? "Rangé à part : ni lancé par un émulateur, ni compté comme un jeu."
                     : "Détecté automatiquement. Changez-le si le classement est faux.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// What an app declared an emulator is able to run.
    ///
    /// A ROM is offered the emulators whose console list contains its own, so an
    /// app nobody recognises is inert until this list is filled in -- and once
    /// it is, it turns up in Réglages → Émulateur par console like any other.
    @ViewBuilder
    private var emulatorConsolesSection: some View {
        if item.kind == .emulator, item.url.pathExtension.lowercased() == "app" {
            let chosen = model.emulatorSystems(for: item)
            section("Consoles prises en charge") {
                if chosen.isEmpty {
                    Text("Cet émulateur n'est pas dans le catalogue. Dites-lui quelles consoles il fait tourner pour pouvoir lancer leurs jeux avec.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(chosen, id: \.self) { systemID in
                    HStack(spacing: 6) {
                        Image(systemName: SystemCatalog.system(systemID)?.symbol ?? "gamecontroller")
                            .foregroundStyle(Theme.accent)
                            .font(.system(size: 11))
                        Text(SystemCatalog.system(systemID)?.name ?? systemID)
                            .font(.system(size: 12))
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Button {
                            model.setEmulatorSystems(chosen.filter { $0 != systemID }, for: item)
                        } label: {
                            Image(systemName: "minus.circle").font(.system(size: 11))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }
                }

                Menu("Ajouter une console…") {
                    ForEach(SystemCatalog.all.filter { !chosen.contains($0.id) }) { system in
                        Button(system.name) {
                            model.setEmulatorSystems(chosen + [system.id], for: item)
                        }
                    }
                }
                .menuStyle(.borderlessButton)
                .font(.system(size: 12))
                .fixedSize()

                if model.isUnknownEmulator(item), !chosen.isEmpty {
                    Text("Les jeux lui seront passés comme à un double-clic : pas de plein écran forcé ni de reprise de sauvegarde, que le catalogue seul sait faire.")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func commitSearch() {
        isRenamingSearch = false
        let trimmed = searchDraft.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        model.refetchArtwork(for: item, title: trimmed)
    }

    // MARK: - Building blocks

    private func section<Content: View>(_ title: String,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title.uppercased())
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.tertiary)
                .tracking(0.6)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 2)
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer(minLength: 10)
            Text(value)
                .font(.system(size: 12))
                .multilineTextAlignment(.trailing)
        }
    }
}

/// The panel is 310 points wide and its actions come in fours; a single row of
/// blue links either overflows or shrinks to nothing. These wrap onto as many
/// rows as they need, each button the same width as its neighbour.
private struct ActionRow<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 118), spacing: 6)],
                  alignment: .leading, spacing: 6) {
            content
        }
        // A style, not a `.frame` around the group: a style reaches each button
        // through the environment, where a frame would wrap the lot into a
        // single grid cell.
        .buttonStyle(PanelButtonStyle())
        .lineLimit(1)
    }
}

/// The bordered look of the panel's buttons: same width in every column, and
/// dark enough not to shout next to the cover.
private struct PanelButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11.5, weight: .medium))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 5)
            .padding(.horizontal, 8)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.white.opacity(configuration.isPressed ? 0.20 : 0.09)))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.13), lineWidth: 0.5))
            .contentShape(Rectangle())
    }
}

/// Lets the user point at the right cover.
///
/// Matching a ROM filename against the archive is a ranking, and a ranking is
/// sometimes wrong: "Tekken 3 (Europe)" and "Tekken 3 (Europe) (Alt)" differ by
/// one word, and a Switch title has no archive entry at all. Showing the
/// runners-up and letting the user choose settles it without guessing.
struct ArtworkCorrectionSheet: View {
    @ObservedObject var model: LibraryModel
    let item: GameItem
    let onDone: () -> Void

    @State private var query: String
    @State private var results: [ArtworkCandidate] = []
    @State private var isSearching = false
    @State private var hasSearched = false

    init(model: LibraryModel, item: GameItem, initialTitle: String,
         onDone: @escaping () -> Void) {
        self.model = model
        self.item = item
        self.onDone = onDone
        _query = State(initialValue: initialTitle)
    }

    private let columns = [GridItem(.adaptive(minimum: 96, maximum: 130), spacing: 12)]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Corriger la jaquette").font(.headline)
            Text("Choisissez la bonne image pour « \(item.title) ».")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                TextField("Titre à rechercher", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await search() } }
                Button("Rechercher") { Task { await search() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isSearching || query.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            resultGrid

            HStack {
                Button("Choisir une image…") {
                    model.chooseArtwork(for: item)
                    onDone()
                }
                Spacer()
                Button("Annuler") { onDone() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 540, height: 560)
        .task { await search() }
    }

    @ViewBuilder
    private var resultGrid: some View {
        if isSearching {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Recherche…").font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if results.isEmpty {
            notice(hasSearched ? emptyAdvice : "Lancez la recherche pour voir les jaquettes disponibles.")
        } else {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(results) { candidate in
                        proposal(candidate)
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.05)))
        }
    }

    private var emptyAdvice: String {
        if item.system?.libretroFolder == nil, !AppSettings.shared.hasSteamGridDBKey {
            return "Cette console n'est pas dans l'archive libretro. Ajoutez une clé SteamGridDB dans les réglages, ou choisissez une image."
        }
        return "Aucune jaquette pour ce titre. Essayez le nom d'origine, sans la région ni l'année."
    }

    private func proposal(_ candidate: ArtworkCandidate) -> some View {
        Button {
            model.applyArtwork(candidate, to: item, searchTitle: query)
            onDone()
        } label: {
            VStack(spacing: 5) {
                ArtworkView(ref: .remote(candidate.imageURL),
                            seed: candidate.title,
                            symbol: item.symbol,
                            cornerRadius: 6,
                            showsPlaceholderSymbol: false)
                Text(candidate.title)
                    .font(.system(size: 10.5))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                Text(candidate.source)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
            }
            .padding(6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(candidate.title)
    }

    private func notice(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func search() async {
        guard !isSearching else { return }
        isSearching = true
        results = await model.artworkCandidates(for: item, title: query)
        isSearching = false
        hasSearched = true
    }
}
