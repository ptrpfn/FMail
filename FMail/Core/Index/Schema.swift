import Foundation
import SQLite3

/// FMail's own SQLite schema. Versioned via `schema_version` so future
/// migrations can detect prior state and upgrade in place.
enum Schema {
    static let currentVersion: Int = 7

    /// Apply migrations to bring the DB up to `currentVersion`. Idempotent.
    static func apply(to db: OpaquePointer) throws {
        try exec(db, "PRAGMA journal_mode = WAL;")
        try exec(db, "PRAGMA synchronous = NORMAL;")
        try exec(db, "PRAGMA temp_store = MEMORY;")
        try exec(db, "PRAGMA mmap_size = 268435456;")  // 256 MB
        try exec(db, "PRAGMA foreign_keys = ON;")

        try exec(db, """
            CREATE TABLE IF NOT EXISTS schema_version (
                version INTEGER PRIMARY KEY,
                applied_at INTEGER NOT NULL
            );
        """)

        let v = currentSchemaVersion(db)
        if v < 1 { try migrateTo1(db) }
        if v < 2 { try migrateTo2(db) }
        if v < 3 { try migrateTo3(db) }
        if v < 4 { try migrateTo4(db) }
        if v < 5 { try migrateTo5(db) }
        if v < 6 { try migrateTo6(db) }
        if v < 7 { try migrateTo7(db) }
    }

    static func currentSchemaVersion(_ db: OpaquePointer) -> Int {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "SELECT MAX(version) FROM schema_version", -1, &stmt, nil) == SQLITE_OK else {
            return 0
        }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        if sqlite3_column_type(stmt, 0) == SQLITE_NULL { return 0 }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    private static func migrateTo1(_ db: OpaquePointer) throws {
        let statements = [
            """
            CREATE TABLE accounts (
                uuid TEXT PRIMARY KEY,
                display_name TEXT NOT NULL,
                email_address TEXT
            );
            """,
            """
            CREATE TABLE mailboxes (
                apple_rowid INTEGER PRIMARY KEY,
                account_uuid TEXT NOT NULL,
                path TEXT NOT NULL,
                name TEXT NOT NULL,
                hidden INTEGER NOT NULL DEFAULT 0,
                total_count INTEGER NOT NULL DEFAULT 0,
                unread_count INTEGER NOT NULL DEFAULT 0,
                kind TEXT NOT NULL DEFAULT 'other'
            );
            """,
            "CREATE INDEX idx_mailboxes_account ON mailboxes(account_uuid);",

            """
            CREATE TABLE messages (
                apple_rowid INTEGER PRIMARY KEY,
                apple_message_id_hash INTEGER NOT NULL DEFAULT 0,
                mailbox_rowid INTEGER NOT NULL,
                account_uuid TEXT NOT NULL,
                subject TEXT NOT NULL DEFAULT '',
                subject_prefix TEXT NOT NULL DEFAULT '',
                subject_normalized TEXT NOT NULL DEFAULT '',
                sender_address TEXT,
                sender_display TEXT,
                date_sent INTEGER,
                date_received INTEGER,
                is_read INTEGER NOT NULL DEFAULT 0,
                is_flagged INTEGER NOT NULL DEFAULT 0,
                has_attachment INTEGER NOT NULL DEFAULT 0,
                thread_id INTEGER NOT NULL DEFAULT 0,
                body_indexed INTEGER NOT NULL DEFAULT 0
            );
            """,
            "CREATE INDEX idx_messages_mailbox_date ON messages(mailbox_rowid, date_received DESC);",
            "CREATE INDEX idx_messages_thread ON messages(thread_id);",
            "CREATE INDEX idx_messages_hash ON messages(apple_message_id_hash) WHERE apple_message_id_hash != 0;",
            "CREATE INDEX idx_messages_account ON messages(account_uuid);",

            """
            CREATE TABLE recipients (
                message_rowid INTEGER NOT NULL,
                kind INTEGER NOT NULL,
                position INTEGER NOT NULL DEFAULT 0,
                address TEXT NOT NULL,
                display TEXT
            );
            """,
            "CREATE INDEX idx_recipients_message ON recipients(message_rowid);",

            """
            CREATE TABLE message_links (
                from_message_rowid INTEGER NOT NULL,
                to_message_id_hash INTEGER NOT NULL,
                is_parent INTEGER NOT NULL DEFAULT 0
            );
            """,
            "CREATE INDEX idx_links_to ON message_links(to_message_id_hash);",
            "CREATE INDEX idx_links_from ON message_links(from_message_rowid);",

            """
            CREATE TABLE threads (
                thread_id INTEGER PRIMARY KEY,
                root_message_rowid INTEGER NOT NULL,
                latest_date_received INTEGER NOT NULL,
                message_count INTEGER NOT NULL,
                unread_count INTEGER NOT NULL,
                flagged_count INTEGER NOT NULL DEFAULT 0
            );
            """,
            "CREATE INDEX idx_threads_latest ON threads(latest_date_received DESC);",

            // Contentless FTS5 — we manage rowid alignment with messages.apple_rowid.
            """
            CREATE VIRTUAL TABLE messages_fts USING fts5(
                subject, body_text, sender, recipients, attachment_names,
                tokenize = 'unicode61 remove_diacritics 2'
            );
            """,

            """
            CREATE TABLE index_metadata (
                key TEXT PRIMARY KEY,
                value TEXT NOT NULL
            );
            """,

            "INSERT INTO schema_version(version, applied_at) VALUES (1, strftime('%s','now'));"
        ]

        try exec(db, "BEGIN TRANSACTION;")
        do {
            for s in statements {
                try exec(db, s)
            }
            try exec(db, "COMMIT;")
        } catch {
            try? exec(db, "ROLLBACK;")
            throw error
        }
    }

