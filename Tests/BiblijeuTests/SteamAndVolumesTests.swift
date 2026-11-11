import Foundation
import Testing
@testable import Biblijeu

@Suite("Fichiers de Steam")
struct SteamTests {

    @Test func keyValuesAreReadFromAManifest() {
        let manifest = """
        "AppState"
        {
            "appid"        "1145360"
            "name"         "Hades"
            "StateFlags"   "4"
            "installdir"   "Hades"
        }
        """
        #expect(Steam.values(of: "appid", in: manifest) == ["1145360"])
        #expect(Steam.values(of: "name", in: manifest) == ["Hades"])
        // Valve's keys are not consistently cased.
        #expect(Steam.values(of: "stateflags", in: manifest) == ["4"])
        #expect(Steam.values(of: "missing", in: manifest).isEmpty)
    }

    @Test func librariesAreListedFromLibraryfolders() {
        let list = #"""
        "libraryfolders"
        {
            "0" { "path" "/Users/someone/Library/Application Support/Steam" }
            "1" { "path" "/Volumes/Games/SteamLibrary" }
        }
        """#
        #expect(Steam.values(of: "path", in: list) == [
            "/Users/someone/Library/Application Support/Steam", "/Volumes/Games/SteamLibrary"])
    }

    @Test func binaryShortcutsAreParsed() {
        // shortcuts.vdf: table "shortcuts" > table "0" > string AppName, int appid.
        var bytes: [UInt8] = []
        func key(_ type: UInt8, _ name: String) { bytes.append(type); bytes += Array(name.utf8); bytes.append(0) }
        key(0x00, "shortcuts")
        key(0x00, "0")
        key(0x01, "AppName"); bytes += Array("Balatro".utf8); bytes.append(0)
        key(0x02, "appid"); bytes += [0x78, 0x56, 0x34, 0x12]
        bytes += [0x08, 0x08, 0x08]

        let parsed = BinaryVDF.parse(Data(bytes))
        let entry = (parsed["shortcuts"] as? [String: Any])?["0"] as? [String: Any]
        #expect(entry?["AppName"] as? String == "Balatro")
        #expect(entry?["appid"] as? UInt32 == 0x1234_5678)
    }

    @Test func truncatedBinaryDataIsRejectedNotMisread() {
        let bytes: [UInt8] = [0x00] + Array("shortcuts".utf8) + [0x00, 0x02] + Array("appid".utf8) + [0x00, 0x01]
        #expect(BinaryVDF.parse(Data(bytes)).isEmpty)
    }

    @Test func onlyFilesThatListGamesCountAsAChange() {
        let library = "/Users/someone/Library/Application Support/Steam/steamapps"
        let config = "/Users/someone/Library/Application Support/Steam/userdata/123/config"
        let roots = [library, config]
        #expect(Steam.mayChangeGameList(at: library + "/appmanifest_1145360.acf", roots: roots))
        #expect(Steam.mayChangeGameList(at: library + "/libraryfolders.vdf", roots: roots))
        #expect(Steam.mayChangeGameList(at: config + "/shortcuts.vdf", roots: roots))
        // FSEvents dropped the detail: the folder itself must be looked at.
        #expect(Steam.mayChangeGameList(at: library, roots: roots))

        // What Steam rewrites all day long.
        #expect(!Steam.mayChangeGameList(at: config + "/localconfig.vdf", roots: roots))
        #expect(!Steam.mayChangeGameList(at: library + "/shadercache/1145360/fozpipelines/a.foz", roots: roots))
        #expect(!Steam.mayChangeGameList(at: library + "/common/Hades/Content/save.sav", roots: roots))
        #expect(!Steam.mayChangeGameList(at: library + "/downloading/1145360/appmanifest_x.acf", roots: roots))
    }
}

@Suite("Disques branchés et débranchés")
struct VolumeTests {

    private let paths = ["/Volumes/Lexar/Jeux/ROM", "/Applications",
                         "/Volumes/Lexar/Jeux/Saves"]

    @Test func aDriveHoldingTheLibraryMatters() {
        #expect(LibraryModel.volume(URL(fileURLWithPath: "/Volumes/Lexar"), holdsAnyOf: paths))
    }

    @Test func aDiskImageOrAnotherDriveDoesNot() {
        #expect(!LibraryModel.volume(URL(fileURLWithPath: "/Volumes/DuckStation"), holdsAnyOf: paths))
        #expect(!LibraryModel.volume(URL(fileURLWithPath: "/Volumes/Time Machine"), holdsAnyOf: paths))
        // A name that merely starts the same is another drive.
        #expect(!LibraryModel.volume(URL(fileURLWithPath: "/Volumes/Lex"), holdsAnyOf: paths))
        #expect(!LibraryModel.volume(URL(fileURLWithPath: "/Volumes/Lexar 2"), holdsAnyOf: paths))
    }

    @Test func theStartupDiskAlwaysMatters() {
        #expect(LibraryModel.volume(URL(fileURLWithPath: "/"), holdsAnyOf: []))
    }
}
