# Implementation Plan: ghBonk

## Overview

Build a native macOS (14+) desktop application in Swift/SwiftUI that monitors GitHub pull requests across configurable repositories, delivers intelligent desktop notifications for CI and review events, and persists all state locally. Implementation follows the layered architecture: Service → Domain → Presentation, with protocol-oriented abstractions for testability.

## Tasks

- [x] 1. Set up Xcode project structure, targets, and core model types
  - [x] 1.1 Create the Xcode project and directory structure
    - Create a macOS App target named `ghBonk` with SwiftUI lifecycle, deployment target macOS 14
    - Establish directory layout: `Sources/Models/`, `Sources/Services/`, `Sources/Domain/`, `Sources/ViewModels/`, `Sources/Views/`, `Tests/`
    - Add a `Package.swift` or Xcode project with a unit test target
    - _Requirements: 13.1, 13.2, 13.3_

  - [x] 1.2 Define all domain models and DTOs
    - Implement `Repository`, `TrackedPR`, `PRState`, `PRRole`, `ReviewStatus`, `CheckStatus` as per design
    - Implement `PREvent`, `PREventType`, `FilteringRule`, `FilterPredicate`, `Disposition`
    - Implement `NotificationHistoryEntry`, `AppSettings`, `NotificationPayload`
    - Implement API DTOs: `GitHubUser`, `PullRequestDTO`, `CheckRunDTO`, `ReviewRequestsDTO`, `GitHubTeam`
    - Implement `CheckRunFailure`, `AnalysisResult`, and `BuildFailureAnalyzer` protocol
    - Implement `GhBonkError` enum with all error cases
    - Implement `RetryPolicy` struct
    - All types must conform to `Codable`, `Sendable`, and `Identifiable` where specified in the design
    - _Requirements: 12.1, 12.2, 10.2_

  - [x] 1.3 Write property tests for model serialization round-trips
    - **Property 1: Persistence round-trip** — For any valid Codable model instance, encoding to JSON and decoding should produce an equal value
    - **Property 2: Corrupted data recovery** — For any invalid JSON, decoding should return defaults rather than crash
    - **Validates: Requirements 1.2, 2.2, 5.4, 8.1, 10.1, 10.2, 10.4, 12.3**

- [x] 2. Implement service layer (Keychain, Persistence, GitHub API)
  - [x] 2.1 Implement KeychainService
    - Define `KeychainServiceProtocol` with `store`, `retrieve`, `delete` methods
    - Implement `KeychainService` struct wrapping Security framework with service name `dev.ghbonk.pat` and account `github-pat`
    - Map `OSStatus` errors to `GhBonkError.keychainReadFailed` / `keychainWriteFailed`
    - _Requirements: 1.1, 1.2_

  - [x] 2.2 Implement PersistenceManager
    - Define as a Swift actor to prevent data races
    - Use `~/Library/Application Support/ghBonk/` as the storage directory, creating it on first use
    - Implement generic `save<T: Encodable>`, `load<T: Decodable>`, and `loadOrDefault<T: Codable>` methods
    - Handle file I/O errors by mapping to `GhBonkError.dataCorrupted` / `writeError`
    - On corrupted data, return defaults and log the error (per requirement 10.4)
    - Store files: `settings.json`, `repos.json`, `filters.json`, `history.json`, `pr_cache.json`, `check_failures/`
    - _Requirements: 10.1, 10.2, 10.3, 10.4_

  - [x] 2.3 Write property tests for PersistenceManager
    - **Property 1: Persistence round-trip** — save then load for each model type produces equal value
    - **Property 2: Corrupted data recovery** — corrupted file returns defaults
    - **Validates: Requirements 10.1, 10.2, 10.4**

  - [x] 2.4 Implement GitHubAPIClient
    - Define `GitHubAPIClientProtocol` with methods: `validateToken`, `fetchPullRequests`, `fetchCheckRuns`, `fetchReviewRequests`
    - Implement as a Swift actor using `URLSession` for all requests
    - Set `Authorization: Bearer <token>` header, `Accept: application/vnd.github+json`, `X-GitHub-Api-Version: 2022-11-28`
    - Parse `X-RateLimit-Reset` on 403 responses and store `rateLimitResetDate`; short-circuit requests until that time
    - Implement retry logic: up to 3 retries with exponential backoff (1s, 2s, 4s) for network errors; no retry for rate-limit responses
    - Map HTTP errors to appropriate `GhBonkError` cases
    - Decode JSON responses into DTO types using `JSONDecoder` with `.iso8601` date strategy
    - _Requirements: 13.4, 13.5, 3.4, 3.5, 1.3_

  - [x] 2.5 Write property tests for retry delay calculation
    - **Property 4: Exponential backoff delay** — For any attempt n in [0,2], delay equals `baseDelay * 2^n`
    - **Validates: Requirements 3.4**

