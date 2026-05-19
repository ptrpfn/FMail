import Foundation
import Observation

/// Public visibility of the tunnel state machine. Surfaced in `MailModel`
/// so SwiftUI can observe transitions and render the warning banner /
/// Settings status row.
enum TunnelState: Equatable, Sendable {
    case off
    case starting              // cloudflared spawned; waiting for "Registered tunnel connection"
    case running(url: URL)     // edge connection registered; URL = MCPSettings.tunnelPublicURL
    case stopping              // SIGTERM sent; waiting for process to exit
    case error(String)         // last failure; banner stays orange/red until cleared

    var isLive: Bool {
        switch self {
        case .starting, .running, .stopping: return true
        case .off, .error: return false
        }
    }
}

/// Why `start()` refused. Surfaced in Settings as the tooltip on a disabled
/// "Open tunnel" button so the user knows which precondition to fix first.
enum TunnelStartRefusal: Equatable {
    case cloudflaredMissing
    case notLoggedIn
    case mcpNotRunning
    case authTokenMissing
    case tunnelNameMissing
    case publicURLMissing
    case publicURLMalformed
    case alreadyRunning

    var userMessage: String {
        switch self {
        case .cloudflaredMissing:
            return "cloudflared isn't installed. Run `brew install cloudflared` and try again."
        case .notLoggedIn:
            return "cloudflared isn't logged in. Run `cloudflared tunnel login` once in Terminal."
        case .mcpNotRunning:
            return "Enable the MCP server above before opening the tunnel."
        case .authTokenMissing:
            return "Generate an auth token first — exposing the server unauthenticated would let anyone read your mail."
        case .tunnelNameMissing:
            return "Set a tunnel name (the one passed to `cloudflared tunnel create`)."
        case .publicURLMissing:
            return "Set the public URL the tunnel routes to (e.g. https://fmail.example.com)."
        case .publicURLMalformed:
            return "Public URL must start with https:// and parse as a valid URL."
        case .alreadyRunning:
            return "Tunnel is already running or starting."
        }
    }
}

/// Manages the cloudflared child process for a named Cloudflare tunnel.
/// Lifecycle:
///   .off ──▶ start() ──▶ .starting ──▶ "Registered tunnel connection" ──▶ .running
///                    └──▶ early err / timeout ────────────────────────▶ .error
///   .running ──▶ stop() ──▶ .stopping ──▶ process exit ──▶ .off
///   process dies unexpectedly while .running ──▶ .error
///
/// One process per coordinator. `start()` while a process is already up
/// returns `.alreadyRunning` rather than spawning a second instance.
///
/// The on-disk log tail (`recentLogLines`) is kept as a small rolling
/// buffer so Settings can surface what cloudflared was saying when it
/// failed — useful for "tunnel credentials file doesn't exist" type errors
/// where the user needs to act in Terminal.
@MainActor
@Observable
final class TunnelCoordinator {
    private(set) var state: TunnelState = .off
    private(set) var recentLogLines: [String] = []

    private let mcpPort: () -> Int
    private let mcpIsRunning: () -> Bool

    @ObservationIgnored
    private var process: Process?
    @ObservationIgnored
    private var stdoutPipe: Pipe?
    @ObservationIgnored
    private var stderrPipe: Pipe?
    @ObservationIgnored
    private var readinessTask: Task<Void, Never>?
    @ObservationIgnored
    /// Temp config.yml we write per-run; removed on stop / unexpected exit.
    private var tempConfigPath: URL?
    @ObservationIgnored
    private static let readinessTimeout: Duration = .seconds(15)
    @ObservationIgnored
    private static let stopTimeout: Duration = .seconds(5)
    @ObservationIgnored
    private static let maxLogLines = 80

    init(mcpPort: @escaping () -> Int, mcpIsRunning: @escaping () -> Bool) {
        self.mcpPort = mcpPort
        self.mcpIsRunning = mcpIsRunning
    }

    /// Check preconditions in order; returns nil when start() would proceed.
    func refusalReason() -> TunnelStartRefusal? {
        if state.isLive { return .alreadyRunning }
        if CloudflaredLocator.locate(override: MCPSettings.cloudflaredPath) == nil {
            return .cloudflaredMissing
        }
        if !CloudflaredLocator.isLoggedIn() { return .notLoggedIn }
        if !mcpIsRunning() { return .mcpNotRunning }
        if MCPSettings.authToken.isEmpty { return .authTokenMissing }
        if MCPSettings.tunnelName.trimmingCharacters(in: .whitespaces).isEmpty {
            return .tunnelNameMissing
        }
        let urlString = MCPSettings.tunnelPublicURL.trimmingCharacters(in: .whitespaces)
        if urlString.isEmpty { return .publicURLMissing }
        guard let url = URL(string: urlString), url.scheme == "https" else {
            return .publicURLMalformed
        }
        _ = url
        return nil
    }

