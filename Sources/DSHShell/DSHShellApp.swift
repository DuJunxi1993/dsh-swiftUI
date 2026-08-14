import SwiftUI
import DSHShellCore

@main
struct DSHShellApp: App {
    @StateObject private var coordinator = AppCoordinator()

    var body: some Scene {
        WindowGroup("dsh") {
            ShellScene()
                .environmentObject(coordinator)
                .frame(minWidth: 800, minHeight: 600)
                .onAppear { coordinator.start() }
                .onDisappear { coordinator.shutdown() }
        }
        .windowToolbarStyle(.unified(showsTitle: true))
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About dsh-swiftUI") {
                    NSApp.orderFrontStandardAboutPanel(nil)
                }
            }
            CommandGroup(after: .windowArrangement) {
                Button("Reload dsh") {
                    coordinator.reload()
                }
                .keyboardShortcut("r", modifiers: [.command])
            }
            CommandGroup(after: .windowList) {
                Button("Open Preferences…") {
                    coordinator.showPreferences()
                }
                .keyboardShortcut(",", modifiers: [.command])
            }
        }

        Settings {
            PreferencesView()
                .environmentObject(coordinator)
        }
    }
}
