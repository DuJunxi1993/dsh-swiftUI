import Foundation
import SwiftUI
import DSHShellCore
import OSLog

/// Bridges the SwiftUI shell to the underlying `DSHProcessManager`. Owns the
/// process lifecycle for the lifetime of the app and exposes the connection
/// state to the view tree.
@MainActor
final class AppCoordinator: ObservableObject {
    @Published var state: ConnectionState = .idle
    @Published var settings: ShellSettings = .default
    @Published var consoleLines: [ConsoleLine] = []
    @Published var isPresentingPreferences: Bool = false

    private let store: SettingsStore
    private var manager: DSHProcessManager?
    private var observerTask: Task<Void, Never>?
    private var lastURL: URL?
    private var lastChildPID: Int32?
    private let logger = Logger(subsystem: "ai.deepseek.dsh-shell", category: "AppCoordinator")

    init(store: SettingsStore = SettingsStore()) {
        self.store = store
        self.settings = store.load()
    }

    func start() {
        guard observerTask == nil else { return }
        observerTask = Task { [weak self] in
            await self?.runLifecycle()
        }
    }

    func shutdown() {
        observerTask?.cancel()
        observerTask = nil
        guard let manager else { return }
        Task { await manager.stop() }
    }

    /// Blocking shutdown for `applicationWillTerminate`. The process exits
    /// immediately after the delegate returns, and by then the Swift
    /// concurrency runtime is being torn down, so neither unstructured nor
    /// detached `Task`s reliably get to run `manager.stop()` (observed: the
    /// stop never executed and the child dsh web was orphaned). Instead we
    /// signal the tracked child PID synchronously with `kill`/`waitpid` —
    /// plain syscalls that cannot be dropped by teardown — and only then
    /// attempt the best-effort actor cleanup.
    func shutdownBlocking() {
        observerTask?.cancel()
        observerTask = nil
        let pid = manager?.currentChildPID() ?? lastChildPID
        if let pid {
            kill(pid, SIGTERM)
            let deadline = Date().addingTimeInterval(5)
            while Date() < deadline {
                var status: Int32 = 0
                if waitpid(pid, &status, WNOHANG) != 0 { break }
                usleep(100_000)
            }
            var status: Int32 = 0
            if waitpid(pid, &status, WNOHANG) == 0 {
                kill(pid, SIGKILL)
            }
        }
        if let manager {
            let semaphore = DispatchSemaphore(value: 0)
            Task.detached {
                await manager.stop()
                semaphore.signal()
            }
            _ = semaphore.wait(timeout: .now() + 1)
        }
    }

    func reload() {
        Task { @MainActor in
            self.state = .shuttingDown
            if let manager {
                await manager.stop()
            }
            self.consoleLines.removeAll()
            self.start()
        }
    }

    func saveSettings(_ new: ShellSettings) {
        self.settings = new
        store.save(new)
    }

    func showPreferences() {
        isPresentingPreferences = true
    }

    // MARK: - Private

    private func runLifecycle() async {
        logger.debug("runLifecycle: dsh=\(self.settings.dshBinaryPath, privacy: .public) mode=\(self.settings.launchMode.rawValue, privacy: .public)")
        let manager = DSHProcessManager(settings: settings)
        self.manager = manager
        let events = await manager.events()
        _ = Task { @MainActor in
            for await event in events {
                self.handle(event: event)
            }
        }

        do {
            let url = try await manager.start()
            logger.info("manager.start() returned url=\(url, privacy: .public)")
            self.lastURL = url
        } catch {
            logger.error("manager.start() failed: \(String(describing: error), privacy: .public)")
            await MainActor.run {
                self.state = .failed(reason: error.localizedDescription)
                self.appendConsole(.shell, text: "[error] \(error.localizedDescription)")
            }
        }
    }

    private func handle(event: DSHProcessEvent) {
        switch event {
        case .launching:
            state = .launching
            appendConsole(.shell, text: "[shell] launching dsh…")
        case .launched(let pid):
            lastChildPID = pid
            appendConsole(.shell, text: "[shell] dsh spawned (pid \(pid))")
        case .stdoutLine(let line):
            appendConsole(.dsh, text: line)
        case .stderrLine(let line):
            appendConsole(.dsh, text: line)
        case .endpointResolved(let url):
            state = .ready(url)
            lastURL = url
            appendConsole(.shell, text: "[shell] endpoint resolved: \(url.absoluteString)")
        case .childExited(let status):
            lastChildPID = nil
            appendConsole(.shell, text: "[shell] dsh exited (status \(status))")
        case .autoRestartScheduled(let after):
            appendConsole(.shell, text: "[shell] auto-restart scheduled in \(Int(after))s")
        case .autoRestartAttempted:
            appendConsole(.shell, text: "[shell] auto-restart attempting")
        case .autoRestartAborted(let reason):
            appendConsole(.shell, text: "[shell] auto-restart aborted: \(reason)")
        }
    }

    private func appendConsole(_ origin: ConsoleLine.Origin, text: String) {
        let line = ConsoleLine(origin: origin, text: text)
        consoleLines.append(line)
        if consoleLines.count > 2000 { consoleLines.removeFirst(consoleLines.count - 2000) }
    }
}