    /// Launch `cloudflared tunnel --config <tmp> run <name>`. We write a
    /// temporary `config.yml` with explicit ingress rules every time
    /// because `--url <localOrigin>` is silently ignored when combined
    /// with `run <name>` — cloudflared then has no idea where to forward
    /// edge traffic and Cloudflare returns HTTP 530 / error 1033 for
    /// every request. The temp file is removed in `stop()`.
    ///
    /// Idempotent: returns early if a process is already starting or
    /// running. Failures land in `state = .error(...)` with a
    /// human-readable string.
    func start() async {
        if let refusal = refusalReason() {
            state = .error(refusal.userMessage)
            return
        }
        guard let cfPath = CloudflaredLocator.locate(override: MCPSettings.cloudflaredPath) else {
            state = .error(TunnelStartRefusal.cloudflaredMissing.userMessage)
            return
        }
        guard let credentialsPath = CloudflaredLocator.findCredentialsFile() else {
            state = .error("Couldn't find tunnel credentials in ~/.cloudflared/. Run `cloudflared tunnel create <name>` (one-time setup) to generate them.")
            return
        }
        let tunnelName = MCPSettings.tunnelName.trimmingCharacters(in: .whitespaces)
        let publicURL = URL(string: MCPSettings.tunnelPublicURL.trimmingCharacters(in: .whitespaces))!
        guard let publicHost = publicURL.host else {
            state = .error("Public URL has no host component: \(publicURL.absoluteString)")
            return
        }

        // Write the temp ingress config. Keep the path on the instance
        // so `stop()` (and the termination handler) can clean up.
        let configPath = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fmail-cloudflared-\(UUID().uuidString).yml")
        let yaml = """
        tunnel: \(tunnelName)
        credentials-file: \(credentialsPath)
        ingress:
          - hostname: \(publicHost)
            service: http://127.0.0.1:\(mcpPort())
          - service: http_status:404
        """
        do {
            try yaml.write(to: configPath, atomically: true, encoding: .utf8)
        } catch {
            state = .error("Failed to write tunnel config: \(error.localizedDescription)")
            return
        }
        self.tempConfigPath = configPath

        state = .starting
        recentLogLines.removeAll()

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: cfPath)
        proc.arguments = [
            "tunnel",
            "--no-autoupdate",
            "--config", configPath.path,
            "run", tunnelName
        ]
        let stdout = Pipe()
        let stderr = Pipe()
        proc.standardOutput = stdout
        proc.standardError = stderr

