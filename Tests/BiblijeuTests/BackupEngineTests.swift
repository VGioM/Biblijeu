import Foundation
import Testing
@testable import Biblijeu

@Suite("Copie des sauvegardes")
struct BackupEngineTests {

    private func exists(_ url: URL, _ path: String) -> Bool {
        FileManager.default.fileExists(atPath: url.appendingPathComponent(path).path)
    }

    @Test func aFolderIsCopiedThenLeftAloneWhenNothingChanged() {
        let f = Fixture(named: "Saves")
        f.file("memcards/Mcd001.ps2", "save data")
        f.file("sstates/game.p2s", "state")
        let destination = f.sibling("Backup")

        let first = BackupEngine.copy(from: f.root, to: destination)
        #expect(first.copied == 2)
        #expect(first.failures.isEmpty)
        #expect(exists(destination, "memcards/Mcd001.ps2"))

        let second = BackupEngine.copy(from: f.root, to: destination)
        #expect(second.copied == 0)
        #expect(second.identical == 2)
    }

    @Test func aChangedSaveIsCopiedAgain() throws {
        let f = Fixture(named: "Saves")
        let save = f.file("slot1.sav", "old")
        let destination = f.sibling("Backup")
        _ = BackupEngine.copy(from: f.root, to: destination)

        try Data("newer and longer".utf8).write(to: save)
        let again = BackupEngine.copy(from: f.root, to: destination)
        #expect(again.copied == 1)
        let copied = try String(contentsOf: destination.appendingPathComponent("slot1.sav"), encoding: .utf8)
        #expect(copied == "newer and longer")
    }

    @Test func symbolicLinksAreNeverFollowed() throws {
        let f = Fixture(named: "Bottle")
        f.file("drive_c/save.dat")
        // A bottle's "My Documents" points at the whole home folder.
        let outside = f.sibling("Documents")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("private".utf8).write(to: outside.appendingPathComponent("secret.txt"))
        try FileManager.default.createSymbolicLink(
            at: f.root.appendingPathComponent("drive_c/My Documents"), withDestinationURL: outside)

        let destination = f.sibling("Backup")
        _ = BackupEngine.copy(from: f.root, to: destination)
        #expect(exists(destination, "drive_c/save.dat"))
        #expect(!exists(destination, "drive_c/My Documents"))
    }

    @Test func aFilterKeepsOnlyTheSaveFormats() {
        let f = Fixture(named: "ROM")
        f.file("GBA/Pokemon.gba", String(repeating: "r", count: 100))
        f.file("GBA/Pokemon.sav")
        f.file("Switch/0100_build/huge.bin")
        f.file("Switch/0100_build/save.sav")
        let destination = f.sibling("Backup")

        let filter = BackupEngine.Filter(onlyExtensions: ["sav"], skipsWorkFolders: true)
        let outcome = BackupEngine.copy(from: f.root, to: destination, filter: filter)
        #expect(outcome.copied == 1)
        #expect(exists(destination, "GBA/Pokemon.sav"))
        #expect(!exists(destination, "GBA/Pokemon.gba"))
        #expect(!exists(destination, "Switch"))
    }

    @Test func excludedNamesAndFinderFilesAreNotCopied() {
        let f = Fixture(named: "Saves")
        f.file("keep.sav")
        f.file(".DS_Store")
        f.file("shadercache/cache.bin")
        let destination = f.sibling("Backup")

        _ = BackupEngine.copy(from: f.root, to: destination,
                              filter: BackupEngine.Filter(excluding: ["shadercache"]))
        #expect(exists(destination, "keep.sav"))
        #expect(!exists(destination, ".DS_Store"))
        #expect(!exists(destination, "shadercache"))
    }

    @Test func aBackupInsideTheSourceIsNotCopiedIntoItself() {
        let f = Fixture(named: "ROM")
        f.file("GBA/Pokemon.sav")
        let destination = f.root.appendingPathComponent("Backups")

        _ = BackupEngine.copy(from: f.root, to: destination)
        let again = BackupEngine.copy(from: f.root, to: destination)
        #expect(again.copied == 0)
        #expect(!exists(destination, "Backups"))
    }

    @Test func aMissingSourceIsReportedNotCrashed() {
        let f = Fixture(named: "Saves")
        let outcome = BackupEngine.copy(from: f.sibling("absent"), to: f.sibling("Backup"))
        #expect(outcome.copied == 0)
        #expect(outcome.failures.count == 1)
    }
}
