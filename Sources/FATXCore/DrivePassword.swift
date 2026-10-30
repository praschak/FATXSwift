import Foundation

public enum DrivePassword {
    public static func derive(key: Data, identify: Data, serialFirst: Bool = false) throws -> Data {
        try require(key.count == 16, "HDD key must contain exactly 16 bytes")
        try require(identify.count == 512, "ATA IDENTIFY data must contain exactly 512 bytes")
        let bytes = Array(identify)
        let configuration = UInt16(bytes[0]) | UInt16(bytes[1]) << 8
        try require(configuration != 0 && configuration != 0xffff && configuration & 0x8000 == 0, "Invalid or unsupported ATA IDENTIFY response")
        func field(_ range: Range<Int>) throws -> [UInt8] {
            var result: [UInt8] = []
            for i in stride(from: range.lowerBound, to: range.upperBound, by: 2) { result += [bytes[i + 1], bytes[i]] }
            while result.last == 0x20 { result.removeLast() }
            try require(!result.isEmpty, "ATA model and serial fields must not be empty")
            return result
        }
        let model = try field(54..<94), serial = try field(20..<40)
        return Data(LegacyCrypto.hmacSHA1(key: Array(key), message: serialFirst ? serial + model : model + serial) + Array(repeating: 0, count: 12))
    }
}
// Legacy algorithms required by the on-device format; no device commands are sent.
enum LegacyCrypto {
    static func sha1(_ input: [UInt8]) -> [UInt8] {
        var message = input
        let bitLength = UInt64(message.count) * 8
        message.append(0x80)
        while message.count % 64 != 56 { message.append(0) }
        for shift in stride(from: 56, through: 0, by: -8) { message.append(UInt8(truncatingIfNeeded: bitLength >> shift)) }
        func rotate(_ x: UInt32, _ n: Int) -> UInt32 { (x << n) | (x >> (32 - n)) }
        var hash: [UInt32] = [0x67452301,0xefcdab89,0x98badcfe,0x10325476,0xc3d2e1f0]
        for offset in stride(from: 0, to: message.count, by: 64) {
            var w = [UInt32](repeating: 0, count: 80)
            for i in 0..<16 { for byte in message[offset + i * 4..<offset + i * 4 + 4] { w[i] = w[i] << 8 | UInt32(byte) } }
            for i in 16..<80 { w[i] = rotate(w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16], 1) }
            var a = hash[0], b = hash[1], c = hash[2], d = hash[3], e = hash[4]
            for i in 0..<80 {
                let f: UInt32, k: UInt32
                switch i {
                case 0..<20: f = (b & c) | (~b & d); k = 0x5a827999
                case 20..<40: f = b ^ c ^ d; k = 0x6ed9eba1
                case 40..<60: f = (b & c) | (b & d) | (c & d); k = 0x8f1bbcdc
                default: f = b ^ c ^ d; k = 0xca62c1d6
                }
                let next = rotate(a, 5) &+ f &+ e &+ k &+ w[i]
                e = d; d = c; c = rotate(b, 30); b = a; a = next
            }
            for (i, value) in [a,b,c,d,e].enumerated() { hash[i] = hash[i] &+ value }
        }
        return hash.flatMap { word in [24,16,8,0].map { UInt8(truncatingIfNeeded: word >> $0) } }
    }
    static func hmacSHA1(key: [UInt8], message: [UInt8]) -> [UInt8] {
        var k = key.count > 64 ? sha1(key) : key
        k += Array(repeating: 0, count: 64 - k.count)
        return sha1(k.map { $0 ^ 0x5c } + sha1(k.map { $0 ^ 0x36 } + message))
    }

}
