import Foundation
import Testing
@testable import Biblijeu

/// A wrong answer here installs something nobody asked for, or hides an update:
/// the comparison is meant to say "unsure" rather than guess.
@Suite("Mises à jour des émulateurs")
struct UpdateCheckerTests {

    private let github = UpdateSource.github("owner/project")

    @Test func versionNumbersAreFoundInReleaseNames() {
        #expect(UpdateChecker.numbers(in: "MAME 0.289") == [0, 289])
        #expect(UpdateChecker.numbers(in: "Snes9x 1.63") == [1, 63])
        #expect(UpdateChecker.numbers(in: "1.0.27+e70414f92") == [1, 0, 27])
        #expect(UpdateChecker.numbers(in: "v148") == [148])
        #expect(UpdateChecker.numbers(in: "Latest Rolling Release") == nil)
        // A commit hash or a date-stamped build is not "version 1".
        #expect(UpdateChecker.numbers(in: "KytyPS5-2026-09-14-a9ae04c") == nil)
    }

    @Test func aNewerReleaseIsAvailable() {
        #expect(UpdateChecker.compare(installed: "2.5", latest: "v2.6", from: github) == .available)
        #expect(UpdateChecker.compare(installed: "1.0.27", latest: "1.0.32", from: github) == .available)
        #expect(UpdateChecker.compare(installed: "0.9.9", latest: "0.10.0", from: github) == .available)
    }

    @Test func theSameReleaseIsUpToDate() {
        #expect(UpdateChecker.compare(installed: "2.6", latest: "2.6", from: github) == .upToDate)
        #expect(UpdateChecker.compare(installed: "2.6", latest: "v2.6.0", from: github) == .upToDate)
        #expect(UpdateChecker.compare(installed: "V1.2", latest: "v1.2", from: github) == .upToDate)
    }

    @Test func runningANightlyAheadOfTheReleaseIsNotOutOfDate() {
        #expect(UpdateChecker.compare(installed: "2.7.1", latest: "2.7.0", from: github) == .upToDate)
    }

    @Test func numbersCountedDifferentlyAreNotCompared() {
        // Azahar's "2126.2" and a "1.0.5" are not on the same scale at all.
        #expect(UpdateChecker.compare(installed: "2126.2", latest: "1.0.5", from: github) == .unsure)
        #expect(UpdateChecker.compare(installed: nil, latest: "1.0", from: github) == .unsure)
        #expect(UpdateChecker.compare(installed: "", latest: "1.0", from: github) == .unsure)
        #expect(UpdateChecker.compare(installed: "nightly", latest: "1.0", from: github) == .unsure)
    }

    @Test func aMacBuildIsPickedAmongAReleasesFiles() {
        let picked = UpdateChecker.macAsset(among: [
            "cemu-2.6-windows-x64.zip",
            "cemu-2.6-ubuntu-22.04-x64.zip",
            "Cemu-2.6-x86_64.AppImage",
            "cemu-2.6-macos-12-x64.dmg",
            "cemu-2.6-macos.dSYM.zip",
            "sha256sums.txt",
        ])
        #expect(picked == "cemu-2.6-macos-12-x64.dmg")
    }

    @Test func noMacBuildMeansNoPick() {
        #expect(UpdateChecker.macAsset(among: ["game-windows.zip", "game-linux.tar.gz",
                                                "source.tar.gz"]) == nil)
        #expect(UpdateChecker.macAsset(among: []) == nil)
    }
}