    /// v7: per-account writeback service preference. Lets the user route
    /// move/delete/mark-read either through AppleScript (the default,
    /// existing behaviour) or — once authorized — through a server-direct
    /// backend (Gmail API for Gmail accounts, IMAP for the rest). Tahoe's
    /// AppleScript bridge is unreliable for mailbox-resolution operations;
    /// the server-direct path bypasses it entirely. See WRITEBACK_PLAN.md
    /// for the full plan. `service` is one of: 'applescript' (default),
    /// 'gmail_api', 'imap'. `keychain_label` points to the entry holding
    /// the relevant secret (OAuth refresh token / app-specific password);
    /// nil for 'applescript' rows.
    private static func migrateTo7(_ db: OpaquePointer) throws {
        let statements = [
            """
            CREATE TABLE account_writeback (
                account_uuid TEXT PRIMARY KEY,
                service TEXT NOT NULL DEFAULT 'applescript',
                keychain_label TEXT,
                settings_json TEXT NOT NULL DEFAULT '{}'
            );
            """,
            "INSERT INTO schema_version(version, applied_at) VALUES (7, strftime('%s','now'));"
        ]
        try exec(db, "BEGIN TRANSACTION;")
        do {
            for s in statements { try exec(db, s) }
            try exec(db, "COMMIT;")
        } catch {
            try? exec(db, "ROLLBACK;")
            throw error
        }
    }

    /// v6: mirror Apple's `messages.remote_id` (IMAP UID per canonical
    /// mailbox) so AppleScript can use `whose id is N` for O(1) lookups
    /// instead of the linear `whose message id is "..."` scan. Order-of-
    /// magnitude faster Mark as Read on big mailboxes.
    private static func migrateTo6(_ db: OpaquePointer) throws {
        let statements = [
            "ALTER TABLE messages ADD COLUMN imap_uid INTEGER;",
            "CREATE INDEX idx_messages_imap_uid ON messages(imap_uid) WHERE imap_uid IS NOT NULL;",
            "INSERT INTO schema_version(version, applied_at) VALUES (6, strftime('%s','now'));"
        ]
        try exec(db, "BEGIN TRANSACTION;")
        do {
            for s in statements { try exec(db, s) }
            try exec(db, "COMMIT;")
        } catch {
            try? exec(db, "ROLLBACK;")
            throw error
        }
    }

