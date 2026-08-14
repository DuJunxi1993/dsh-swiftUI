import Foundation
import SwiftUI
import DSHShellCore

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
        let manager = DSHProcessManager(settings: settings)
        self.manager = manager
        let events = await manager.events()
        let eventsTask = Task { @MainActor in
            for await event in events {
                self.handle(event: event)
            }
        }
        defer {
            eventsTask.cancel()
            Task { await manager.stop() }
        }

        do {
            let url = try await manager.start()
            self.lastURL = url
        } catch {
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
