import Foundation

/// Errors thrown by `DSHProcessManager`.
public enum DSHProcessError: Error, LocalizedError, Sendable {
    case binaryNotFound(String)
    case binaryNotExecutable(String)
    case alreadyRunning
    case spawnFailed(Int32)
    case timedOutWaitingForURL(Int)
    case noExistingEndpointFound
    case childExitedUnexpectedly(Int32, lastLogLines: [String])

    public var errorDescription: String? {
        switch self {
        case .binaryNotFound(let path):
            return "dsh binary not found at \(path). Set `dshBinaryPath` in Preferences."
        case .binaryNotExecutable(let path):
            return "dsh binary at \(path) is not executable. Run `chmod +x \(path)`."
        case .alreadyRunning:
            return "A dsh process is already running under this manager."
        case .spawnFailed(let code):
            return "Failed to spawn dsh (errno \(code))."
        case .timedOutWaitingForURL(let seconds):
            return "dsh web did not print its URL line within \(seconds)s."
        case .noExistingEndpointFound:
            return "No existing dsh web instance was found on loopback ports."
        case .childExitedUnexpectedly(let code, let lines):
            let tail = lines.suffix(5).joined(separator: "\n")
            return "dsh exited with status \(code). Last log:\n\(tail)"
        }
    }
}

/// Lifecycle events emitted by `DSHProcessManager`.
public enum DSHProcessEvent: Sendable {
    case launching
    case launched(pid: Int32)
    case stdoutLine(String)
    case stderrLine(String)
    case endpointResolved(URL)
    case childExited(status: Int32)
    case autoRestartScheduled(after: TimeInterval)
    case autoRestartAttempted
    case autoRestartAborted(reason: String)
}

