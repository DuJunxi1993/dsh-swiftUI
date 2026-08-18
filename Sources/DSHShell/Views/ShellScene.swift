import SwiftUI
import DSHShellCore

/// Top-level scene. Shows one of three states: a loading overlay, the WKWebView,
/// or an error view with a retry button. The connection status badge floats in
/// the middle of the (transparent) titlebar, without a toolbar or any material.
struct ShellScene: View {
    @EnvironmentObject private var coordinator: AppCoordinator

    var body: some View {
        ZStack(alignment: .top) {
            background
            content
            statusBadge
                .frame(maxWidth: .infinity, alignment: .top)
                .padding(.top, 6)
                .ignoresSafeArea(edges: .top)
        }
        .background(WindowAccessor())
        .onReceive(coordinator.$webSession) { session in
            guard let window = NSApp.windows.first(where: { $0.isVisible }) else { return }
            if let title = session.title, !title.isEmpty {
                window.title = "\(title) — dsh"
            } else {
                window.title = "dsh"
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch coordinator.state {
        case .ready(let url):
            WebSurfaceView(url: url, bridgeClient: coordinator)
                .ignoresSafeArea(edges: [.top, .bottom])
        case .failed(let reason):
            ErrorView(reason: reason) {
                coordinator.reload()
            }
        case .shuttingDown:
            LoadingView(title: "Shutting down dsh…")
        case .launching:
            LoadingView(title: "Launching dsh web…")
        case .connecting:
            LoadingView(title: "Connecting to existing dsh instance…")
        case .idle:
            LoadingView(title: "Idle")
        }
    }

    private var background: some View {
        Color(nsColor: .windowBackgroundColor)
            .ignoresSafeArea()
    }

    private var statusBadge: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(badgeColor)
                .frame(width: 8, height: 8)
            Text(badgeText)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(
            Capsule()
                .fill(Color(nsColor: .windowBackgroundColor))
        )
    }

    private var badgeColor: Color {
        if coordinator.webSession.agentRunning { return .orange }
        switch coordinator.state {
        case .ready: return .green
        case .failed: return .red
        case .shuttingDown: return .gray
        default: return .yellow
        }
    }

    private var badgeText: String {
        let title = coordinator.webSession.title
        switch coordinator.state {
        case .ready(let url):
            if coordinator.webSession.agentRunning {
                return "thinking · \(title ?? url.host ?? "dsh")"
            }
            return "ready · \(title ?? url.host ?? url.absoluteString)"
        case .connecting(let host, _):
            return "connecting · \(host)"
        case .failed:
            return "failed"
        case .launching:
            return "launching"
        case .shuttingDown:
            return "shutting down"
        case .idle:
            return "idle"
        }
    }
}

private struct WindowAccessor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.styleMask.insert(.fullSizeContentView)
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.title = ""
        }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}