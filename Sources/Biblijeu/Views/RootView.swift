import SwiftUI

struct RootView: View {
    @ObservedObject var model: LibraryModel
    /// Observed for the subtitle alone: without it the backup progress shown
    /// beside the window title would be whatever it was when the view was last
    /// drawn for another reason.
    @ObservedObject private var backups = BackupManager.shared

    var body: some View {
        NavigationSplitView {
            SidebarView(model: model)
                .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 300)
        } detail: {
            HStack(spacing: 0) {
                if model.selection == .updates {
                    // Not a shelf of games: the emulators and what their
                    // projects have published take the whole width.
                    EmulatorUpdatesView(model: model)
                        .frame(maxWidth: .infinity)
                } else if model.selection == .backups {
                    BackupsView(model: model)
                        .frame(maxWidth: .infinity)
                } else {
                    LibraryGridView(model: model)
                        .frame(maxWidth: .infinity)
                }

                if model.selection.showsGames, model.showInspector, let item = model.selectedItem {
                    Divider()
                    DetailView(model: model, item: item)
                        .frame(width: 310)
                        .transition(.move(edge: .trailing))
                }
            }
            .navigationTitle(model.selection.title)
            .navigationSubtitle(subtitle)
            .toolbar { toolbarContent }
        }
        .animation(.easeOut(duration: 0.2), value: model.showInspector)
        .animation(.easeOut(duration: 0.2), value: model.selectedItemID != nil)
        .searchable(text: $model.searchText, placement: .toolbar, prompt: "Rechercher")
        .frame(minWidth: 960, minHeight: 600)
        .preferredColorScheme(.dark)
        .tint(Theme.accent)
        .alert("Erreur", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } })
        ) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .alert("Biblijeu", isPresented: Binding(
            get: { model.infoMessage != nil },
            set: { if !$0 { model.infoMessage = nil } })
        ) {
            Button("OK") { model.infoMessage = nil }
        } message: {
            Text(model.infoMessage ?? "")
        }
        // Changing shelf leaves the panel describing a game that is no longer
        // on screen; close it rather than let it linger.
        .onChange(of: model.selection) { model.clearSelection() }
        .task { model.rescanIfNeeded() }
    }

    private var subtitle: String {
        if model.isScanning { return model.scanProgress }
        if model.isFetchingArtwork {
            return "Recherche des jaquettes… \(Int(model.artworkProgress * 100)) %"
        }
        if model.selection == .updates {
            let n = model.installedEmulators.count
            return "\(n) émulateur\(n > 1 ? "s" : "") installé\(n > 1 ? "s" : "")"
        }
        if model.selection == .backups {
            if !backups.progress.isEmpty { return backups.progress }
            let n = backups.groups.count
            return n == 0 ? "" : "\(n) émulateur\(n > 1 ? "s" : "") avec des sauvegardes"
        }
        let n = model.visibleItems.count
        return n == 0 ? "" : "\(n) élément\(n > 1 ? "s" : "")"
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button {
                if let item = model.selectedItem { model.play(item) }
            } label: {
                Label("Jouer", systemImage: "play.circle")
            }
            .help("Lancer le jeu sélectionné")
            .disabled(model.selectedItem == nil)
        }

        ToolbarItem {
            if model.isFetchingArtwork {
                ProgressView(value: model.artworkProgress)
                    .progressViewStyle(.circular)
                    .controlSize(.small)
            }
        }

        ToolbarItem {
            Menu {
                Picker("Trier par", selection: $model.sortOrder) {
                    ForEach(GameSortOrder.allCases) { Text($0.rawValue).tag($0) }
                }
                Divider()
                Button("Analyser à nouveau") { model.rescan() }
                Button("Rechercher les jaquettes manquantes") { model.fetchArtwork(force: true) }
                    .disabled(model.items.isEmpty)
                Divider()
                Button("Ajouter un dossier de ROM…") { model.addRomFolder() }
            } label: {
                Label("Options", systemImage: "ellipsis.circle")
            }
        }

        ToolbarItem {
            Button {
                model.showInspector.toggle()
            } label: {
                Label("Informations", systemImage: "sidebar.right")
            }
            .help("Afficher/masquer les informations")
        }
    }
}