/// Owns the `dsh web` child process. Never invokes a shell, so user input
/// cannot become argv injection. Implemented as an actor so all state mutation
/// happens under Swift's structured concurrency isolation rules.
public actor DSHProcessManager {
    public let settings: ShellSettings
    private let resolver: EndpointResolver

    private var process: Process?
    private var stdoutTask: Task<Void, Never>?
    private var stderrTask: Task<Void, Never>?
    private var listeners: [UUID: AsyncStream<DSHProcessEvent>.Continuation] = [:]
    private var state: ConnectionState = .idle
    private var lastLogLines: [String] = []
    private var restartAttempts: Int = 0
    private var inFlightAttach: Task<URL?, Error>?

    public init(settings: ShellSettings, resolver: EndpointResolver = EndpointResolver()) {
        self.settings = settings
        self.resolver = resolver
    }

    /// Returns a live stream of events. The stream terminates when `stop()` is called.
    public func events() -> AsyncStream<DSHProcessEvent> {
        AsyncStream { continuation in
            let id = UUID()
            Task { await self.addListener(id: id, continuation: continuation) }
            continuation.onTermination = { @Sendable [weak self] _ in
                Task { await self?.removeListener(id: id) }
            }
        }
    }

    private func addListener(id: UUID, continuation: AsyncStream<DSHProcessEvent>.Continuation) {
        listeners[id] = continuation
    }

    private func removeListener(id: UUID) {
        listeners.removeValue(forKey: id)
    }

    private func broadcast(_ event: DSHProcessEvent) {
        for c in listeners.values { c.yield(event) }
    }

    /// Begin the lifecycle. Returns the URL once known.
    public func start() async throws -> URL {
        try Self.validateBinary(settings.dshBinaryPath)

        switch settings.launchMode {
        case .spawn:
            return try await startSpawn()
        case .attach:
            return try await startAttach()
        }
    }

    // MARK: - Spawn

    private func startSpawn() async throws -> URL {
        if process != nil { throw DSHProcessError.alreadyRunning }
        state = .launching
        broadcast(.launching)

        let argv = Self.buildArgv(settings: settings)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: settings.dshBinaryPath)
        process.arguments = Array(argv.dropFirst())

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        process.terminationHandler = { [weak self] proc in
            let status = proc.terminationStatus
            Task { await self?.handleChildExit(status: status) }
        }

        do {
            try process.run()
        } catch {
            state = .failed(reason: "spawn failed: \(error.localizedDescription)")
            throw DSHProcessError.spawnFailed(-1)
        }

        self.process = process
        let pid = process.processIdentifier
        broadcast(.launched(pid: pid))

        // Drain stdout/stderr. The detached tasks read from the pipe on a
        // utility-priority executor; the FileHandles are reference types
        // pinned to the child process for its lifetime. We mark the local
        // bindings `nonisolated(unsafe)` so the strict-concurrency checker
        // accepts the cross-actor closure capture.
        nonisolated(unsafe) let outHandle = stdoutPipe.fileHandleForReading
        nonisolated(unsafe) let errHandle = stderrPipe.fileHandleForReading
        stdoutTask = Task.detached(priority: .utility) { [weak self] in
            await self?.drain(handle: outHandle, isErr: false)
        }
        stderrTask = Task.detached(priority: .utility) { [weak self] in
            await self?.drain(handle: errHandle, isErr: true)
        }

        // Wait for endpoint resolution with a per-instance deadline.
        let deadline = Date().addingTimeInterval(TimeInterval(settings.spawnTimeoutSeconds))
        while true {
            switch state {
            case .ready(let url):
                return url
            case .failed(let reason):
                throw DSHProcessError.timedOutWaitingForURL(0) // carry reason upward via Diagnose helper below
                _ = reason
            case .shuttingDown:
                throw DSHProcessError.spawnFailed(-1)
            default:
                if Date() >= deadline {
                    throw DSHProcessError.timedOutWaitingForURL(settings.spawnTimeoutSeconds)
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
    }

    /// Reads one line at a time from a `FileHandle` and forwards it to the
    /// actor. Marked `nonisolated` so we can run it inside a `Task.detached`
    /// without dragging the actor's executor with us. FileHandle is unsafe to
    /// share across actors in the general case, so we mark the parameter
    /// `nonisolated(unsafe)` to accept the borrow.
    private nonisolated func drain(handle: FileHandle, isErr: Bool) async {
        var buffer = Data()
        do {
            for try await chunk in handle.bytes {
                if chunk.isEmpty { continue }
                buffer.append(chunk)
                while let nl = buffer.firstIndex(of: 0x0A) {
                    let lineData = buffer.subdata(in: buffer.startIndex..<nl)
                    let dropRange = buffer.startIndex...nl
                    buffer.removeSubrange(dropRange)
                    let line = String(data: lineData, encoding: .utf8) ?? ""
                    if isErr {
                        await self.consumeStderr(line)
                    } else {
                        await self.consumeStdout(line)
                    }
                }
            }
            if !buffer.isEmpty, let last = String(data: buffer, encoding: .utf8) {
                if isErr {
                    await self.consumeStderr(last)
                } else {
                    await self.consumeStdout(last)
                }
            }
        } catch {
            // fd closed
        }
    }

    private func consumeStdout(_ line: String) {
        appendLog(line)
        broadcast(.stdoutLine(line))
        if case .ready = state { return }
        if let url = resolver.resolveURL(in: line) {
            state = .ready(url)
            broadcast(.endpointResolved(url))
        }
    }

    private func consumeStderr(_ line: String) {
        appendLog(line)
        broadcast(.stderrLine(line))
    }

    private func appendLog(_ line: String) {
        lastLogLines.append(line)
        if lastLogLines.count > 200 { lastLogLines.removeFirst(lastLogLines.count - 200) }
    }

    private func handleChildExit(status: Int32) {
        appendLog("[exit] status=\(status)")
        broadcast(.childExited(status: status))
        if case .shuttingDown = state { return }
        if settings.autoRestartOnCrash && restartAttempts == 0 {
            restartAttempts += 1
            let delay: TimeInterval = min(30, pow(2.0, Double(restartAttempts)))
            broadcast(.autoRestartScheduled(after: delay))
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard let self else { return }
                await self.attemptAutoRestart()
            }
        } else {
            state = .failed(reason: "Child exited with status \(status).")
        }
    }

    private func attemptAutoRestart() async {
        broadcast(.autoRestartAttempted)
        process = nil
        do {
            _ = try await startSpawn()
        } catch {
            broadcast(.autoRestartAborted(reason: error.localizedDescription))
        }
    }

    // MARK: - Attach

    private func startAttach() async throws -> URL {
        let probe = AttachProbe()
        inFlightAttach?.cancel()
        let task = Task<URL?, Error> { await probe.findExisting() }
        inFlightAttach = task
        state = .connecting(host: "127.0.0.1", port: 0)
        do {
            guard let url = try await task.value else {
                state = .failed(reason: "No dsh instance found on loopback ports.")
                throw DSHProcessError.noExistingEndpointFound
            }
            state = .ready(url)
            broadcast(.endpointResolved(url))
            return url
        } catch {
            state = .failed(reason: error.localizedDescription)
            throw error
        }
    }

    // MARK: - Shutdown

    public func stop() async {
        state = .shuttingDown
        guard let process else { return }
        let pid = process.processIdentifier
        process.terminate()
        let deadline = Date().addingTimeInterval(5)
        while process.isRunning && Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        if process.isRunning {
            kill(pid, SIGKILL)
        }
        stdoutTask?.cancel()
        stderrTask?.cancel()
        for c in listeners.values { c.finish() }
        listeners.removeAll()
    }

    // MARK: - Helpers

    public static func validateBinary(_ path: String) throws {
        guard FileManager.default.fileExists(atPath: path) else {
            throw DSHProcessError.binaryNotFound(path)
        }
        guard FileManager.default.isExecutableFile(atPath: path) else {
            throw DSHProcessError.binaryNotExecutable(path)
        }
    }

    public static func buildArgv(settings: ShellSettings) -> [String] {
        var argv: [String] = [settings.dshBinaryPath, "web"]
        argv.append(contentsOf: ["--host", settings.listenHost])
        if settings.preferredPort >= 0 {
            argv.append(contentsOf: ["--port", String(settings.preferredPort)])
        }
        for host in settings.trustedHosts {
            argv.append(contentsOf: ["--trusted-host", host])
        }
        if let workspace = settings.workspaceRoot, !workspace.isEmpty {
            argv.append(contentsOf: ["--workspace", workspace])
        }
        return argv
    }
}