    /// v5: recover from a pre-fix bug where every sync wiped FTS body content.
    /// Reset `body_indexed = 0` for all messages so the body indexer re-runs
    /// and re-populates body text into FTS. The Indexer's FTS update is now
    /// incremental (only inserts new rows / removes deleted rows; existing
    /// rows are left alone) so body content survives subsequent syncs.
    private static func migrateTo5(_ db: OpaquePointer) throws {
        let statements = [
            "UPDATE messages SET body_indexed = 0;",
            "INSERT INTO schema_version(version, applied_at) VALUES (5, strftime('%s','now'));"
        ]
        try exec(db, "BEGIN TRANSACTION;")
        do {
            for s in statements { try exec(db, s) }
            try exec(db, "COMMIT;")
        } catch {
            try? exec(db, "ROLLBACK;")
            throw error
        }
    }

    /// v4: store the RFC 2822 Message-ID header on each message, joined from
    /// Apple's `message_global_data.message_id_header` (FK is
    /// `messages.global_message_id` → `message_global_data.ROWID`). Enables
    /// `message://<id>` URLs that open Mail.app at the specific message and
    /// trigger body fetch on demand.
    private static func migrateTo4(_ db: OpaquePointer) throws {
        let statements = [
            "ALTER TABLE messages ADD COLUMN rfc_message_id TEXT;",
            "CREATE INDEX idx_messages_rfc ON messages(rfc_message_id) WHERE rfc_message_id IS NOT NULL;",
            "INSERT INTO schema_version(version, applied_at) VALUES (4, strftime('%s','now'));"
        ]
        try exec(db, "BEGIN TRANSACTION;")
        do {
            for s in statements { try exec(db, s) }
            try exec(db, "COMMIT;")
        } catch {
            try? exec(db, "ROLLBACK;")
            throw error
        }
    }

    /// v3: mirror Apple's `labels` table so Gmail label-mailboxes (INBOX,
    /// Sent Mail, etc.) actually find their messages. Apple stores Gmail mail
    /// in `[Gmail]/All Mail` (canonical) and uses `labels` to map messages to
    /// their other "mailboxes."
    private static func migrateTo3(_ db: OpaquePointer) throws {
        let statements = [
            """
            CREATE TABLE message_labels (
                message_rowid INTEGER NOT NULL,
                mailbox_rowid INTEGER NOT NULL,
                PRIMARY KEY (message_rowid, mailbox_rowid)
            ) WITHOUT ROWID;
            """,
            "CREATE INDEX idx_message_labels_mailbox ON message_labels(mailbox_rowid);",
            "INSERT INTO schema_version(version, applied_at) VALUES (3, strftime('%s','now'));"
        ]
        try exec(db, "BEGIN TRANSACTION;")
        do {
            for s in statements { try exec(db, s) }
            try exec(db, "COMMIT;")
        } catch {
            try? exec(db, "ROLLBACK;")
            throw error
        }
    }

    /// v2: contact preference table (reserved; not yet read/written by code).
    private static func migrateTo2(_ db: OpaquePointer) throws {
        let statements = [
            """
            CREATE TABLE contact_prefs (
                contact_id TEXT PRIMARY KEY,
                preferred_address TEXT,
                blocked_addresses TEXT NOT NULL DEFAULT '[]'
            );
            """,
            "INSERT INTO schema_version(version, applied_at) VALUES (2, strftime('%s','now'));"
        ]
        try exec(db, "BEGIN TRANSACTION;")
        do {
            for s in statements { try exec(db, s) }
            try exec(db, "COMMIT;")
        } catch {
            try? exec(db, "ROLLBACK;")
            throw error
        }
    }

    static func exec(_ db: OpaquePointer, _ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &err)
        if rc != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "rc=\(rc)"
            sqlite3_free(err)
            throw IndexDBError.execFailed(msg)
        }
    }
}

enum IndexDBError: Error, CustomStringConvertible {
    case openFailed(String)
    case execFailed(String)
    case prepareFailed(String)
    case stepFailed(String)

    var description: String {
        switch self {
        case .openFailed(let m): return "Index DB open failed: \(m)"
        case .execFailed(let m): return "Index DB exec failed: \(m)"
        case .prepareFailed(let m): return "Index DB prepare failed: \(m)"
        case .stepFailed(let m): return "Index DB step failed: \(m)"
        }
    }
}
