import XCTest
@testable import ReSignKit

final class MachOInspectTests: XCTestCase {
    func testCryptidParsingDetectsEncrypted() {
        let enc = """
                  cmd LC_ENCRYPTION_INFO_64
              cmdsize 24
             cryptoff 16384
            cryptsize 32768
               cryptid 1
        """
        let dec = enc.replacingOccurrences(of: "cryptid 1", with: "cryptid 0")
        XCTAssertTrue(MachOInspect.cryptidIsEncrypted(otoolLoadCommands: enc))
        XCTAssertFalse(MachOInspect.cryptidIsEncrypted(otoolLoadCommands: dec))
        XCTAssertFalse(MachOInspect.cryptidIsEncrypted(otoolLoadCommands: "（无加密段）"))
    }
    func testLoadDylibsParsing() {
        let s = """
                  cmd LC_LOAD_DYLIB
                 name @rpath/CydiaSubstrate (offset 24)
                  cmd LC_LOAD_DYLIB
                 name /usr/lib/libSystem.B.dylib (offset 24)
        """
        XCTAssertEqual(MachOInspect.loadDylibs(otoolLoadCommands: s),
                       ["@rpath/CydiaSubstrate", "/usr/lib/libSystem.B.dylib"])
    }
}