- [x] 3. Implement domain layer (PRClassifier, CIEvaluator, FilterEngine)
  - [x] 3.1 Implement PRClassifier
    - Implement `PRClassifier.classify(pr:reviewRequests:currentUser:)` as a static pure function
    - Return `.authored` if `pr.user.login == currentUser.login`
    - Return `.reviewing` if `currentUser.login` is in `reviewRequests.users` (exclude team-based via `reviewRequests.teams`)
    - Return `nil` if neither condition holds
    - _Requirements: 3.6, 3.7_

  - [x] 3.2 Write property tests for PRClassifier
    - **Property 5: PR classification correctness** — For any (PR, reviewRequests, user) triple, classification follows the authored/reviewing/nil rules exactly
    - **Validates: Requirements 3.6, 3.7**

  - [x] 3.3 Implement CIEvaluator
    - Implement `CIEvaluator.evaluate(checkRun:prRole:)` as a static pure function
    - SonarCloud check ("SonarCloud Code Analysis") always returns `shouldNotify = false`
    - Any check on a reviewing PR returns `shouldNotify = false`
    - SDK Build check ("Build SDK / aws-sdk-pr-build (pull_request)") on authored PR: notify for both success and failure
    - Any other check on authored PR: notify only for failure, suppress success
    - Return a `CINotificationDecision` with `shouldNotify` and `reason`
    - _Requirements: 6.1, 6.2, 6.3, 6.4, 6.5_

  - [x] 3.4 Write property tests for CIEvaluator
    - **Property 7: SonarCloud exclusion** — For any conclusion and role, SonarCloud never notifies
    - **Property 8: CI notification matrix for authored PRs** — Failure always notifies (non-SonarCloud); SDK Build success notifies; other success doesn't
    - **Property 9: No CI notifications for reviewing PRs** — Any check with role reviewing returns false
    - **Validates: Requirements 6.1, 6.2, 6.3, 6.4, 6.5**

  - [x] 3.5 Implement FilterEngine
    - Implement `FilterEngine.evaluate(event:rules:debugMode:)` as a static function
    - Sort rules by `priority` ascending, evaluate predicates in order, return decision from first match
    - Support `FilterPredicate` cases: `.eventType`, `.ciCheck`, `.prRole`, `.compound` (allOf/anyOf)
    - Return `FilterDecision` with disposition, matched rule reference, and reason (populated when `debugMode` is true)
    - If no rule matches, default disposition is `.delivered`
    - _Requirements: 5.5, 7.2, 7.3_

  - [x] 3.6 Write property tests for FilterEngine
    - **Property 10: Filter rule priority ordering** — When multiple rules match, the lowest priority number wins
    - **Property 11: Filter rule toggle independence** — Toggling one rule does not change other rules' states
    - **Property 14: Debug mode annotation completeness** — Delivered events have matched rule name; suppressed events have rule name and reason
    - **Validates: Requirements 5.2, 5.5, 7.2, 7.3**

- [x] 4. Checkpoint
  - Ensure all tests pass, ask the user if questions arise.

- [x] 5. Implement PollingEngine and NotificationEngine
  - [x] 5.1 Implement PollingEngine
    - Define as a Swift actor
    - Accept `GitHubAPIClientProtocol`, polling interval, and repo list
    - Implement `start()` that spawns a `Task` loop: sleep for interval → `pollOnce()` → emit events
    - Implement `stop()` to cancel the running task
    - `pollOnce()` fetches PRs for each repo, classifies them via `PRClassifier`, fetches check runs for authored PRs, diffs against `previousState` to produce `[PREvent]`
    - Validate polling interval >= 30s, clamp if below (emit `pollingIntervalTooShort` warning)
    - Handle API errors per retry policy and rate-limit logic
    - _Requirements: 3.1, 3.2, 3.3, 3.4, 3.5_

  - [x] 5.2 Write property tests for polling interval validation and state diff
    - **Property 3: Polling interval validation** — Values >= 30 accepted, values < 30 rejected/clamped
    - **Property 6: State diff completeness** — For any (old, new) PR snapshots, diff produces exactly one event per changed PR
    - **Validates: Requirements 3.2, 3.3**

  - [x] 5.3 Implement NotificationEngine
    - Define as a Swift actor
    - Accept `SystemNotificationService` protocol and `FilterEngine`
    - `process(event:rules:settings:)` evaluates event through `FilterEngine`, then:
      - If delivered and `settings.notificationsEnabled`: call `systemService.deliver(notification:)`
      - Increment badge count and call `systemService.setBadgeCount()` if `settings.badgeEnabled`
      - Record `NotificationHistoryEntry` with disposition and debug annotations
    - If suppressed: record history entry only (with reason if debug mode)
    - `markRead(count:)` decrements badge count, clamps at 0
    - _Requirements: 4.1, 4.2, 4.3, 4.4, 4.5, 7.2, 7.3, 8.1_

  - [x] 5.4 Write property tests for badge count invariant
    - **Property 12: Badge count invariant** — After any sequence of deliveries and dismissals, badge = delivered - dismissed, never negative
    - **Property 13: Notification payload completeness** — Delivered notifications have non-empty title, repo name, and summary
    - **Validates: Requirements 4.1, 4.4, 4.5**

  - [x] 5.5 Implement SystemNotificationService
    - Define `SystemNotificationService` protocol (as in design)
    - Implement concrete `UNNotificationService` wrapping `UNUserNotificationCenter`
    - `requestAuthorization()` requests `.alert, .badge, .sound` permissions
    - `deliver(notification:)` creates `UNMutableNotificationContent` from `NotificationPayload`, including debug annotation as subtitle if present
    - `setBadgeCount(_:)` updates the app badge
    - _Requirements: 4.1, 4.4_