        // Stream both pipes through the same line-handler — cloudflared
        // logs to stderr but doesn't promise to keep doing so forever.
        let onChunk: @Sendable (Data) -> Void = { [weak self] data in
            guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor [weak self] in self?.ingest(chunk: chunk) }
        }
        stdout.fileHandleForReading.readabilityHandler = { onChunk($0.availableData) }
        stderr.fileHandleForReading.readabilityHandler = { onChunk($0.availableData) }
        proc.terminationHandler = { [weak self] terminated in
            let code = terminated.terminationStatus
            Task { @MainActor [weak self] in self?.handleTermination(exitCode: code) }
        }

        do {
            try proc.run()
        } catch {
            state = .error("Failed to launch cloudflared: \(error.localizedDescription)")
            return
        }
        self.process = proc
        self.stdoutPipe = stdout
        self.stderrPipe = stderr

        // Readiness watchdog: if no "registered connection" line arrives
        // within the timeout, give up and tear the process down.
        readinessTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.readinessTimeout)
            guard let self else { return }
            if case .starting = self.state {
                Log.tunnel.error("cloudflared startup timed out after \(Int(Self.readinessTimeout.components.seconds))s")
                self.state = .error("cloudflared started but no tunnel connection registered within \(Int(Self.readinessTimeout.components.seconds))s. Check the recent log output below.")
                self.killProcessImmediately()
            }
        }

        // Capture the URL we'll surface once ready — read once here so a
        // mid-flight Settings edit doesn't change what we report.
        self.pendingPublicURL = publicURL

        Log.tunnel.info("cloudflared spawned: \(cfPath) tunnel run \(tunnelName, privacy: .private)")
    }

    /// SIGTERM cloudflared and wait for it to exit (up to `stopTimeout`),
    /// then transition to `.off`. `force=true` skips the wait — used from
    /// `applicationWillTerminate` to keep app-quit snappy.
    func stop(force: Bool = false) async {
        guard let proc = process else {
            // Already stopped; just normalise state.
            if case .running = state { state = .off }
            if case .starting = state { state = .off }
            readinessTask?.cancel()
            readinessTask = nil
            return
        }
        guard case .running = state else {
            // Mid-startup or already-stopping — still send SIGTERM.
            if case .starting = state { state = .stopping }
            proc.terminate()
            if !force {
                _ = await waitForExit(proc)
            }
            cleanupAfterExit()
            return
        }
        state = .stopping
        proc.terminate()
        if !force {
            _ = await waitForExit(proc)
        }
        cleanupAfterExit()
    }

    /// Synchronous best-effort tear-down for `applicationWillTerminate`.
    /// Sends SIGTERM, waits briefly, then SIGKILLs if necessary. Doesn't
    /// touch the published state — the app is exiting anyway. Called on
    /// the main actor from a notification observer; spending up to 2s on
    /// the main thread here is fine since the app is exiting.
    func stopBlockingForQuit() {
        guard let proc = process else { return }
        proc.terminate()
        let deadline = Date().addingTimeInterval(2.0)
        while proc.isRunning && Date() < deadline {
            usleep(50_000)
        }
        if proc.isRunning {
            kill(proc.processIdentifier, SIGKILL)
        }
    }

    /// Clear `.error` so the banner / "Open tunnel" button reset to off-state.
    func clearError() {
        if case .error = state { state = .off }
    }

    // MARK: — Private

    @ObservationIgnored
    private var pendingPublicURL: URL?

    private func ingest(chunk: String) {
        let lines = chunk
            .split(whereSeparator: \.isNewline)
            .map(String.init)
        for line in lines {
            recentLogLines.append(line)
            if recentLogLines.count > Self.maxLogLines {
                recentLogLines.removeFirst(recentLogLines.count - Self.maxLogLines)
            }
        }
        if case .starting = state {
            if CloudflaredLogParser.didRegisterConnection(in: chunk) {
                guard let url = pendingPublicURL else { return }
                Log.tunnel.info("cloudflared tunnel up; public URL: \(url.absoluteString, privacy: .private)")
                state = .running(url: url)
                readinessTask?.cancel()
                readinessTask = nil
                return
            }
            if CloudflaredLogParser.didFailEarly(in: chunk) {
                let tail = recentLogLines.suffix(5).joined(separator: " / ")
                Log.tunnel.error("cloudflared early failure: \(tail, privacy: .private)")
                state = .error("cloudflared reported an error: \(tail)")
                killProcessImmediately()
            }
        }
    }

    private func handleTermination(exitCode: Int32) {
        readinessTask?.cancel()
        readinessTask = nil
        switch state {
        case .stopping:
            state = .off
        case .running, .starting:
            let tail = recentLogLines.suffix(5).joined(separator: " / ")
            state = .error("cloudflared exited unexpectedly (code \(exitCode)). \(tail)")
            Log.tunnel.error("cloudflared exited unexpectedly code=\(exitCode)")
        case .off, .error:
            break  // shouldn't usually happen; leave state alone
        }
        process = nil
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
        stdoutPipe = nil
        stderrPipe = nil
        removeTempConfig()
    }

    private func cleanupAfterExit() {
        // termination handler does the heavy lifting; this exists for the
        // paths where we want to be sure handlers are removed even if the
        // process is mid-exit.
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
        removeTempConfig()
    }

    private func removeTempConfig() {
        guard let path = tempConfigPath else { return }
        try? FileManager.default.removeItem(at: path)
        tempConfigPath = nil
    }

    private func killProcessImmediately() {
        guard let proc = process else { return }
        proc.terminate()
        // Don't await — the readiness path already timed out; UI just
        // wants the state transition. terminationHandler tidies up.
    }

    private func waitForExit(_ proc: Process) async -> Bool {
        let deadline = Date().addingTimeInterval(TimeInterval(Self.stopTimeout.components.seconds))
        while proc.isRunning && Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        if proc.isRunning {
            kill(proc.processIdentifier, SIGKILL)
            return false
        }
        return true
    }
}
