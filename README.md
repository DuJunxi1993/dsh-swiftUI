# dsh-swiftUI

A native macOS shell for the [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) (dsh) web UI.

`dsh` ships its product as a CLI that boots a local HTTP server and serves a SPA front-end. `dsh-swiftUI` wraps that experience in a native SwiftUI application: it owns the window, the menu, the lifecycle, and (once configured) prefers to fork `dsh web` itself, but falls back to connecting to any `dsh web` already running on `127.0.0.1`.

This first milestone delivers **only the main panel** — the WKWebView pointing at the dsh SPA. A roadmap for the future native panels (Git, file tree, in-process terminal) is captured in [`docs/ROADMAP.md`](docs/ROADMAP.md); that work is intentionally deferred.

> **Pure shell.** dsh-swiftUI does not modify dsh, does not bundle dsh, and does not write any dsh client plugin. It talks to dsh the same way a browser does: a single HTTP/WebSocket origin on `127.0.0.1`.

---

## Status

| Stage | State |
|---|---|
| Repository skeleton | ✅ |
| Xcode project (SwiftUI app) | ✅ (text-only `.xcodeproj`; regenerate with the helper script if needed) |
| Swift Package manifest | ✅ |
| `DSHProcessManager` — fork `dsh web`, capture URL, health check, clean shutdown | ✅ |
| `DSHWebView` — `WKWebView` bridged into SwiftUI, console logging, URL forwarding | ✅ |
| Connection-mode fallback (existing on-port service) | ✅ |
| AppKit window with traffic-light + custom toolbar | ✅ |
| Settings (host, port, fork vs. attach, dsh binary path) | ✅ |
| Git / File tree / Terminal panels | ⏳ Roadmap only |

---

## Requirements

- macOS 27 (this repo is built and tested against the macOS 27 SDK shipped with Xcode-beta)
- Xcode-beta (the bundled Swift 6.4 compiler in your installation is the target toolchain)
- A working `dsh` install — `dsh --version` should print `0.1.0-rc.6` or later. The fastest path is `npm install -g @deepseek-ai/dsh` (or `npx @deepseek-ai/dsh`).

dsh itself requires a built front-end (`pnpm run build` from the dsh repo). dsh-swiftUI does **not** ship the dsh dist — it points the embedded `WKWebView` at the URL printed by `dsh web`.

---

## Building

### Option A — open the Xcode project

The Xcode project is generated from [`project.yml`](project.yml) by [XcodeGen](https://github.com/yonaskolb/XcodeGen). On a fresh checkout:

```bash
brew install xcodegen                # one-time
./scripts/generate-xcodeproj.sh      # regenerates App/DSHShell.xcodeproj
open App/DSHShell.xcodeproj
```

Then ⌘R. The first build expects a valid signing identity. For a local-only build set the team to "None" and enable the "Sign to Run Locally" capability.

### Option B — pure Swift Package

```bash
swift build -c release
```

This compiles the `DSHShellCore` library. The SwiftUI app target also lives in the same package and can be built with:

```bash
swift build -c release --target DSHShell
```

If you want a `.app` bundle, use the Xcode project (Option A) or run `./scripts/build-app.sh` (scripts to be added with the first release).

### Pointing at the right SDK

If a `xcodebuild` run fails because multiple Xcode versions are installed, select the beta explicitly:

```bash
sudo xcode-select -s /Applications/Xcode-beta.app/Contents/Developer
```

This is the step that failed inside the sandboxed session that bootstrapped this repo. Run it once on your machine.

---

## Configuration

dsh-swiftUI's preferences are written to `~/Library/Application Support/dsh-swiftUI/settings.json`. The defaults are:

```json
{
  "dshBinaryPath": "/Users/djx/.npm-global/bin/dsh",
  "launchMode": "spawn",
  "listenHost": "127.0.0.1",
  "preferredPort": 0,
  "trustedHosts": ["127.0.0.1", "localhost"],
  "pollIntervalSeconds": 0.5,
  "spawnTimeoutSeconds": 60
}
```

| Field | Meaning |
|---|---|
| `dshBinaryPath` | Absolute path to the `dsh` executable. The app refuses to spawn a non-absolute path. |
| `launchMode` | `spawn` → fork `dsh web` ourselves; `attach` → only connect to an already-running instance. |
| `listenHost` | Local host passed to `dsh web --host`. `0.0.0.0` is intentionally **not** supported (mirrors dsh's own policy). |
| `preferredPort` | `0` → let the OS assign; otherwise the value is forwarded to `dsh web --port`. |
| `trustedHosts` | Hosts appended to `dsh web --trusted-host` (repeatable). |
| `pollIntervalSeconds` | How often the fallback path probes `127.0.0.1` ports when looking for an existing service. |
| `spawnTimeoutSeconds` | How long to wait for the `dsh web:` URL line on stdout before failing. |

---

## Lifecycle

```
+-----------+    run   +----------+    http   +-----------+
| DSHShell  | --------▶ | dsh web  | --------▶ | WKWebView |
| (macOS)   |           | (child)  |           |  + SPA    |
+-----------+            +----------+            +-----------+
       │                       │
       │  app quit / panic    │  crash
       ▼                       ▼
   terminate()             respawn w/ backoff
```

- The app starts in `connecting` state, kicks off `DSHProcessManager`, and transitions to `ready` once it has the URL.
- If `dsh web` exits unexpectedly, the manager schedules a single automatic restart with exponential back-off (capped at 30s); the user sees a native alert and can disable auto-restart.
- On `applicationWillTerminate`, the manager sends `SIGTERM` to the child, escalates to `SIGKILL` after 5s, and waits for the pipe to close.

---

## Architecture

See [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) for the layered view and the rationales for the dsh integration boundaries, the process model, and the App Sandbox stance. The roadmap for native panels lives in [`docs/ROADMAP.md`](docs/ROADMAP.md).

---

## License

MIT. See [`LICENSE`](LICENSE).
