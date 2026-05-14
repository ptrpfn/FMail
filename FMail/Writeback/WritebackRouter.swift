import Foundation

/// Per-account dispatcher for write operations. Resolves rowids to
/// `MessageRef`s via `IndexDB`, looks up each account's service preference,
/// groups by service, and dispatches each group to the appropriate
/// `WritebackService`. Merges per-message results back into a single
/// `WritebackResult`.
///
/// Default service when an account has no `account_writeback` row is
/// `.applescript` — preserving today's behaviour until the user explicitly
/// configures something else in Settings (Phase B1+).
///
/// The router is a value type (struct) because all of its dependencies are
/// either Sendable services or the `IndexDB` actor — there's no internal
/// mutable state. Hop into the router's methods from any context.
struct WritebackRouter: Sendable {
    let indexDB: IndexDB
    /// Service per backend kind. Keep keys aligned with `WritebackKind`
    /// cases; the router falls back to `.applescript` for anything missing.
    let services: [WritebackKind: any WritebackService]

    init(
        indexDB: IndexDB,
        services: [WritebackKind: any WritebackService] = WritebackRouter.defaultServices()
    ) {
        self.indexDB = indexDB
        self.services = services
    }

    /// Production default — the three real services. Tests inject mocks
    /// that record calls instead.
    static func defaultServices() -> [WritebackKind: any WritebackService] {
        [
            .applescript: AppleScriptWritebackService(),
            .gmailApi: GmailAPIWritebackService(),
            .imap: IMAPWritebackService()
        ]
    }

    func setReadStatus(rowids: [Int], isRead: Bool) async -> WritebackResult {
        await run(rowids: rowids) { service, refs in
            await service.setReadStatus(refs, isRead: isRead)
        }
    }

    func moveToJunk(rowids: [Int]) async -> WritebackResult {
        await run(rowids: rowids) { service, refs in
            await service.moveToJunk(refs)
        }
    }

    func delete(rowids: [Int]) async -> WritebackResult {
        await run(rowids: rowids) { service, refs in
            await service.delete(refs)
        }
    }

    // MARK: — Internals

    /// Shared pipeline: resolve refs → group by service → dispatch each
    /// group → merge. The per-operation closure performs the actual
    /// service call.
    private func run(
        rowids: [Int],
        _ operation: @Sendable (any WritebackService, [MessageRef]) async -> WritebackResult
    ) async -> WritebackResult {
        guard !rowids.isEmpty else { return WritebackResult.empty() }

        // 1. Resolve rowids → MessageRefs.
        let refsByRowid: [Int: MessageRef]
        do {
            refsByRowid = try await indexDB.resolveMessageRefs(rowids: rowids)
        } catch {
            var fail = WritebackResult.empty()
            fail.error = "Failed to resolve messages: \(error)"
            for rowid in rowids {
                fail.perMessage[rowid] = .failed("resolve failed")
            }
            return fail
        }

        // Build the result skeleton with `.notFound` for any rowid that
        // didn't resolve. Services will overwrite with actual outcomes.
        var combined = WritebackResult.empty()
        for rowid in rowids where refsByRowid[rowid] == nil {
            combined.perMessage[rowid] = .notFound
        }
        let refs = refsByRowid.values
        guard !refs.isEmpty else { return combined }

        // 2. Look up per-account service preferences.
        let accountUUIDs = Array(Set(refs.map(\.accountID)))
        let prefs: [String: IndexDB.WritebackPreference]
        do {
            prefs = try await indexDB.writebackPreferences(accountUUIDs: accountUUIDs)
        } catch {
            prefs = [:]  // fall back to defaults
        }

        // 3. Group by service kind. Enrich each ref with its account's
        //    Keychain label so the Gmail/IMAP services don't need their
        //    own IndexDB hop to find credentials.
        var byService: [WritebackKind: [MessageRef]] = [:]
        for ref in refs {
            let pref = prefs[ref.accountID]
            let kind = pref?.service ?? .applescript
            let enriched = MessageRef(
                accountID: ref.accountID,
                accountEmail: ref.accountEmail,
                appleRowId: ref.appleRowId,
                imapUID: ref.imapUID,
                imapFolderPath: ref.imapFolderPath,
                rfcMessageId: ref.rfcMessageId,
                gmailMessageId: ref.gmailMessageId,
                keychainLabel: pref?.keychainLabel
            )
            byService[kind, default: []].append(enriched)
        }

        // 4. Dispatch each group; merge.
        for (kind, group) in byService {
            let service = service(for: kind)
            let partial = await operation(service, group)
            combined.merge(partial)
        }
        return combined
    }

    private func service(for kind: WritebackKind) -> any WritebackService {
        // Fall back to AppleScript when a kind isn't registered (defensive
        // — `defaultServices()` populates all three).
        services[kind] ?? services[.applescript] ?? AppleScriptWritebackService()
    }
}
