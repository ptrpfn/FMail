import Foundation

/// `get_attachment` and `get_attachments_for_rowids` — attachment-byte
/// access by message rowid + attachment index. Two output modes:
///
///   1. `save_to_path` set → bytes are written to that filesystem path,
///      and the response contains only metadata + `saved_path`. Use this
///      for non-trivial PDFs / images: base64-in-JSON inflates payload
///      ~33% and pushes anything above ~150 KB past most MCP clients'
///      per-call result-size cap.
///   2. `save_to_path` unset → bytes returned base64-encoded in
///      `data_base64`, capped by `max_bytes` (default 10 MB).
///
/// The bulk variant takes a list of rowids and a `save_dir`. For each
/// rowid it writes every attachment to `save_dir/<rowid>/<filename>`
/// and returns one row per attachment (success + error variants).
extension MCPHandlers {

    // MARK: — get_attachment

    static func getAttachment(_ args: JSONValue, context: MCPContext) async throws -> JSONValue {
        guard let obj = args.objectValue,
              let rowid = obj["rowid"]?.intValue,
              let attIdx = obj["attachment_index"]?.intValue
        else {
            throw JSONRPCErrorPayload(
                code: JSONRPCErrorCode.invalidParams,
                message: "get_attachment: `rowid` (integer) and `attachment_index` (integer) are required"
            )
        }
        let savePath = obj["save_to_path"]?.stringValue?.trimmingCharacters(in: .whitespaces)
        let maxBytes = max(0, obj["max_bytes"]?.intValue ?? AttachmentDefaults.maxBase64Bytes)

        guard let msg = try await context.indexDB.loadMessage(rowid: rowid) else {
            throw JSONRPCErrorPayload(
                code: JSONRPCErrorCode.invalidParams,
                message: "get_attachment: no message with rowid \(rowid)"
            )
        }
        guard let mailbox = try await context.indexDB.loadMailbox(rowid: msg.mailboxRowId) else {
            throw JSONRPCErrorPayload(
                code: JSONRPCErrorCode.internalError,
                message: "get_attachment: rowid \(rowid) has no resolvable mailbox"
            )
        }
        guard let body = try await context.bodyLoader.loadBody(messageRowId: msg.rowId, mailbox: mailbox) else {
            throw JSONRPCErrorPayload(
                code: JSONRPCErrorCode.invalidParams,
                message: "get_attachment: body not on disk for rowid \(rowid) — open the message in Mail.app once to trigger an IMAP download, then retry"
            )
        }
        guard attIdx >= 0, attIdx < body.attachments.count else {
            throw JSONRPCErrorPayload(
                code: JSONRPCErrorCode.invalidParams,
                message: "get_attachment: attachment_index \(attIdx) out of range — message has \(body.attachments.count) attachment(s)"
            )
        }

        let att = body.attachments[attIdx]

        if let savePath, !savePath.isEmpty {
            // Disk-write mode — sidesteps the per-tool-call payload cap.
            let absolute: String
            do {
                absolute = try safeAbsolutePath(savePath)
            } catch let err as PathSafetyError {
                throw JSONRPCErrorPayload(
                    code: JSONRPCErrorCode.invalidParams,
                    message: "get_attachment: \(err.description)"
                )
            }
            do {
                try writeAttachment(att.data, to: absolute)
            } catch {
                throw JSONRPCErrorPayload(
                    code: JSONRPCErrorCode.internalError,
                    message: "get_attachment: failed to write to \(absolute): \(error.localizedDescription)"
                )
            }
            return try JSONValue.encoding(AttachmentSaved(
                rowid: rowid,
                attachment_index: attIdx,
                name: att.name,
                content_type: att.contentType,
                byte_count: att.data.count,
                saved_path: absolute
            ))
        }

        // Base64 mode (original behaviour).
        let totalBytes = att.data.count
        let truncated = totalBytes > maxBytes
        let slice = truncated ? att.data.prefix(maxBytes) : att.data
        let base64 = Data(slice).base64EncodedString()

        return try JSONValue.encoding(AttachmentContent(
            rowid: rowid,
            attachment_index: attIdx,
            name: att.name,
            content_type: att.contentType,
            byte_count: totalBytes,
            data_base64: base64,
            truncated: truncated
        ))
    }

