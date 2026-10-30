import XCTest
@testable import FATXCore
final class DrivePasswordTests: XCTestCase {
    func hex(_ s: String) -> [UInt8] { stride(from: 0, to: s.count, by: 2).map { i in let x = s.index(s.startIndex, offsetBy: i); return UInt8(s[x..<s.index(x, offsetBy: 2)], radix: 16)! } }
    func testStandardVectors() {
        XCTAssertEqual(LegacyCrypto.sha1(Array("abc".utf8)), hex("a9993e364706816aba3e25717850c26c9cd0d89d"))
        XCTAssertEqual(LegacyCrypto.hmacSHA1(key: Array(repeating: 0x0b, count: 20), message: Array("Hi There".utf8)), hex("b617318655057264e28bc0b6fb378c8ef146be00"))
    }
    func testDriveIdentityDerivation() throws {
        var identity = Data(repeating: 0, count: 512); identity[0] = 0x40
        for (start, size, field) in [(54,40,"Test SSD"),(20,20,"SERIAL123")] {
            let bytes = Array(field.utf8) + Array(repeating: UInt8(32), count: size - field.utf8.count)
            for i in stride(from: 0, to: size, by: 2) { identity[start+i] = bytes[i+1]; identity[start+i+1] = bytes[i] }
        }
        XCTAssertEqual(try DrivePassword.derive(key: Data(0..<16), identify: identity), Data(hex("489dc66f4f9a90d7e38a6eb45ded77aa6e8c66e3000000000000000000000000")))
        XCTAssertEqual(try DrivePassword.derive(key: Data(0..<16), identify: identity, serialFirst: true), Data(hex("5614b260024dcf5b67f7db704e13134bea1182b0000000000000000000000000")))
        XCTAssertThrowsError(try DrivePassword.derive(key: Data(repeating: 0, count: 15), identify: identity))
        XCTAssertThrowsError(try DrivePassword.derive(key: Data(0..<16), identify: Data(repeating: 0, count: 512)))
    }
}