- [x] 6. Implement AppState and ViewModels
  - [x] 6.1 Implement AppState observable model
    - Create `@MainActor` class conforming to `ObservableObject`
    - Define `@Published` properties: `trackedPRs`, `notificationHistory`, `filterRules`, `repoList`, `settings`, `pollingStatus`, `authStatus`
    - Add `enum PollingStatus`: `idle`, `polling`, `paused(reason)`, `error(String)`
    - Add `enum AuthStatus`: `unknown`, `authenticated(GitHubUser)`, `invalid`, `expired`
    - Wire to `PersistenceManager` to save state on each mutation
    - _Requirements: 10.1, 10.3_

  - [x] 6.2 Implement ViewModels
    - `DashboardViewModel`: groups tracked PRs by role, exposes sorted lists, handles PR click (open URL in browser)
    - `SettingsViewModel`: manages PAT entry/validation/deletion, repo list CRUD, polling interval configuration, notification toggles, debug mode toggle, launch-at-login
    - `HistoryViewModel`: exposes filtered and sorted notification history, supports disposition filter and clear action
    - `FilterRulesViewModel`: exposes rules list, handles toggle enable/disable for individual rules
    - All ViewModels observe `AppState` and delegate mutations through domain services
    - _Requirements: 1.1, 2.1, 5.1, 5.2, 7.1, 8.2, 8.4, 8.5, 9.1, 9.5_

- [x] 7. Implement SwiftUI views
  - [x] 7.1 Implement app entry point and main window structure
    - Create `@main` App struct with `WindowGroup`
    - Implement `NavigationSplitView` with sidebar (Dashboard, History, Settings sections)
    - Handle `NSApplicationDelegate` via `@NSApplicationDelegateAdaptor` for lifecycle events:
      - `applicationShouldHandleReopen` to re-open main window
      - Continue polling on window close
    - _Requirements: 11.1, 11.2, 11.3_

  - [x] 7.2 Implement Dashboard view
    - List sections for "Authored" and "Reviewing" PRs
    - Each row: PR title, repo name, PR number, state badge (open/draft/merged/closed), review status
    - Show SDK Build status for authored PRs (pending/success/failure/not applicable)
    - Show most recent event with timestamp
    - Tap action opens PR URL in default browser via `NSWorkspace.shared.open()`
    - Show empty state prompt when no tracked PRs exist
    - _Requirements: 9.1, 9.2, 9.3, 9.4, 9.5_

  - [x] 7.3 Implement Settings views
    - Authentication section: PAT text field (secure), validate button, status indicator, delete button
    - Repositories section: list with add/remove/reorder, "owner/name" text field, validation on add
    - Polling section: interval picker (minimum 30s)
    - Notifications section: global toggle, badge toggle (independent)
    - Filtering Rules section: list with name, description, enabled toggle per rule
    - Debug Mode section: toggle with explanation text
    - Launch at Login section: toggle using `SMAppService`
    - Show empty repo list prompt per requirement 2.3
    - Include default repo `aws/aws-sdk-java-v2` in fresh install
    - _Requirements: 1.1, 2.1, 2.3, 2.4, 2.5, 3.2, 4.2, 4.3, 5.1, 5.2, 7.1, 11.4_

  - [x] 7.4 Implement Notification History view
    - List entries in reverse chronological order
    - Each row: timestamp, PR title, repository, event type, disposition badge (delivered/suppressed), matched rule name
    - Segmented control or picker for disposition filter (All / Delivered / Suppressed)
    - Clear history button with confirmation
    - Show debug annotations (rule name, reason) when debug mode is active
    - _Requirements: 8.2, 8.3, 8.4, 8.5, 7.3_