    // MARK: — get_attachments_for_rowids (bulk)

    /// Fetch every attachment for each of `rowids` and write them all to
    /// `save_dir`, one subdirectory per rowid. Result rows pair every
    /// rowid+index with either `saved_path` (success) or `error`.
    /// Partial success is normal — a single missing-from-disk body
    /// shouldn't fail the whole batch.
    static func getAttachmentsForRowids(_ args: JSONValue, context: MCPContext) async throws -> JSONValue {
        guard let obj = args.objectValue,
              let rawRowids = obj["rowids"]?.arrayValue
        else {
            throw JSONRPCErrorPayload(
                code: JSONRPCErrorCode.invalidParams,
                message: "get_attachments_for_rowids: `rowids` (array of integers) and `save_dir` (string) are required"
            )
        }
        guard let saveDirRaw = obj["save_dir"]?.stringValue, !saveDirRaw.isEmpty else {
            throw JSONRPCErrorPayload(
                code: JSONRPCErrorCode.invalidParams,
                message: "get_attachments_for_rowids: `save_dir` (string) is required"
            )
        }
        let rowids = rawRowids.compactMap { $0.intValue }
        guard rowids.count == rawRowids.count else {
            throw JSONRPCErrorPayload(
                code: JSONRPCErrorCode.invalidParams,
                message: "get_attachments_for_rowids: `rowids` must contain integers only"
            )
        }
        let saveDir: String
        do {
            saveDir = try safeAbsolutePath(saveDirRaw)
        } catch let err as PathSafetyError {
            throw JSONRPCErrorPayload(
                code: JSONRPCErrorCode.invalidParams,
                message: "get_attachments_for_rowids: \(err.description)"
            )
        }
        do {
            try FileManager.default.createDirectory(
                atPath: saveDir, withIntermediateDirectories: true
            )
        } catch {
            throw JSONRPCErrorPayload(
                code: JSONRPCErrorCode.internalError,
                message: "get_attachments_for_rowids: couldn't create \(saveDir): \(error.localizedDescription)"
            )
        }

        var saved: [BulkAttachmentRow] = []
        var errors: [BulkAttachmentRow] = []

        for rowid in rowids {
            guard let msg = try? await context.indexDB.loadMessage(rowid: rowid) else {
                errors.append(.errorRow(rowid: rowid, attachment_index: -1, message: "no message with rowid \(rowid)"))
                continue
            }
            guard let mailbox = try? await context.indexDB.loadMailbox(rowid: msg.mailboxRowId) else {
                errors.append(.errorRow(rowid: rowid, attachment_index: -1, message: "no mailbox for rowid \(rowid)"))
                continue
            }
            guard let body = try? await context.bodyLoader.loadBody(messageRowId: rowid, mailbox: mailbox) else {
                errors.append(.errorRow(rowid: rowid, attachment_index: -1, message: "body not on disk for rowid \(rowid)"))
                continue
            }

            // One subdir per message, by rowid. Avoids name collisions
            // across messages with same-named attachments.
            let perMsgDir = (saveDir as NSString).appendingPathComponent(String(rowid))
            do {
                try FileManager.default.createDirectory(
                    atPath: perMsgDir, withIntermediateDirectories: true
                )
            } catch {
                errors.append(.errorRow(rowid: rowid, attachment_index: -1, message: "mkdir failed: \(error.localizedDescription)"))
                continue
            }

            for (idx, att) in body.attachments.enumerated() {
                let safeName = sanitiseFilename(att.name)
                let path = (perMsgDir as NSString).appendingPathComponent(safeName)
                do {
                    try writeAttachment(att.data, to: path)
                    saved.append(BulkAttachmentRow(
                        rowid: rowid,
                        attachment_index: idx,
                        name: att.name,
                        content_type: att.contentType,
                        byte_count: att.data.count,
                        saved_path: path,
                        error: nil
                    ))
                } catch {
                    errors.append(.errorRow(
                        rowid: rowid,
                        attachment_index: idx,
                        message: "write \(att.name) failed: \(error.localizedDescription)"
                    ))
                }
            }
        }

        return try JSONValue.encoding(BulkAttachmentResult(saved: saved, errors: errors))
    }

