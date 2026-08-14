import SwiftUI
import DSHShellCore

/// Top-level scene. Shows one of three states: a loading overlay, the WKWebView,
/// or an error view with a retry button.
struct ShellScene: View {
    @EnvironmentObject private var coordinator: AppCoordinator

    var body: some View {
        ZStack {
            background
            content
        }
        .background(WindowAccessor())
        .toolbar {
            ToolbarItemGroup(placement: .principal) {
                statusBadge
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch coordinator.state {
        case .ready(let url):
            WebSurfaceView(url: url)
                .ignoresSafeArea(edges: .bottom)
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
    }

    private var badgeColor: Color {
        switch coordinator.state {
        case .ready: return .green
        case .failed: return .red
        case .shuttingDown: return .orange
        default: return .yellow
        }
    }

    private var badgeText: String {
        switch coordinator.state {
        case .ready(let url): return "ready · \(url.host ?? url.absoluteString)"
        case .connecting(let host, _): return "connecting · \(host)"
        case .failed: return "failed"
        case .launching: return "launching"
        case .shuttingDown: return "shutting down"
        case .idle: return "idle"
        }
    }
}

private struct WindowAccessor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.titlebarAppearsTransparent = false
            window.title = "dsh"
        }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
