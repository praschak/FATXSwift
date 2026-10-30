import Foundation
import Security
import FATXCore

/// Local named credentials. The secret itself is stored only in the login keychain.
struct HDDKeyStore {
    private static let service = "com.fatxswift.browser.hdd-keys"
    private static var base: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
    }
    private static func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else {
            throw FATXError("Keychain error: \(SecCopyErrorMessageString(status, nil) as String? ?? String(status))")
        }
    }
    static func names() throws -> [String] {
        var query = base
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        try check(status)
        guard let items = result as? [[String: Any]] else { throw FATXError("Unexpected Keychain response") }
        return items.compactMap { $0[kSecAttrAccount as String] as? String }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
    static func get(_ name: String) throws -> Data {
        var query = base
        query[kSecAttrAccount as String] = name
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        try check(SecItemCopyMatching(query as CFDictionary, &result))
        guard let key = result as? Data, key.count == 16 else { throw FATXError("Saved HDD key is invalid") }
        return key
    }
    static func save(_ name: String, key: Data) throws {
        guard !name.isEmpty, key.count == 16 else { throw FATXError("Enter a name and a 16-byte HDD key") }
        var query = base
        query[kSecAttrAccount as String] = name
        // Add only; never silently overwrite a different saved key.
        query[kSecValueData as String] = key
        query[kSecAttrLabel as String] = "FATX Browser HDD Key: " + name
        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecDuplicateItem { throw FATXError("A key with this name already exists. Choose another name or delete the saved key first.") }
        try check(status)
    }
    static func delete(_ name: String) throws {
        var query = base
        query[kSecAttrAccount as String] = name
        try check(SecItemDelete(query as CFDictionary))
    }
}
