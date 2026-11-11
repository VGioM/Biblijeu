import Foundation
import Testing
@testable import Biblijeu

@Suite("Analyse des dossiers de ROM")
struct RomScannerTests {

    private func scan(_ fixture: Fixture) -> [GameItem] {
        RomScanner.scan(roots: [fixture.root], progress: { _ in })
    }

    private func titles(_ items: [GameItem]) -> Set<String> { Set(items.map(\.title)) }

    @Test func theFolderDecidesBetweenConsolesSharingAnExtension() {
        let f = Fixture()
        f.file("PS2/Shadow of the Colossus (Europe).iso")
        f.file("GameCube/Pikmin (Europe).iso")
        f.file("Wii/Zelda Twilight Princess.iso")
        let bySystem = Dictionary(uniqueKeysWithValues: scan(f).map { ($0.title, $0.systemID) })
        #expect(bySystem["Shadow of the Colossus"] == "ps2")
        #expect(bySystem["Pikmin"] == "gc")
        #expect(bySystem["Zelda Twilight Princess"] == "wii")
    }

    @Test func anAmbiguousFileOutsideAConsoleFolderIsLeftOut() {
        let f = Fixture()
        f.file("Something.iso")   // PS2, GameCube, Wii, PSP... no way to tell
        f.file("notes.md")        // a Mega Drive extension, but a README
        #expect(scan(f).isEmpty)
    }

    @Test func aFormatOnlyOneConsoleUsesNeedsNoFolder() {
        let f = Fixture()
        f.file("Super Mario 64 (USA).z64")
        let items = scan(f)
        #expect(items.count == 1)
        #expect(items.first?.systemID == "n64")
    }

    @Test func aCueSheetHidesItsTracks() {
        let f = Fixture()
        f.file("PS1/Tekken 3 (Europe).cue", #"FILE "Tekken 3 (Europe) (Track 1).bin" BINARY"#)
        f.file("PS1/Tekken 3 (Europe) (Track 1).bin", String(repeating: "x", count: 700))
        let items = scan(f)
        #expect(items.count == 1)
        #expect(items.first?.url.pathExtension == "cue")
        // The size is the tracks', not the hundred bytes of the sheet.
        #expect((items.first?.fileSize ?? 0) >= 700)
    }

    @Test func discsOfOneGameMakeOneTile() {
        let f = Fixture()
        for disc in 1...3 {
            f.file("PS1/Final Fantasy VII (France) (Disc \(disc)).chd")
        }
        let items = scan(f)
        #expect(items.count == 1)
        #expect(items.first?.discs.count == 3)
        #expect(items.first?.discs.first?.lastPathComponent == "Final Fantasy VII (France) (Disc 1).chd")
    }

    @Test func updatesDLCAndBuildFoldersAreNotEntered() {
        let f = Fixture()
        f.file("Switch/Updates/Game Update.nsp")
        f.file("Switch/DLC/Game DLC.nsp")
        f.file("Switch/0100ABCD_build/romfs.iso")
        f.file("Switch/nxnative-build.noindex/game.nsp")
        f.file("N64/saves/Mario.z64")
        #expect(scan(f).isEmpty)
    }

    @Test func aZipCountsOnlyInAnArcadeFolder() {
        let f = Fixture()
        f.file("Downloads/emulator-source.zip")
        f.file("MAME/pacman.zip")
        let items = scan(f)
        #expect(items.count == 1)
        #expect(items.first?.systemID == "arcade")
    }

    @Test func anInstalledWindowsGameIsOneTileNotItsAssets() {
        let f = Fixture()
        f.file("PC/Obsidian Quest/ObsidianQuest.exe")
        f.file("PC/Obsidian Quest/unins000.exe")
        f.file("PC/Obsidian Quest/data/maps/level01.wad")
        f.file("PC/Obsidian Quest/data/maps/level02.wad")
        let items = scan(f)
        #expect(items.count == 1)
        #expect(items.first?.systemID == "windows")
        #expect(items.first?.url.lastPathComponent == "ObsidianQuest.exe")
    }

    @Test func macOSMetadataFilesAreIgnored() {
        let f = Fixture()
        f.file("N64/._Super Mario 64.z64")
        #expect(scan(f).isEmpty)
    }

    @Test func excludedFoldersAreSkipped() {
        let f = Fixture()
        f.file("N64/Mario.z64")
        f.file("Archive/N64/Zelda.z64")
        let items = RomScanner.scan(roots: [f.root],
                                    excluded: [f.root.appendingPathComponent("Archive").path],
                                    progress: { _ in })
        #expect(titles(items) == ["Mario"])
    }

    @Test func aMissingRootIsNotAnError() {
        let items = RomScanner.scan(roots: [URL(fileURLWithPath: "/Volumes/Biblijeu-absent/ROM")],
                                    progress: { _ in })
        #expect(items.isEmpty)
    }

    // MARK: - Folder watching

    @Test func changesInFoldersTheScanSkipsAreIgnored() {
        let root = "/Volumes/Lexar/ROM"
        let roots = [root]
        #expect(RomScanner.ignoresChange(at: root + "/Switch/0100_build/a/b.bin", roots: roots, excluded: []))
        #expect(RomScanner.ignoresChange(at: root + "/N64/saves/mario.eep", roots: roots, excluded: []))
        #expect(RomScanner.ignoresChange(at: root + "/Mac/Game.app/Contents/Info.plist", roots: roots, excluded: []))
        #expect(RomScanner.ignoresChange(at: root + "/Old/x.z64", roots: roots, excluded: [root + "/Old"]))
        #expect(!RomScanner.ignoresChange(at: root + "/N64/Zelda.z64", roots: roots, excluded: []))
    }
}
