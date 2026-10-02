import AppKit
import SwiftUI

@main
struct BiblijeuApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = LibraryModel()

    init() {
        // `--scan` turns the app into a one-shot diagnostic tool.
        ScanReport.runIfRequested()
    }

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
                .background(Theme.windowBackground)
        }
        .windowToolbarStyle(.unified(showsTitle: true))
        .commands {
            CommandGroup(replacing: .newItem) { }

            CommandGroup(after: .newItem) {
                Button("Ajouter un dossier de ROM…") { model.addRomFolder() }
                    .keyboardShortcut("o", modifiers: .command)
                Button("Analyser à nouveau") { model.rescan() }
                    .keyboardShortcut("r", modifiers: .command)
            }

            CommandMenu("Jeu") {
                Button("Jouer") {
                    if let item = model.selectedItem { model.play(item) }
                }
                .keyboardShortcut(.return, modifiers: [])
                .disabled(model.selectedItem == nil)

                Button("Jouer depuis le début") {
                    if let item = model.selectedItem { model.play(item, resume: .fromStart) }
                }
                .keyboardShortcut(.return, modifiers: .shift)
                .disabled(model.selectedItem == nil)

                Button("Ajouter aux favoris") {
                    if let item = model.selectedItem { PlayStore.shared.toggleFavorite(item.id) }
                }
                .keyboardShortcut("d", modifiers: .command)
                .disabled(model.selectedItem == nil)

                Divider()

                Button("Afficher dans le Finder") {
                    if let item = model.selectedItem { model.reveal(item) }
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(model.selectedItem == nil)
            }
        }

        Settings {
            SettingsView(model: model)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        NSApp.appearance = NSAppearance(named: .darkAqua)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// One last copy of the saves onto the backup drive before going away.
    ///
    /// The emulator the player just quit wrote its save seconds ago, and this
    /// is the moment it is worth having. Quitting is never held hostage to it:
    /// the run has its own deadline, after which the app closes regardless --
    /// the saves are still on the Mac, and the next launch copies them.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            let backups = BackupManager.shared
            guard backups.wantsBackupOnQuit else { return .terminateNow }
            backups.backupOnQuit {
                NSApp.reply(toApplicationShouldTerminate: true)
            }
            return .terminateLater
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Favourites, play history and resolved covers are the only state that
        // cannot be rebuilt by re-scanning.
        PlayStore.shared.saveNow()
    }
}
