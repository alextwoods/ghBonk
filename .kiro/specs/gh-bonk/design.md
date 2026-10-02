# Design Document — ghBonk

## Architecture Overview

ghBonk follows a layered architecture with clear boundaries between networking, domain logic, persistence, and presentation. The app is structured as a single-target macOS application built with SwiftUI and backed by Swift concurrency (async/await, actors) for safe state management.

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
│  BuildFailureAnalyzer (protocol)                    │
└─────────────────────────────────────────────────────┘
```

### Key Architectural Decisions

1. **Actor-based state isolation**: The `PollingEngine` and `PersistenceManager` are Swift actors to prevent data races across polling tasks and UI reads.
2. **Protocol-oriented services**: All external interactions (GitHub API, Keychain, UNUserNotificationCenter) are behind protocols enabling testability via mock injection.
3. **Unidirectional data flow**: ViewModels subscribe to domain layer state published via `@Published` properties. UI never directly mutates domain state.
4. **Single source of truth**: An `AppState` model aggregates all live state (tracked PRs, filter rules, settings). Persistence serialises a snapshot of this model on every mutation.

---

## Components

### 1. GitHubAPIClient

Responsible for all HTTP communication with the GitHub REST API.

```swift
protocol GitHubAPIClientProtocol: Sendable {
    func validateToken(_ token: String) async throws -> GitHubUser
    func fetchPullRequests(repo: Repository) async throws -> [PullRequestDTO]
    func fetchCheckRuns(repo: Repository, ref: String) async throws -> [CheckRunDTO]
    func fetchReviewRequests(repo: Repository, prNumber: Int) async throws -> ReviewRequestsDTO
}

actor GitHubAPIClient: GitHubAPIClientProtocol {
    private let session: URLSession
    private let baseURL: URL = URL(string: "https://api.github.com")!
    private var rateLimitResetDate: Date?

    func validateToken(_ token: String) async throws -> GitHubUser { ... }
    func fetchPullRequests(repo: Repository) async throws -> [PullRequestDTO] { ... }
    func fetchCheckRuns(repo: Repository, ref: String) async throws -> [CheckRunDTO] { ... }
    func fetchReviewRequests(repo: Repository, prNumber: Int) async throws -> ReviewRequestsDTO { ... }
}
```

**Rate limit handling**: After receiving a 403 with `X-RateLimit-Reset`, the client stores the reset `Date` and short-circuits all requests until that time elapses.

**Retry logic**: Network errors trigger up to 3 retries with exponential backoff (1s, 2s, 4s). Rate-limit responses are not retried but deferred.

### 2. KeychainService

Wraps the macOS Security framework for PAT storage.

```swift
protocol KeychainServiceProtocol: Sendable {
    func store(token: String) throws
    func retrieve() throws -> String?
    func delete() throws
}

struct KeychainService: KeychainServiceProtocol {
    private let service = "dev.ghbonk.pat"
    private let account = "github-pat"

    func store(token: String) throws { ... }
    func retrieve() throws -> String? { ... }
    func delete() throws { ... }
}
```

### 3. PollingEngine

Orchestrates periodic fetching, PR classification, and event diffing.

```swift
actor PollingEngine {
    private let apiClient: GitHubAPIClientProtocol
    private let interval: TimeInterval
    private var task: Task<Void, Never>?
    private var previousState: [TrackedPR]

    func start() { ... }
    func stop() { ... }
    func pollOnce() async throws -> [PREvent] { ... }
}
```

The engine runs a `Task` loop that sleeps for `Polling_Interval`, invokes `pollOnce()`, diffs against `previousState`, and emits `PREvent` values to the `NotificationEngine`.

### 4. PRClassifier

Pure function that categorises pull requests.

```swift
struct PRClassifier {
    /// Classifies a PR as authored, reviewing, or irrelevant for the given user.
    static func classify(
        pr: PullRequestDTO,
        reviewRequests: ReviewRequestsDTO,
        currentUser: GitHubUser
    ) -> PRRole?
}

enum PRRole: String, Codable {
    case authored
    case reviewing
}
```

Classification rules:
- `authored`: `pr.user.login == currentUser.login`
- `reviewing`: `reviewRequests.users` contains `currentUser.login` (team-based assignments in `reviewRequests.teams` are excluded)

### 5. CIEvaluator

Pure function that determines whether a CI event warrants a notification.

```swift
struct CINotificationDecision {
    let shouldNotify: Bool
    let reason: String
}

struct CIEvaluator {
    static let sonarCloudCheckName = "SonarCloud Code Analysis"
    static let sdkBuildCheckName = "Build SDK / aws-sdk-pr-build (pull_request)"

