import Foundation
import SQLite3

/// Per-account writeback-service preferences. Read/write helpers for the
/// `account_writeback` table (Schema v7). Used by `WritebackRouter` to
/// decide which backend (AppleScript / Gmail API / IMAP) handles a given
/// account's writes.
extension IndexDB {

    /// One row from `account_writeback`. `keychainLabel` is nil for the
    /// AppleScript default (no credentials needed).
    struct WritebackPreference: Sendable, Hashable {
        let accountUUID: String
        let service: WritebackKind
        let keychainLabel: String?
        let settingsJSON: String  // raw JSON string; parsed per-service
    }

    /// Fetch the preference for one account. Returns nil when no row exists
    /// (caller treats nil as "use AppleScript default"). Unknown service
    /// values fall back to `.applescript` so a typo'd row never wedges the
    /// router.
    func writebackPreference(accountUUID: String) throws -> WritebackPreference? {
        var stmt: OpaquePointer?
        try prepare("""
            SELECT account_uuid, service, keychain_label, settings_json
            FROM account_writeback
            WHERE account_uuid = ?
            """, into: &stmt)
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, accountUUID)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        let uuid = String(cString: sqlite3_column_text(stmt, 0))
        let serviceRaw = String(cString: sqlite3_column_text(stmt, 1))
        let service = WritebackKind(rawValue: serviceRaw) ?? .applescript
        let label = sqlite3_column_text(stmt, 2).map { String(cString: $0) }
        let settings = sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? "{}"
        return WritebackPreference(
            accountUUID: uuid, service: service,
            keychainLabel: label, settingsJSON: settings
        )
    }

    /// Bulk fetch — returns one entry per requested UUID that has a row.
    /// Missing UUIDs are absent from the map (caller defaults them).
    func writebackPreferences(accountUUIDs: [String]) throws -> [String: WritebackPreference] {
        guard !accountUUIDs.isEmpty else { return [:] }
        let placeholders = accountUUIDs.map { _ in "?" }.joined(separator: ",")
        var stmt: OpaquePointer?
        try prepare("""
            SELECT account_uuid, service, keychain_label, settings_json
            FROM account_writeback
            WHERE account_uuid IN (\(placeholders))
            """, into: &stmt)
        defer { sqlite3_finalize(stmt) }
        for (i, uuid) in accountUUIDs.enumerated() {
            bind(stmt, Int32(i + 1), uuid)
        }
        var out: [String: WritebackPreference] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            let uuid = String(cString: sqlite3_column_text(stmt, 0))
            let serviceRaw = String(cString: sqlite3_column_text(stmt, 1))
            let service = WritebackKind(rawValue: serviceRaw) ?? .applescript
            let label = sqlite3_column_text(stmt, 2).map { String(cString: $0) }
            let settings = sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? "{}"
            out[uuid] = WritebackPreference(
                accountUUID: uuid, service: service,
                keychainLabel: label, settingsJSON: settings
            )
        }
        return out
    }

    /// Upsert. Used by the B1 Settings UI when the user authorizes a Gmail
    /// account or configures IMAP credentials. Settings can be partially
    /// specified — pass nil to leave the column unchanged on update.
    func setWritebackPreference(
        accountUUID: String,
        service: WritebackKind,
        keychainLabel: String?,
        settingsJSON: String = "{}"
    ) throws {
        var stmt: OpaquePointer?
        try prepare("""
            INSERT INTO account_writeback(account_uuid, service, keychain_label, settings_json)
            VALUES (?, ?, ?, ?)
            ON CONFLICT(account_uuid) DO UPDATE SET
                service = excluded.service,
                keychain_label = excluded.keychain_label,
                settings_json = excluded.settings_json
            """, into: &stmt)
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, accountUUID)
        bind(stmt, 2, service.rawValue)
        bindOptional(stmt, 3, keychainLabel)
        bind(stmt, 4, settingsJSON)
        try stepDone(stmt)
    }

    /// Drop the row (back to AppleScript default). Used when the user
    /// revokes server access for an account.
    func clearWritebackPreference(accountUUID: String) throws {
        var stmt: OpaquePointer?
        try prepare("DELETE FROM account_writeback WHERE account_uuid = ?", into: &stmt)
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, accountUUID)
        try stepDone(stmt)
    }

    /// Bulk resolve message rowids → `MessageRef`s with all the fields the
    /// writeback services need. One SQL joining messages × mailboxes ×
    /// accounts. Missing rowids (deleted between MCP call and resolve) are
    /// absent from the result.
    func resolveMessageRefs(rowids: [Int]) throws -> [Int: MessageRef] {
        guard !rowids.isEmpty else { return [:] }
        let placeholders = rowids.map { _ in "?" }.joined(separator: ",")
        let sql = """
        SELECT m.apple_rowid, m.account_uuid, a.email_address,
               m.imap_uid, COALESCE(mb.path, ''), m.rfc_message_id
        FROM messages m
        LEFT JOIN mailboxes mb ON mb.apple_rowid = m.mailbox_rowid
        LEFT JOIN accounts a ON a.uuid = m.account_uuid
        WHERE m.apple_rowid IN (\(placeholders))
        """
        var stmt: OpaquePointer?
        try prepare(sql, into: &stmt)
        defer { sqlite3_finalize(stmt) }
        for (i, rowid) in rowids.enumerated() {
            bind(stmt, Int32(i + 1), Int64(rowid))
        }
        var out: [Int: MessageRef] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            let rowid = Int(sqlite3_column_int64(stmt, 0))
            let accountUUID = String(cString: sqlite3_column_text(stmt, 1))
            let email = sqlite3_column_text(stmt, 2).map { String(cString: $0) }
            let uidVal = sqlite3_column_int64(stmt, 3)
            let uid: Int? = sqlite3_column_type(stmt, 3) == SQLITE_NULL ? nil : Int(uidVal)
            let path = sqlite3_column_text(stmt, 4).map { String(cString: $0) } ?? ""
            let pathComponents: [String]? = path.isEmpty ? nil : path.split(separator: "/").map(String.init)
            let rfcId = sqlite3_column_text(stmt, 5).map { String(cString: $0) }
            out[rowid] = MessageRef(
                accountID: accountUUID,
                accountEmail: email,
                appleRowId: rowid,
                imapUID: uid,
                imapFolderPath: pathComponents,
                rfcMessageId: rfcId,
                gmailMessageId: nil,  // Phase B1 populates from Gmail API
                keychainLabel: nil    // router enriches from account_writeback prefs
            )
        }
        return out
    }
}
