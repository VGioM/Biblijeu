import Foundation
import Testing
@testable import Biblijeu

@Suite("Noms de ROM")
struct NameParserTests {

    @Test func dumpAttributesAreStrippedAndKept() {
        let parsed = NameParser.parse(name: "Legend of Zelda, The - Ocarina of Time (Europe) (En,Fr,De) (Rev 1)")
        #expect(parsed.title == "The Legend of Zelda - Ocarina of Time")
        #expect(parsed.region == "Europe")
        #expect(parsed.languages == ["EN", "FR", "DE"])
        #expect(parsed.revision == "Rev 1")
        #expect(parsed.raw == "Legend of Zelda, The - Ocarina of Time (Europe) (En,Fr,De) (Rev 1)")
    }

    @Test func regionsAreReadInFrench() {
        #expect(NameParser.parse(name: "Pokemon Emerald (USA)").region == "États-Unis")
        #expect(NameParser.parse(name: "Pokemon Emerald (Japan)").region == "Japon")
    }

    @Test func discNumbersAreRead() {
        #expect(NameParser.parse(name: "Final Fantasy VII (France) (Disc 2)").disc == 2)
        #expect(NameParser.parse(name: "Metal Gear Solid (CD 1)").disc == 1)
        #expect(NameParser.parse(name: "Tekken 3 (Europe)").disc == nil)
    }

    @Test func hyphenatedDumpNamesAreUnpacked() {
        let parsed = NameParser.parse(name: "Super-Mario-Sunshine-Europe-En-Fr-De")
        #expect(parsed.title == "Super Mario Sunshine")
        #expect(parsed.region == "Europe")
        #expect(parsed.languages == ["EN", "FR", "DE"])
    }

    @Test func titleIDsAreDropped() {
        let parsed = NameParser.parse(name: "Celeste [01002B30028F6000]")
        #expect(parsed.title == "Celeste")
        #expect(parsed.tags.isEmpty)
    }

    @Test func underscoresBecomeSpaces() {
        #expect(NameParser.parse(name: "Sonic_the_Hedgehog (World)").title == "Sonic the Hedgehog")
    }

    @Test func normalizingIgnoresCaseAccentsAndPunctuation() {
        #expect(NameParser.normalize("Pokémon: Édition Rouge!") == "pokemon edition rouge")
        #expect(NameParser.normalizedCore("Tekken 3 (Europe) [b]") == NameParser.normalizedCore("TEKKEN 3 (USA)"))
    }

    @Test func tokensLeaveOutStopWords() {
        #expect(NameParser.tokens("The Legend of Zelda") == ["legend", "zelda"])
    }
}
