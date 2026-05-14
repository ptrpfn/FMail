import Foundation
import Security

/// Minimal generic-password Keychain helper. Stores secrets keyed by a
/// caller-chosen label string. Used for:
///   - Gmail OAuth refresh tokens (label: `com.felixmatschke.FMail.gmail.<email>`)
///   - IMAP app-specific passwords (label: `com.felixmatschke.FMail.imap.<email>`)
///
/// We use a single keychain service (`com.felixmatschke.FMail`) and the
/// label as the account name within that service. Each FMail account gets
/// one entry; updating overwrites in place.
enum Keychain {
    private static let service = "com.felixmatschke.FMail"

    /// Read the raw bytes stored under `label`. Returns nil when no entry
    /// exists. Throws on actual Keychain errors (locked / permission).
    static func read(label: String) throws -> Data? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: label,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]
        var item: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            return item as? Data
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.osStatus(status)
        }
    }

    /// Upsert. If an entry with the same label exists, it's overwritten.
    static func write(label: String, data: Data) throws {
        // Try update first; if missing, insert.
        let attributes: [CFString: Any] = [kSecValueData: data]
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: label
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var insert = query
            insert[kSecValueData] = data
            insert[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlock
            let insertStatus = SecItemAdd(insert as CFDictionary, nil)
            if insertStatus != errSecSuccess {
                throw KeychainError.osStatus(insertStatus)
            }
        default:
            throw KeychainError.osStatus(updateStatus)
        }
    }

    /// Convenience for UTF-8 string secrets.
    static func writeString(label: String, _ string: String) throws {
        try write(label: label, data: Data(string.utf8))
    }

    /// Convenience: returns nil when no entry; throws on decode failure.
    static func readString(label: String) throws -> String? {
        guard let data = try read(label: label) else { return nil }
        guard let s = String(data: data, encoding: .utf8) else {
            throw KeychainError.malformedUTF8
        }
        return s
    }

    /// Delete. Returns true when an entry existed and was removed; false
    /// when nothing was there (idempotent semantics).
    @discardableResult
    static func delete(label: String) throws -> Bool {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: label
        ]
        let status = SecItemDelete(query as CFDictionary)
        switch status {
        case errSecSuccess: return true
        case errSecItemNotFound: return false
        default: throw KeychainError.osStatus(status)
        }
    }
}

enum KeychainError: Error, CustomStringConvertible {
    case osStatus(OSStatus)
    case malformedUTF8

    var description: String {
        switch self {
        case .osStatus(let s):
            let msg = SecCopyErrorMessageString(s, nil) as String? ?? "OSStatus \(s)"
            return "Keychain error: \(msg)"
        case .malformedUTF8:
            return "Keychain value is not valid UTF-8"
        }
    }
}
