import Foundation
import Network
import AppKit

/// Spins up a one-shot HTTP server on `127.0.0.1:<random>` to catch the
/// OAuth callback. Opens the auth URL in the user's default browser; the
/// browser hits our redirect URI; we parse out the code and shut down.
///
/// Loopback redirects are Google's recommended pattern for installed apps
/// (RFC 8252 §7.3). They avoid the security pitfalls of custom URL schemes
/// (claim-jacking by other apps) and embedded WebView (CVE-prone).
enum OAuthLoopbackListener {

    /// Run a full auth code flow. Binds a listener, opens the browser,
    /// waits for the callback, returns the auth code (and used PKCE
    /// verifier so the caller can exchange it for tokens).
    /// `timeout` defaults to 5 minutes — enough for the user to read the
    /// consent screen even on a slow Google account picker, but bounded
    /// so a forgotten flow doesn't pin a port forever.
    static func run(
        clientID: String,
        scopes: [String],
        timeout: TimeInterval = 300
    ) async throws -> (code: String, verifier: String, redirectURI: String) {
        guard !clientID.isEmpty else { throw OAuthFlowError.notConfigured }

        // Bind first so we know our port before building the auth URL.
        let listener = try NWListener(using: .tcp, on: .any)
        let bindStart = Date()
        let port = try await waitForReady(listener: listener, deadline: bindStart.addingTimeInterval(10))
        let redirectURI = "http://127.0.0.1:\(port)/oauth-callback"

        // Build PKCE + state + auth URL.
        let pkce = PKCE.generate()
        let state = PKCE.makeVerifier(length: 43)  // any URL-safe random
        let request = AuthorizationRequest(
            clientID: clientID,
            redirectURI: redirectURI,
            scopes: scopes,
            state: state,
            pkceChallenge: pkce.challenge,
            pkceMethod: pkce.method
        )
        let authURL = request.authorizationURL()

        // Set up the callback handler before opening the browser.
        let codePromise = AsyncSinglePromise<String>()
        listener.newConnectionHandler = { conn in
            Task {
                await Self.handleCallback(conn, expectedState: state, promise: codePromise)
            }
        }

        // Open the user's browser.
        await MainActor.run {
            NSWorkspace.shared.open(authURL)
        }

        // Wait for the callback (or timeout).
        let code: String
        do {
            code = try await withTimeout(seconds: timeout) {
                try await codePromise.value()
            }
        } catch {
            listener.cancel()
            throw error
        }
        listener.cancel()
        return (code: code, verifier: pkce.verifier, redirectURI: redirectURI)
    }

    // MARK: — internals

    /// Bind the listener and await its `.ready` state to learn the OS-
    /// assigned port. Treats `.failed`/`.waiting` as bind failures.
    private static func waitForReady(listener: NWListener, deadline: Date) async throws -> UInt16 {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<UInt16, Error>) in
            let didResume = AtomicFlag()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if didResume.testAndSet() {
                        cont.resume(returning: listener.port?.rawValue ?? 0)
                    }
                case .failed(let err), .waiting(let err):
                    if didResume.testAndSet() {
                        cont.resume(throwing: err)
                    }
                default: break
                }
            }
            listener.start(queue: .global(qos: .userInitiated))
        }
    }

    /// Read the inbound GET request, parse the OAuth callback URL, fulfil
    /// the promise. Always writes an HTML response to the browser before
    /// closing so the user sees a friendly "authorization complete" page.
    private static func handleCallback(_ conn: NWConnection, expectedState: String, promise: AsyncSinglePromise<String>) async {
        conn.start(queue: .global(qos: .userInitiated))
        defer { conn.cancel() }

        // Read until headers complete.
        var accumulated = Data()
        let maxBytes = 64 * 1024
        while accumulated.count < maxBytes {
            let chunk: Data? = await withCheckedContinuation { (cont: CheckedContinuation<Data?, Never>) in
                conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, isComplete, error in
                    if error != nil { cont.resume(returning: nil); return }
                    if let data, !data.isEmpty { cont.resume(returning: data); return }
                    if isComplete { cont.resume(returning: nil); return }
                    cont.resume(returning: Data())
                }
            }
            guard let chunk else { return }
            accumulated.append(chunk)
            if accumulated.range(of: Data([0x0D, 0x0A, 0x0D, 0x0A])) != nil {
                break
            }
        }

        // Extract the request path.
        guard let headersText = String(data: accumulated, encoding: .ascii),
              let firstLine = headersText.components(separatedBy: "\r\n").first,
              let pathPart = firstLine.split(separator: " ").dropFirst().first
        else {
            await sendHTML(conn, body: "<h1>FMail: malformed callback</h1>")
            return
        }
        let path = String(pathPart)

        // Build a URL out of `http://127.0.0.1/<path>` so URLComponents
        // can parse the query for us.
        guard let url = URL(string: "http://127.0.0.1\(path)") else {
            await sendHTML(conn, body: "<h1>FMail: malformed callback URL</h1>")
            return
        }

        do {
            let code = try OAuthCallbackParser.parse(url, expectedState: expectedState)
            await sendHTML(conn, body: """
            <h1>FMail: authorization complete</h1>
            <p>You can close this tab and return to FMail.</p>
            """)
            await promise.fulfil(.success(code))
        } catch {
            await sendHTML(conn, body: """
            <h1>FMail: authorization failed</h1>
            <p>\(error)</p>
            <p>You can close this tab.</p>
            """)
            await promise.fulfil(.failure(error))
        }
    }

    private static func sendHTML(_ conn: NWConnection, body: String) async {
        let html = "<!doctype html><html><body style=\"font-family: -apple-system, sans-serif; padding: 40px;\">\(body)</body></html>"
        let response =
            "HTTP/1.1 200 OK\r\n" +
            "Content-Type: text/html; charset=utf-8\r\n" +
            "Content-Length: \(html.utf8.count)\r\n" +
            "Connection: close\r\n\r\n" +
            html
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            conn.send(content: Data(response.utf8), completion: .contentProcessed { _ in
                cont.resume()
            })
        }
    }
}

// MARK: — Concurrency primitives

/// One-shot future, fulfillable from any actor. Used to bridge the
/// callback-based NWConnection world into async/await.
private actor AsyncSinglePromise<T: Sendable> {
    private var result: Result<T, Error>?
    private var waiters: [CheckedContinuation<T, Error>] = []

    func fulfil(_ r: Result<T, Error>) {
        guard result == nil else { return }
        result = r
        for w in waiters { w.resume(with: r) }
        waiters.removeAll()
    }

    func value() async throws -> T {
        if let r = result {
            return try r.get()
        }
        return try await withCheckedThrowingContinuation { cont in
            waiters.append(cont)
        }
    }
}

/// Wrap an async operation with a deadline. Throws `OAuthFlowError` on
/// timeout. Uses TaskGroup so the cancellation propagates.
private func withTimeout<T: Sendable>(
    seconds: TimeInterval,
    _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw OAuthFlowError.malformedCallback("timed out waiting for browser callback after \(Int(seconds))s")
        }
        let first = try await group.next()!
        group.cancelAll()
        return first
    }
}

/// Tiny one-shot flag to guard NWListener's continuation against multiple
/// state-update resumes. Mirrors the one in MCPServer.
private final class AtomicFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    func testAndSet() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if fired { return false }
        fired = true
        return true
    }
}