    /// Evaluates whether a check run completion should produce a notification.
    static func evaluate(
        checkRun: CheckRunDTO,
        prRole: PRRole
    ) -> CINotificationDecision { ... }
}
```

Decision matrix:

| Check Name | Role | Conclusion | Notify? |
|---|---|---|---|
| SonarCloud* | any | any | No |
| SDK Build | authored | success | Yes |
| SDK Build | authored | failure | Yes |
| Any other | authored | failure | Yes |
| Any other | authored | success | No |
| Any | reviewing | any | No |

### 6. FilterEngine

Evaluates filtering rules in priority order against a PR event.

```swift
struct FilterDecision {
    let disposition: Disposition
    let matchedRule: FilteringRule?
    let reason: String
}

enum Disposition: String, Codable {
    case delivered
    case suppressed
}

struct FilterEngine {
    /// Evaluates rules in priority order. Returns the decision for the first matching rule.
    static func evaluate(
        event: PREvent,
        rules: [FilteringRule],
        debugMode: Bool
    ) -> FilterDecision { ... }
}
```

### 7. NotificationEngine

Bridges domain events to macOS `UNUserNotificationCenter`.

```swift
protocol SystemNotificationService: Sendable {
    func requestAuthorization() async throws -> Bool
    func deliver(notification: NotificationPayload) async throws
    func setBadgeCount(_ count: Int) async throws
}

actor NotificationEngine {
    private let filterEngine: FilterEngine
    private let systemService: SystemNotificationService
    private var unreadCount: Int = 0

    func process(event: PREvent, rules: [FilteringRule], settings: NotificationSettings) async { ... }
    func markRead(count: Int) { ... }
}
```

### 8. PersistenceManager

Handles reading/writing of all local state to `~/Library/Application Support/ghBonk/`.

```swift
actor PersistenceManager {
    private let directory: URL  // Application Support/ghBonk/

    func save<T: Encodable>(_ value: T, to filename: String) throws { ... }
    func load<T: Decodable>(_ type: T.Type, from filename: String) throws -> T { ... }
    func loadOrDefault<T: Codable>(_ type: T.Type, from filename: String, default: T) -> T { ... }
}
```

Files stored:
- `settings.json` — Polling interval, notification toggles, debug mode
- `repos.json` — Repo_List
- `filters.json` — FilteringRule states
- `history.json` — Notification_History entries
- `pr_cache.json` — Cached TrackedPR data
- `check_failures/` — Raw CheckRun failure payloads (one JSON per failure)

### 9. AppState (Observable)

The central observable model that ViewModels consume.

```swift
@MainActor
final class AppState: ObservableObject {
    @Published var trackedPRs: [TrackedPR] = []
    @Published var notificationHistory: [NotificationHistoryEntry] = []
    @Published var filterRules: [FilteringRule] = []
    @Published var repoList: [Repository] = []
    @Published var settings: AppSettings = .default
    @Published var pollingStatus: PollingStatus = .idle
    @Published var authStatus: AuthStatus = .unknown
}
```

---

## Interfaces (Protocols)

### Build Failure Analysis Extension Point

```swift
/// Extension point for future build failure investigation modules.
/// Conforming types can analyze CheckRun failures without modifying
/// core polling or notification logic (Requirement 12.2).
protocol BuildFailureAnalyzer: Sendable {
    /// Analyzes a check run failure and returns investigation results.
    func analyze(failure: CheckRunFailure) async throws -> AnalysisResult
}

struct CheckRunFailure: Codable, Sendable {
    let checkName: String
    let failureURL: URL
    let runID: Int
    let conclusion: String
    let rawPayload: Data  // Persisted for offline analysis (Req 12.3)
}

struct AnalysisResult: Sendable {
    let summary: String
    let suggestedActions: [String]
    let confidence: Double
}
```

---

## Data Models

### Domain Models

```swift
struct Repository: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    let owner: String   // e.g., "aws"
    let name: String    // e.g., "aws-sdk-java-v2"
    var fullName: String { "\(owner)/\(name)" }
    var sortOrder: Int
}

struct TrackedPR: Codable, Identifiable, Sendable {
    let id: String  // "\(repo.fullName)#\(number)"
    let number: Int
    let title: String
    let repository: Repository
    let state: PRState
    let role: PRRole
    let reviewStatus: ReviewStatus
    let sdkBuildStatus: CheckStatus?
    let latestEvent: PREvent?
    let updatedAt: Date
}

enum PRState: String, Codable, Sendable {
    case open, draft, merged, closed
}

enum ReviewStatus: String, Codable, Sendable {
    case pending, approved, changesRequested, commented
}

enum CheckStatus: String, Codable, Sendable {
    case pending, success, failure, notApplicable
}

struct PREvent: Codable, Identifiable, Sendable {
    let id: UUID
    let prIdentifier: String  // TrackedPR.id
    let prTitle: String
    let repository: Repository
    let eventType: PREventType
    let timestamp: Date
    let summary: String
}

enum PREventType: String, Codable, Sendable {
    case reviewRequested
    case reviewSubmitted
    case commentAdded
    case checkCompleted
    case prStateChanged
    case prMerged
}