- [x] 8. Checkpoint
  - Ensure all tests pass, ask the user if questions arise.

- [x] 9. Wire components together and implement application lifecycle
  - [x] 9.1 Wire dependency graph and app initialization
    - In the App `init` or a composition root: instantiate `PersistenceManager`, `KeychainService`, `GitHubAPIClient`, `PollingEngine`, `NotificationEngine`, `AppState`
    - On launch: restore persisted state into `AppState`, retrieve PAT from Keychain
    - If PAT exists: validate → set `authStatus` → start polling
    - If no PAT: set `authStatus = .unknown`, show auth prompt
    - Pass protocol-typed dependencies into ViewModels
    - _Requirements: 10.3, 11.1_

  - [x] 9.2 Implement polling-to-notification pipeline
    - Connect `PollingEngine` event output → `CIEvaluator` (for check events on authored PRs) → `NotificationEngine.process()`
    - Update `AppState.trackedPRs` on each poll cycle
    - Update `AppState.pollingStatus` to reflect current state (polling, paused, error)
    - Persist updated PR cache and notification history after each cycle
    - _Requirements: 3.1, 3.3, 4.1, 6.1, 6.2, 6.3, 6.4, 6.5, 8.1_

  - [x] 9.3 Implement application lifecycle behavior
    - Configure app to remain running when window closes (no `NSApp.terminate`)
    - Implement `applicationShouldHandleReopen` to recreate/show main window
    - Implement Launch at Login using `SMAppService.mainApp` (macOS 13+)
    - On termination: flush any pending persistence writes
    - _Requirements: 11.2, 11.3, 11.4_

  - [x] 9.4 Implement notification interaction handling
    - Set up `UNUserNotificationCenterDelegate` to handle notification taps
    - On notification tap: open PR URL in browser, decrement badge count
    - On notification dismiss: decrement badge count
    - _Requirements: 4.5, 9.5_

- [x] 10. Implement Check_Run failure persistence and extensibility
  - [x] 10.1 Implement CheckRunFailure mapping and persistence
    - Map `CheckRunDTO` failures to `CheckRunFailure` structs (checkName, failureURL, runID, conclusion, rawPayload)
    - Persist raw JSON payload to `check_failures/` directory as individual files (one per failure, named by runID)
    - Wire into polling pipeline: when a check completes with failure on an authored PR, save the failure payload
    - _Requirements: 12.1, 12.3_

  - [x] 10.2 Write property test for CheckRunFailure model completeness
    - **Property 19: CheckRunFailure model completeness** — For any CheckRunDTO with failure conclusion, mapped CheckRunFailure has all required fields populated
    - **Validates: Requirements 12.1**

- [x] 11. Final checkpoint
  - Ensure all tests pass, ask the user if questions arise.

## Notes

- Tasks marked with `*` are optional and can be skipped for faster MVP
- Each task references specific requirements for traceability
- Checkpoints ensure incremental validation
- Property tests validate universal correctness properties from the design document
- Unit tests validate specific examples and edge cases
- The app uses Swift concurrency (actors, async/await) throughout — no Combine or GCD
- All protocols enable mock injection for testing without hitting the real GitHub API
- The `BuildFailureAnalyzer` protocol (Req 12.2) is defined in task 1.2 but no concrete implementation is built — it is an extension point for future work

## Task Dependency Graph

```json
{
  "waves": [
    { "id": 0, "tasks": ["1.1"] },
    { "id": 1, "tasks": ["1.2"] },
    { "id": 2, "tasks": ["1.3", "2.1", "2.2", "2.4"] },
    { "id": 3, "tasks": ["2.3", "2.5", "3.1", "3.3", "3.5"] },
    { "id": 4, "tasks": ["3.2", "3.4", "3.6", "5.1", "5.3", "5.5"] },
    { "id": 5, "tasks": ["5.2", "5.4", "6.1"] },
    { "id": 6, "tasks": ["6.2"] },
    { "id": 7, "tasks": ["7.1", "7.2", "7.3", "7.4"] },
    { "id": 8, "tasks": ["9.1"] },
    { "id": 9, "tasks": ["9.2", "9.3", "9.4", "10.1"] },
    { "id": 10, "tasks": ["10.2"] }
  ]
}
```
