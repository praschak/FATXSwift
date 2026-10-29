import Foundation

public struct FATXError: Error, CustomStringConvertible {
    public let description: String
    public init(_ message: String) { description = message }
}
func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw FATXError(message) }
}
public enum ByteOrder: String, Codable { case little, big }
extension Data {
    func number(_ at: Int, _ width: Int, _ order: ByteOrder) -> UInt32 {
        var value: UInt32 = 0
        for i in 0..<width {
            let shift = order == .little ? i * 8 : (width - i - 1) * 8
            value |= UInt32(self[at + i]) << shift
        }
        return value
    }
    mutating func put(_ value: UInt32, _ at: Int, _ width: Int, _ order: ByteOrder) {
        for i in 0..<width {
            let shift = order == .little ? i * 8 : (width - i - 1) * 8
            self[at + i] = UInt8(truncatingIfNeeded: value >> shift)
        }
    }
}
func folded(_ bytes: Data) -> Data { Data(bytes.map { (65...90).contains($0) ? $0 + 32 : $0 }) }
func nameBytes(_ name: String) throws -> Data {
    let bytes = Data(name.utf8)
    try require(!bytes.isEmpty && bytes.count <= 42 && bytes.allSatisfy { $0 < 127 }, "New names must contain 1–42 ASCII bytes")
    try validateName(bytes)
    try require(bytes.last != 32 && bytes.last != 46, "Names cannot end with a space or dot")
    return bytes
}
func validateName(_ bytes: Data) throws {
    let forbidden = Data("\"*+,/:;<=>?\\|".utf8)
    try require(!bytes.isEmpty && bytes.count <= 42 && bytes != Data(".".utf8) && bytes != Data("..".utf8), "Invalid FATX name")
    try require(bytes.allSatisfy { $0 >= 32 && !forbidden.contains($0) }, "Invalid FATX name byte")
}
func components(_ path: String) throws -> [String] {
    try require(path.hasPrefix("/"), "FATX paths must be absolute (start with /)")
    let parts = path.split(separator: "/").map(String.init)
    try require(!parts.contains(".") && !parts.contains(".."), "Dot path components are not supported")
    return parts
}