struct FilteringRule: Codable, Identifiable, Sendable {
    let id: UUID
    let name: String
    let description: String
    let priority: Int
    var isEnabled: Bool
    let predicate: FilterPredicate
}

enum FilterPredicate: Codable, Sendable {
    case eventType(PREventType)
    case ciCheck(checkName: String, conclusion: String?)
    case prRole(PRRole)
    case compound([FilterPredicate], mode: LogicalMode)

    enum LogicalMode: String, Codable, Sendable {
        case allOf, anyOf
    }
}

struct NotificationHistoryEntry: Codable, Identifiable, Sendable {
    let id: UUID
    let timestamp: Date
    let prTitle: String
    let repository: Repository
    let eventType: PREventType
    let disposition: Disposition
    let matchedRuleName: String?
    let reason: String?  // Populated in debug mode
}
```

### Settings Models

```swift
struct AppSettings: Codable, Sendable {
    var pollingInterval: TimeInterval  // >= 30 seconds
    var notificationsEnabled: Bool
    var badgeEnabled: Bool
    var debugMode: Bool
    var launchAtLogin: Bool

    static let `default` = AppSettings(
        pollingInterval: 60,
        notificationsEnabled: true,
        badgeEnabled: true,
        debugMode: false,
        launchAtLogin: false
    )
}

struct NotificationPayload: Sendable {
    let title: String      // PR title
    let subtitle: String   // Repository name
    let body: String       // Event summary
    let debugAnnotation: String?  // Filter rule name in debug mode
    let prURL: URL
}
```

### API DTOs

```swift
struct GitHubUser: Codable, Sendable {
    let login: String
    let id: Int
}

struct PullRequestDTO: Codable, Sendable {
    let number: Int
    let title: String
    let state: String
    let draft: Bool
    let user: GitHubUser
    let headRef: String
    let updatedAt: Date
    let htmlURL: URL
}

struct CheckRunDTO: Codable, Sendable {
    let id: Int
    let name: String
    let status: String       // "completed", "in_progress", "queued"
    let conclusion: String?  // "success", "failure", "neutral", etc.
    let htmlURL: URL
}

struct ReviewRequestsDTO: Codable, Sendable {
    let users: [GitHubUser]
    let teams: [GitHubTeam]
}

struct GitHubTeam: Codable, Sendable {
    let slug: String
    let name: String
}
```

---

## Error Handling

### Error Taxonomy

```swift
enum GhBonkError: Error, LocalizedError {
    // Network
    case networkUnavailable
    case httpError(statusCode: Int, body: String?)
    case rateLimited(resetDate: Date)
    case maxRetriesExceeded(underlyingError: Error)

    // Auth
    case tokenInvalid
    case tokenExpired
    case keychainReadFailed(OSStatus)
    case keychainWriteFailed(OSStatus)

    // Persistence
    case dataCorrupted(filename: String, underlyingError: Error)
    case writeError(filename: String, underlyingError: Error)

    // Validation
    case repositoryNotFound(fullName: String)
    case repositoryNotAccessible(fullName: String)
    case pollingIntervalTooShort(provided: TimeInterval, minimum: TimeInterval)
}
```

### Error Recovery Strategies

| Error Type | Recovery |
|---|---|
| `networkUnavailable` | Retry with exponential backoff (1s, 2s, 4s); after 3 failures, surface to user and pause polling |
| `rateLimited` | Pause polling until `resetDate`; show rate-limit status in UI |
| `tokenInvalid` / `tokenExpired` | Disable polling, show auth error banner, prompt for new PAT |
| `dataCorrupted` | Log the error, reset affected file to defaults, inform user via alert |
| `repositoryNotFound` | Show inline error on the repo list entry; do not add to Repo_List |
| `pollingIntervalTooShort` | Clamp to minimum (30s) and inform user |

### Retry Policy

```swift
struct RetryPolicy {
    let maxAttempts: Int = 3
    let baseDelay: TimeInterval = 1.0
    let multiplier: Double = 2.0

    func delay(for attempt: Int) -> TimeInterval {
        baseDelay * pow(multiplier, Double(attempt))
    }
}
```

---

## Application Lifecycle

1. **Launch**: `PersistenceManager` restores cached state → `AppState` is populated → UI renders immediately from cache. `KeychainService` retrieves PAT. If PAT exists, `PollingEngine.start()` is called.
2. **Window close**: `NSApp.setActivationPolicy(.regular)` remains; the app stays in the Dock; polling continues.
3. **Dock icon click**: `NSApplicationDelegate.applicationShouldHandleReopen` re-opens the main window.
4. **Terminate**: `PersistenceManager` flushes any pending writes synchronously.

---

## Polling Flow

```
┌──────────┐        ┌──────────────┐       ┌────────────────┐
│  Timer   │──tick──▶│ PollingEngine│──API──▶│ GitHubAPIClient│
└──────────┘        └──────┬───────┘       └────────────────┘
                           │ diff
                    ┌──────▼───────┐
                    │ PRClassifier │
                    └──────┬───────┘
                           │ events
                    ┌──────▼───────┐       ┌──────────────┐
                    │ CIEvaluator  │──────▶│ FilterEngine  │
                    └──────────────┘       └──────┬───────┘
                                                  │ decision
                                           ┌──────▼────────────┐
                                           │ NotificationEngine │
                                           └──────┬────────────┘
                                                  │
                                      ┌───────────▼───────────┐
                                      │ UNUserNotificationCenter│
                                      └───────────────────────┘