    // MARK: — Helpers

    /// Resolve a user-supplied path: tilde expansion, then make absolute
    /// relative to the user's home (the only sensible default in a
    /// single-user macOS app). Rejects paths containing `..` segments —
    /// any authenticated MCP client otherwise gets unrestricted write
    /// access to any user-writable file (`~/.zshrc`, ssh keys, etc.).
    /// A handful of legitimate paths happen to contain `..` (e.g.
    /// `~/Documents/../Downloads/foo.pdf`); they can be re-expressed
    /// without the parent reference.
    static func safeAbsolutePath(_ path: String) throws -> String {
        let trimmed = path.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            throw PathSafetyError.emptyPath
        }
        let expanded = (trimmed as NSString).expandingTildeInPath
        let absolute: String
        if (expanded as NSString).isAbsolutePath {
            absolute = expanded
        } else {
            absolute = ((NSHomeDirectory() as NSString).appendingPathComponent(expanded) as NSString).standardizingPath
        }
        // After standardisation, no `..` segment should appear. We check
        // both the standardised form and the raw input so a client can't
        // sneak `..` past us by exploiting a quirk of `standardizingPath`.
        let standardised = (absolute as NSString).standardizingPath
        let components = (standardised as NSString).pathComponents
        if components.contains("..") || (trimmed as NSString).pathComponents.contains("..") {
            throw PathSafetyError.parentReference(trimmed)
        }
        return standardised
    }

    private static func writeAttachment(_ data: Data, to absolutePath: String) throws {
        // Ensure the destination directory exists (handle `save_to_path =
        // /path/to/missing/dir/file.pdf`).
        let dir = (absolutePath as NSString).deletingLastPathComponent
        if !dir.isEmpty {
            try FileManager.default.createDirectory(
                atPath: dir, withIntermediateDirectories: true
            )
        }
        try data.write(to: URL(fileURLWithPath: absolutePath))
    }

    /// Strip characters that misbehave on macOS (slashes, NUL) and trim
    /// whitespace. Also defangs `..` segments — an attachment named
    /// `../../foo.txt` would otherwise write outside its per-rowid
    /// subdirectory. We replace `..` with `__` rather than dropping it
    /// so two distinct attachments don't collide on the sanitised name.
    static func sanitiseFilename(_ name: String) -> String {
        var cleaned = name
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\\", with: "_")
            .replacingOccurrences(of: "\u{0}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Strip leading dots so the result isn't a hidden file or `.` /
        // `..` literal; then neutralise any remaining `..` substrings.
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }
        cleaned = cleaned.replacingOccurrences(of: "..", with: "__")
        return cleaned.isEmpty ? "attachment.bin" : cleaned
    }
}

enum PathSafetyError: Error, CustomStringConvertible {
    case emptyPath
    case parentReference(String)

    var description: String {
        switch self {
        case .emptyPath:
            return "path is empty"
        case .parentReference(let p):
            return "path contains a `..` segment (\(p)) — re-express without parent references"
        }
    }
}

/// Defaults for the attachment tools. Lifted out so the values are
/// shared between the schema (`MCPTools`) and the handler.
enum AttachmentDefaults {
    /// Cap on raw (pre-base64) bytes returned when `save_to_path` is
    /// unset. The base64 inflation pushes anything larger past most
    /// MCP-client per-call response caps.
    static let maxBase64Bytes = 10_000_000
}

private extension BulkAttachmentRow {
    static func errorRow(rowid: Int, attachment_index: Int, message: String) -> BulkAttachmentRow {
        BulkAttachmentRow(
            rowid: rowid,
            attachment_index: attachment_index,
            name: nil,
            content_type: nil,
            byte_count: nil,
            saved_path: nil,
            error: message
        )
    }
}
