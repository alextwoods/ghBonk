# ghBonk

A native macOS desktop app for managing GitHub PR workflow. Tracks PRs you author or review, monitors CI status, and delivers smart desktop notifications so you never miss a failed build.

Requires macOS 14 (Sonoma) or later.

## Features

- **Dashboard** — All your PRs in one view, grouped by role (authored vs. reviewing)
- **CI Notifications** — Notifies on check failures (and SDK Build success), skips noise like SonarCloud
- **Filtering Rules** — Toggleable rules that control which events fire notifications
- **Debug Mode** — Annotates each notification with the rule that allowed or blocked it
- **Notification History** — Full audit log with disposition filtering

### Notification logic

| Check | Notify on |
|-------|-----------|
| SonarCloud Code Analysis | Never (always excluded) |
| `Build SDK / aws-sdk-pr-build (pull_request)` | Success and failure |
| All other checks | Failure only |

CI notifications only fire for PRs you **author** — not PRs you're reviewing.

## Build & Install

Swift Package Manager project (swift-tools-version 5.9).

```bash
# Development build
swift build

# Run tests (182 tests across 18 suites)
swift test

# Build app bundle (recommended)
./scripts/bundle.sh --release

# Run it
open .build/ghBonk.app

# Install to Applications
cp -R .build/ghBonk.app /Applications/

# clean, install, open
./scripts/bundle.sh --release

rm -rf /Applications/ghBonk.app && cp -R .build/ghBonk.app /Applications/
open /Applications/ghBonk.app
```

The bundle script compiles a release build and wraps it in a proper `.app` bundle with an `Info.plist`. This gives you Dock icon, notifications, badge count, and proper macOS app lifecycle.

For quick iteration during development, `swift build && .build/debug/ghBonk` also works (notifications will be silently unavailable without the bundle).

## Configuration

### First launch

1. Open Settings → Authentication
2. Enter a GitHub Personal Access Token with `repo` scope (read access to repositories, PRs, check runs)

### Settings

| Setting | Default | Notes |
|---------|---------|-------|
| Default repository | `aws/aws-sdk-java-v2` | Pre-configured |
| Polling interval | 60s | Minimum 30s |
| Desktop notifications | On | Toggleable |
| Badge count | On | Toggleable |
| Debug mode | Off | Shows rule evaluation in notifications |
| Launch at Login | Off | Toggleable |

Add more repositories in Settings → Repositories (format: `owner/name`).

## Data storage

| Data | Location |
|------|----------|
| PAT | macOS Keychain (service: `dev.ghbonk.pat`) |
| Settings, repo list, filter rules, notification history, PR cache | `~/Library/Application Support/ghBonk/` (JSON) |
| Check failure payloads | `~/Library/Application Support/ghBonk/check_failures/` |
| Application logs | `~/Library/Application Support/ghBonk/logs/` |
| Raw poll event data | `~/Library/Application Support/ghBonk/events/` |

### Logs

One log file per day at `logs/YYYY-MM-DD.log`. Format:

```
[2024-01-15 10:30:45.123] [INFO] [polling] Poll cycle complete: 2 events, 3 tracked PRs
[2024-01-15 10:30:45.200] [ERROR] [auth] Token validation failed: ...
```

Categories: `lifecycle`, `auth`, `polling`, `general`. Also emitted to OSLog (visible in Console.app).

### Raw event data

Each poll cycle writes a JSON snapshot to `events/YYYY-MM-DD/poll_HHmmss.json` containing:

- Timestamp and counts
- All `PREvent` objects produced by the diff
- Full tracked PR state at that moment

Useful for debugging filtering behavior or replaying events. Inspect with:

```bash
ls ~/Library/Application\ Support/ghBonk/events/$(date +%Y-%m-%d)/
cat ~/Library/Application\ Support/ghBonk/events/$(date +%Y-%m-%d)/poll_*.json | python3 -m json.tool | head -50
```

## Architecture

```
┌─────────────────────────────────────────────────────┐
│                   Presentation Layer                 │
│   SwiftUI Views  │  ViewModels (ObservableObject)   │
├─────────────────────────────────────────────────────┤
│                   Domain Layer                       │
│  PollingEngine │ NotificationEngine │ FilterEngine  │
│  PRClassifier  │ CIEvaluator                        │
├─────────────────────────────────────────────────────┤
│                   Service Layer                      │
│  GitHubAPIClient │ KeychainService │ NotificationSvc│
├─────────────────────────────────────────────────────┤
│                   Persistence Layer                  │
│  PersistenceManager (JSON ↔ Codable)                │
├─────────────────────────────────────────────────────┤
│                   Extension Layer                    │
│  BuildFailureAnalyzer (protocol — future)           │
└─────────────────────────────────────────────────────┘
```

**Key patterns:**

- Swift actors for concurrency safety (PollingEngine, PersistenceManager, NotificationEngine, GitHubAPIClient)
- Protocol-oriented services for testability
- Unidirectional data flow — ViewModels subscribe to AppState
- AppController as composition root

### Source layout

```
Sources/
├── ghBonkApp.swift            # @main entry point + AppDelegate
├── AppController.swift        # Composition root, dependency wiring
├── Domain/                    # Core logic (actors)
├── Services/                  # GitHub API, Keychain, persistence, notifications
├── ViewModels/                # ObservableObject view models + AppState
├── Views/                     # SwiftUI views (NavigationSplitView shell)
└── Models/                    # Domain models, DTOs, settings, errors
```