```

1. Timer fires → `PollingEngine.pollOnce()`
2. For each repo: fetch PRs → classify (authored/reviewing) → fetch check runs for authored PRs
3. Diff against previous state to produce `[PREvent]`
4. For CI events on authored PRs: `CIEvaluator.evaluate()` decides if notification-worthy
5. All notification-worthy events pass through `FilterEngine.evaluate()`
6. Delivered events → `NotificationEngine` → system notification + badge + history entry
7. Suppressed events → history entry only (with debug annotation if enabled)

---

## UI Structure

```
Main Window
├── Sidebar (NavigationSplitView)
│   ├── Dashboard (default)
│   ├── Notification History
│   └── Settings
│       ├── Authentication
│       ├── Repositories
│       ├── Polling
│       ├── Notifications
│       ├── Filtering Rules
│       └── Debug Mode
└── Content Area
    └── (contextual based on sidebar selection)
```

The `Dashboard` view uses a `List` with sections for "Authored" and "Reviewing". Each row shows the PR title, state badge, review status, SDK build status (authored only), and latest event timestamp.

---

## Correctness Properties

*A property is a characteristic or behavior that should hold true across all valid executions of a system — essentially, a formal statement about what the system should do. Properties serve as the bridge between human-readable specifications and machine-verifiable correctness guarantees.*

### Prework Analysis

Acceptance Criteria Testing Prework:

1.1. THE GhBonk SHALL provide a UI for the User to enter, update, and delete a GitHub PAT.
  Thoughts: This is a UI specification. We can verify presence of elements but it's not a computational property.
  Classification: EXAMPLE
  Test Strategy: Verify the settings view contains PAT entry, update, and delete controls.

1.2. THE GhBonk SHALL store the PAT in the macOS Keychain.
  Thoughts: This is about storage mechanism. We can test round-trip: store then retrieve returns the same value. This works for any arbitrary token string.
  Classification: PROPERTY
  Test Strategy: For any valid token string, storing it and then retrieving it should return the same string.

1.3. WHEN the User submits a PAT, THE GhBonk SHALL validate the token by making a test API call to GitHub and display the result.
  Thoughts: This requires an external API call. We test our code's handling of success/failure responses, not GitHub itself.
  Classification: INTEGRATION
  Test Strategy: Mock the API call and verify error/success paths with a few examples.

1.4. IF the stored PAT becomes invalid or expired, THEN THE GhBonk SHALL notify the User and disable polling until a valid PAT is provided.
  Thoughts: This is about a specific state transition. We can test that when the API returns 401, polling stops.
  Classification: EXAMPLE
  Test Strategy: Mock API returning 401, verify polling is disabled and user is notified.

2.1. THE GhBonk SHALL provide a UI for the User to add, remove, and reorder entries in the Repo_List.
  Thoughts: UI specification for CRUD operations.
  Classification: EXAMPLE
  Test Strategy: Verify UI elements exist for adding, removing, reordering.

2.2. THE GhBonk SHALL persist the Repo_List to local storage in Application Support.
  Thoughts: Round-trip property: persisting then loading should return the same list. Works for any valid repo list.
  Classification: PROPERTY
  Test Strategy: For any valid repo list, save then load produces the same list.

2.3. WHEN no Repo_List entries exist, THE GhBonk SHALL display a prompt guiding the User to add a repository.
  Thoughts: Specific UI state for empty list.
  Classification: EXAMPLE
  Test Strategy: Set repo list to empty, verify prompt is displayed.

2.4. THE GhBonk SHALL include `aws/aws-sdk-java-v2` as the default entry in a fresh Repo_List.
  Thoughts: Specific default value check.
  Classification: EXAMPLE
  Test Strategy: Verify default repo list contains the expected entry.

2.5. WHEN a Repo_List entry is added, THE GhBonk SHALL validate that the repository exists and is accessible with the current PAT.
  Thoughts: Requires external API call for validation.
  Classification: INTEGRATION
  Test Strategy: Mock API responses for existing/non-existing repos.

3.1. THE GhBonk SHALL poll the GitHub REST API at the configured Polling_Interval for each Watched_Repo.
  Thoughts: Timing behavior. We can verify the scheduling logic but actual timing is integration.
  Classification: INTEGRATION
  Test Strategy: Verify poll is triggered at configured intervals with mock clock.

3.2. THE GhBonk SHALL allow the User to configure the Polling_Interval with a minimum of 30 seconds.
  Thoughts: Input validation. For any value < 30, it should be rejected or clamped. For any value >= 30, it should be accepted.
  Classification: PROPERTY
  Test Strategy: For any TimeInterval, the system should accept values >= 30 and reject values < 30.

3.3. WHEN a poll cycle completes, THE GhBonk SHALL update local state with any new or changed Tracked_PRs and PR_Events.
  Thoughts: State diffing logic. For any two snapshots of PR data, the diff should correctly identify new and changed PRs.
  Classification: PROPERTY
  Test Strategy: For any pair of (old state, new state), the computed diff should include exactly the PRs that changed.

3.4. IF a poll request fails due to a network error, THEN THE GhBonk SHALL retry with exponential backoff up to 3 attempts before reporting the failure to the User.
  Thoughts: Retry behavior. We can verify the retry count and delay calculation.
  Classification: PROPERTY
  Test Strategy: For any attempt number n (0..2), delay should equal baseDelay * 2^n.

3.5. IF a poll request returns an HTTP 403 rate-limit response, THEN THE GhBonk SHALL pause polling until the rate-limit reset time indicated in the response headers.
  Thoughts: Specific state transition in response to rate limiting.
  Classification: EXAMPLE
  Test Strategy: Feed a 403 with rate-limit headers, verify polling pauses until reset time.

3.6. THE GhBonk SHALL identify Authored_PRs by matching the PR author to the authenticated User.
  Thoughts: Classification logic. For any PR and user, if PR author matches user login, it should be classified as authored.
  Classification: PROPERTY
  Test Strategy: For any (PR, user) pair, PR is authored iff pr.user.login == user.login.

3.7. THE GhBonk SHALL identify Reviewing_PRs by matching direct reviewer assignments (excluding team-based assignments) to the authenticated User.
  Thoughts: Classification logic with exclusion rule. For any review request set, only direct user assignments count.
  Classification: PROPERTY
  Test Strategy: For any (review requests, user), PR is reviewing iff user is in users list and not only in teams list.

4.1. WHEN a new PR_Event matches an active Filtering_Rule, THE GhBonk SHALL deliver a macOS desktop notification containing the PR title, repository name, and event summary.
  Thoughts: This combines filtering evaluation with notification content. We can test that delivered notifications contain required fields.
  Classification: PROPERTY
  Test Strategy: For any delivered notification, the payload contains PR title, repo name, and event summary.

4.2. THE GhBonk SHALL allow the User to enable or disable desktop notifications globally.
  Thoughts: Toggle behavior - specific state.
  Classification: EXAMPLE
  Test Strategy: Toggle notifications off, verify no notifications are delivered.

4.3. THE GhBonk SHALL allow the User to enable or disable Dock badge count independently of desktop notifications.
  Thoughts: Independent toggle behavior.
  Classification: EXAMPLE
  Test Strategy: Verify badge and notification toggles operate independently.

4.4. WHILE desktop notifications are enabled, THE GhBonk SHALL display the count of unread notification-worthy events as a Dock badge.
  Thoughts: Badge count should equal the number of unread events. This is an invariant.
  Classification: PROPERTY
  Test Strategy: For any sequence of notification events, badge count equals number of unread delivered events.

4.5. WHEN the User views or dismisses a notification, THE GhBonk SHALL decrement the Dock badge count accordingly.
  Thoughts: Decrement behavior. Badge should never go negative and should decrease by the count of dismissed notifications.
  Classification: PROPERTY
  Test Strategy: For any badge count N and dismissal count K (K <= N), resulting badge count is N - K.

5.1. THE GhBonk SHALL display all Filtering_Rules in a dedicated UI section with their name, description, and current enabled state.
  Thoughts: UI display requirement.
  Classification: EXAMPLE
  Test Strategy: Verify each rule's name, description, and enabled state are rendered.

5.2. THE GhBonk SHALL allow the User to toggle each Filtering_Rule on or off independently.
  Thoughts: Independence property. Toggling one rule should not affect others.
  Classification: PROPERTY
  Test Strategy: For any rule R in a set of rules, toggling R should not change the enabled state of any other rule.

5.3. WHEN a Filtering_Rule is toggled, THE GhBonk SHALL apply the change to subsequent PR_Events without requiring a restart.
  Thoughts: Live application of rules. After toggling, next event evaluation uses the updated rules.
  Classification: EXAMPLE
  Test Strategy: Toggle a rule, send an event, verify new rule state is applied.

5.4. THE GhBonk SHALL persist Filtering_Rule states across application launches.
  Thoughts: Round-trip persistence, same as repo list.
  Classification: PROPERTY
  Test Strategy: For any set of filter rule states, persisting and loading them should produce identical states.

5.5. THE GhBonk SHALL evaluate Filtering_Rules in defined priority order, applying the first matching rule.
  Thoughts: Priority ordering. For any set of rules where multiple match, the lowest priority number wins.
  Classification: PROPERTY
  Test Strategy: For any event and set of rules where multiple rules match, the decision should come from the highest-priority (lowest number) matching rule.

6.1. THE GhBonk SHALL exclude the SonarCloud_Check from all CI notifications regardless of outcome.
  Thoughts: Absolute exclusion rule. For any outcome, SonarCloud never triggers a notification.
  Classification: PROPERTY
  Test Strategy: For any conclusion value, CIEvaluator with SonarCloud check name should return shouldNotify=false.

6.2. WHEN any Check_Run (except SonarCloud_Check) on an Authored_PR completes with a failure status, THE GhBonk SHALL generate a notification.
  Thoughts: For any non-SonarCloud check with failure on an authored PR, notify.
  Classification: PROPERTY
  Test Strategy: For any check name != SonarCloud and conclusion == failure and role == authored, shouldNotify == true.

6.3. WHEN the SDK_Build_Check on an Authored_PR completes with a success status, THE GhBonk SHALL generate a notification.
  Thoughts: Specific check + specific outcome.
  Classification: EXAMPLE
  Test Strategy: Verify SDK build check with success on authored PR generates notification.

6.4. THE GhBonk SHALL suppress success notifications for all Check_Runs other than the SDK_Build_Check.
  Thoughts: For any check that is not SDK Build, success should not notify. Combined with 6.2 this means only failures notify for non-SDK checks.
  Classification: PROPERTY
  Test Strategy: For any check name != SDK Build and conclusion == success and role == authored, shouldNotify == false.

6.5. THE GhBonk SHALL NOT generate CI notifications for Reviewing_PRs.
  Thoughts: Role-based exclusion. For any check event on a reviewing PR, no notification.
  Classification: PROPERTY
  Test Strategy: For any check run and role == reviewing, shouldNotify == false.

7.1. THE GhBonk SHALL provide a toggle in settings to enable or disable Debug Mode.
  Thoughts: UI toggle, specific state.
  Classification: EXAMPLE
  Test Strategy: Verify debug mode toggle exists and persists.

7.2. WHILE Debug Mode is enabled, THE GhBonk SHALL annotate each delivered notification with the name of the Filtering_Rule that allowed it.
  Thoughts: When debug mode is on, all delivered notifications carry the rule name.
  Classification: PROPERTY
  Test Strategy: For any delivered notification while debug mode is on, the annotation should contain the matched rule name.

7.3. WHILE Debug Mode is enabled, THE GhBonk SHALL annotate each suppressed event in Notification_History with the name of the Filtering_Rule that blocked it and a human-readable reason.
  Thoughts: When debug mode is on, suppressed events have rule name and reason.
  Classification: PROPERTY
  Test Strategy: For any suppressed event while debug mode is on, history entry should contain rule name and non-empty reason.

8.1. THE GhBonk SHALL maintain a Notification_History log persisted in local storage.
  Thoughts: Persistence round-trip.
  Classification: PROPERTY
  Test Strategy: For any list of history entries, persisting and loading should produce the same list.

8.2. THE GhBonk SHALL provide a UI view listing all entries in Notification_History in reverse chronological order.
  Thoughts: Ordering invariant. The displayed list should be sorted by timestamp descending.
  Classification: PROPERTY
  Test Strategy: For any set of history entries, the displayed order should have each entry's timestamp >= the next entry's timestamp.

8.3. THE GhBonk SHALL display for each history entry: timestamp, PR title, repository, event type, filter disposition, and the Filtering_Rule that determined the disposition.
  Thoughts: Display completeness for any entry.
  Classification: PROPERTY
  Test Strategy: For any history entry, the rendered view should include all required fields.

8.4. THE GhBonk SHALL allow the User to filter the Notification_History view by disposition (delivered, suppressed, or all).
  Thoughts: Filter predicate correctness. For any filter value, displayed entries match that disposition.
  Classification: PROPERTY
  Test Strategy: For any disposition filter and history set, all displayed entries should match the selected disposition.

8.5. THE GhBonk SHALL allow the User to clear the Notification_History.
  Thoughts: Specific action with specific outcome.
  Classification: EXAMPLE
  Test Strategy: Clear history, verify list is empty.

9.1. THE GhBonk SHALL display a Dashboard listing all Tracked_PRs grouped by role.
  Thoughts: Grouping invariant. Each PR appears under the correct role section.
  Classification: PROPERTY
  Test Strategy: For any set of tracked PRs, each PR appears exactly once in the section matching its role.

9.2. THE GhBonk SHALL display for each Tracked_PR: PR title, repository name, PR number, current state, and review status summary.
  Thoughts: Display completeness for any PR.
  Classification: PROPERTY
  Test Strategy: For any tracked PR, the rendered row contains all required fields.

9.3. THE GhBonk SHALL display the most recent PR_Event for each Tracked_PR with a timestamp and brief description.
  Thoughts: Most recent event selection.
  Classification: PROPERTY
  Test Strategy: For any tracked PR with events, the displayed event is the one with the most recent timestamp.

9.4. THE GhBonk SHALL display the status of the SDK_Build_Check for each Authored_PR.
  Thoughts: Conditional display based on role.
  Classification: EXAMPLE
  Test Strategy: Verify SDK build status shown for authored PRs, not for reviewing PRs.

9.5. WHEN the User clicks a Tracked_PR in the Dashboard, THE GhBonk SHALL open the PR in the default web browser.
  Thoughts: UI interaction, specific behavior.
  Classification: EXAMPLE
  Test Strategy: Verify click action opens the correct URL.

10.1. THE GhBonk SHALL persist all application state in the macOS Application Support directory.
  Thoughts: Covered by individual persistence tests for each component.
  Classification: PROPERTY
  Test Strategy: Subsumed by individual round-trip tests (2.2, 5.4, 8.1).

10.2. THE GhBonk SHALL use JSON or property list format for persisted data files.
  Thoughts: Format constraint. We can verify written data is valid JSON.
  Classification: PROPERTY
  Test Strategy: For any persisted state, the output file is valid JSON (parseable by JSONDecoder).

10.3. WHEN GhBonk launches, THE GhBonk SHALL restore the previously persisted state without requiring a network connection.
  Thoughts: Offline restore capability. If data exists, it loads without network.
  Classification: INTEGRATION
  Test Strategy: Persist state, disable network mock, launch, verify state is restored.

10.4. IF persisted data is corrupted or unreadable, THEN THE GhBonk SHALL reset to defaults and inform the User.
  Thoughts: Error recovery. For any corrupted data, defaults are restored.
  Classification: PROPERTY
  Test Strategy: For any invalid JSON input, loading should return defaults rather than crash.

11.1–11.4: Application lifecycle behaviors.
  Thoughts: These are macOS integration behaviors (Dock, window management, launch-at-login) that require system-level testing.
  Classification: INTEGRATION / SMOKE
  Test Strategy: Manual verification or UI automation tests.

12.1. THE GhBonk SHALL model Check_Run failures as structured data including: check name, failure URL, run ID, and conclusion.
  Thoughts: Data model completeness. For any check run failure, the struct contains all required fields.
  Classification: PROPERTY
  Test Strategy: For any CheckRunDTO with failure conclusion, the mapped CheckRunFailure contains all four fields.

12.2. THE GhBonk SHALL provide extension points for plugging in build failure analysis modules without modifying core polling or notification logic.
  Thoughts: Architectural constraint, not runtime testable as a property.
  Classification: SMOKE
  Test Strategy: Verify protocol exists and can be conformed to without modifying core modules.

12.3. THE GhBonk SHALL persist raw Check_Run failure payloads for future offline analysis.
  Thoughts: Round-trip persistence of raw data.
  Classification: PROPERTY
  Test Strategy: For any raw check run payload, persisting and reading back should produce identical bytes.

13.1–13.5: Technology constraints.
  Thoughts: These are build-time constraints, not runtime properties.
  Classification: SMOKE
  Test Strategy: Verified by project configuration (Xcode project settings, deployment target, imports).

### Property Reflection

After reviewing the prework, I identify the following consolidations:

1. **Persistence round-trips** (1.2, 2.2, 5.4, 8.1, 10.1, 10.2, 12.3): These can be unified into a single property — "for any Codable app state component, serializing then deserializing produces an equivalent value." However, since they test different model types, I'll keep one general property plus note that it covers all persistence requirements.

2. **PR classification** (3.6, 3.7): These are two facets of the same classifier function. I'll combine into a single comprehensive property about classification correctness.

3. **CI notification evaluation** (6.1, 6.2, 6.4, 6.5): These all describe facets of `CIEvaluator.evaluate()`. I can express them as one property with the complete decision matrix, but since SonarCloud exclusion and role-based exclusion are independent concerns, I'll keep them as separate properties for clarity. However, 6.2 and 6.4 together form "non-SonarCloud check notification depends on conclusion: failure notifies, success doesn't (except SDK Build)." I'll combine 6.2 and 6.4 into one property.

4. **Badge count invariants** (4.4, 4.5): These describe the same counter invariant. Combine into one property about badge count consistency.

5. **Debug mode annotations** (7.2, 7.3): These both describe annotation behavior in debug mode. Combine into one property covering both delivered and suppressed cases.

6. **History display properties** (8.2, 8.3): These are about the same view but test different aspects (ordering vs. completeness). Keep separate as they validate different concerns.

7. **Dashboard display** (9.1, 9.2, 9.3): 9.1 (grouping) and 9.2 (field completeness) test different aspects. 9.3 (most recent event) is a distinct computation. Keep separate.

---

### Property 1: Persistence round-trip

*For any* valid `Codable` application state component (Repository list, FilteringRule set, NotificationHistory, AppSettings, CheckRunFailure payload), serializing to JSON and then deserializing should produce a value equal to the original.

**Validates: Requirements 1.2, 2.2, 5.4, 8.1, 10.1, 10.2, 12.3**

### Property 2: Corrupted data recovery

*For any* byte sequence that is not valid JSON for the expected type, the persistence layer should return the default value for that type rather than crash or propagate an error to the UI.

**Validates: Requirements 10.4**

### Property 3: Polling interval validation

*For any* `TimeInterval` value, the system should accept values >= 30 seconds and reject (or clamp to 30) values below 30 seconds.

**Validates: Requirements 3.2**

### Property 4: Exponential backoff delay calculation

*For any* retry attempt number `n` in range [0, 2], the computed delay should equal `baseDelay * 2^n` (i.e., 1s, 2s, 4s with the default policy).

**Validates: Requirements 3.4**

### Property 5: PR classification correctness

*For any* pull request DTO, review requests DTO, and authenticated user: the PR is classified as `authored` if and only if `pr.user.login == currentUser.login`; it is classified as `reviewing` if and only if `currentUser.login` appears in `reviewRequests.users` (not via `reviewRequests.teams`); otherwise it is untracked.

**Validates: Requirements 3.6, 3.7**

### Property 6: State diff completeness

*For any* pair of PR snapshots (previous and current), the computed list of `PREvent` values includes exactly one event for each PR that was added, removed, or changed between the two snapshots, and no events for unchanged PRs.

**Validates: Requirements 3.3**

### Property 7: SonarCloud exclusion

*For any* `CheckRunDTO` whose name matches "SonarCloud Code Analysis" and *for any* conclusion value and *for any* PR role, `CIEvaluator.evaluate()` should return `shouldNotify == false`.

**Validates: Requirements 6.1**

### Property 8: CI notification decision matrix for authored PRs

*For any* `CheckRunDTO` whose name is not "SonarCloud Code Analysis" on an authored PR: if conclusion is `failure`, `shouldNotify` is `true`; if conclusion is `success` and the check name is "Build SDK / aws-sdk-pr-build (pull_request)", `shouldNotify` is `true`; if conclusion is `success` and the check name is anything else, `shouldNotify` is `false`.

**Validates: Requirements 6.2, 6.3, 6.4**

### Property 9: No CI notifications for reviewing PRs

*For any* `CheckRunDTO` and `prRole == .reviewing`, `CIEvaluator.evaluate()` should return `shouldNotify == false`.

**Validates: Requirements 6.5**

### Property 10: Filter rule priority ordering

*For any* `PREvent` and *for any* set of `FilteringRule` values where two or more rules match the event, `FilterEngine.evaluate()` should return the decision of the matching rule with the lowest `priority` value (highest priority).

**Validates: Requirements 5.5**

### Property 11: Filter rule toggle independence

*For any* set of filtering rules and *for any* single rule toggled, the enabled states of all other rules remain unchanged.

**Validates: Requirements 5.2**

### Property 12: Badge count invariant

*For any* sequence of notification deliveries (each incrementing the badge) and dismissals (each decrementing the badge), the badge count at any point should equal `totalDelivered - totalDismissed`, and should never be negative.

**Validates: Requirements 4.4, 4.5**

### Property 13: Notification payload completeness

*For any* delivered notification (disposition == `.delivered`), the `NotificationPayload` should contain a non-empty PR title, a non-empty repository name, and a non-empty event summary.

**Validates: Requirements 4.1**

### Property 14: Debug mode annotation completeness

*For any* filter evaluation while debug mode is enabled: if disposition is `delivered`, the result contains a non-nil `matchedRuleName`; if disposition is `suppressed`, the history entry contains a non-nil `matchedRuleName` and a non-empty `reason` string.

**Validates: Requirements 7.2, 7.3**

### Property 15: Notification history ordering

*For any* set of `NotificationHistoryEntry` values, the history view presents them in reverse chronological order (each entry's timestamp >= the next entry's timestamp in display order).

**Validates: Requirements 8.2**

### Property 16: History disposition filter correctness

*For any* disposition filter value (delivered, suppressed, or all) and *for any* set of history entries, the filtered view contains exactly those entries whose disposition matches the filter (or all entries when filter is "all").

**Validates: Requirements 8.4**

### Property 17: Dashboard grouping correctness

*For any* set of tracked PRs, each PR appears exactly once in the Dashboard, placed in the section corresponding to its role (authored or reviewing).

**Validates: Requirements 9.1**

### Property 18: Most recent event selection

*For any* tracked PR with one or more associated events, the event displayed on the Dashboard is the one with the maximum timestamp among all events for that PR.

**Validates: Requirements 9.3**

### Property 19: CheckRunFailure model completeness

*For any* `CheckRunDTO` with a failure conclusion, mapping it to a `CheckRunFailure` produces a struct where `checkName`, `failureURL`, `runID`, and `conclusion` are all populated (non-nil, non-empty).

**Validates: Requirements 12.1**
