import Foundation

// IEEE CRC32 guards journal addresses, lengths, and payloads against corruption.
// It is an integrity checksum, not authentication of an untrusted journal.
enum CRC32 {
    static let table: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 { value = value & 1 != 0 ? (value >> 1) ^ 0xedb88320 : value >> 1 }
        return value
    }
    static func checksum(_ parts: Data...) -> UInt32 {
        var crc: UInt32 = 0xffffffff
        for part in parts { for byte in part { crc = (crc >> 8) ^ table[Int((crc ^ UInt32(byte)) & 255)] } }
        return crc ^ 0xffffffff
    }
}
