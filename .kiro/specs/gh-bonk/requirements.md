# Requirements Document

## Introduction

ghBonk is a native macOS desktop application that serves as a personal GitHub workflow manager. It monitors pull requests where the user is the author or a directly-assigned reviewer across a configurable set of repositories, providing intelligent desktop notifications and a consolidated dashboard. The application uses periodic polling of the GitHub REST API, persists state locally, and is designed for future expansion (additional repositories, richer filtering rules, and automated build failure investigation).

## Glossary

- **GhBonk**: The native macOS desktop application described by this specification
- **User**: The single person operating GhBonk on their machine
- **PAT**: A GitHub Personal Access Token used to authenticate API requests
- **Authored_PR**: A pull request where the User is the author
- **Reviewing_PR**: A pull request where the User is directly assigned as a reviewer (not via team assignment)
- **Tracked_PR**: The union of Authored_PRs and Reviewing_PRs across all Watched_Repos
- **Watched_Repo**: A GitHub repository that GhBonk monitors, drawn from the Repo_List
- **Repo_List**: The user-configurable set of GitHub repositories to monitor (initially `aws/aws-sdk-java-v2`)
- **Polling_Interval**: The configurable time period between successive GitHub API request cycles
- **Check_Run**: A CI/CD status check associated with a pull request
- **SonarCloud_Check**: The "SonarCloud Code Analysis" check run
- **SDK_Build_Check**: The "Build SDK / aws-sdk-pr-build (pull_request)" check run
- **Filtering_Rule**: A named, toggleable predicate that determines whether a notification is surfaced or suppressed
- **Notification_History**: A persistent log of all notification events and their filter dispositions
- **Dashboard**: The primary UI surface showing the status of all Tracked_PRs
- **PR_Event**: A discrete change in state of a Tracked_PR (e.g., review requested, comment added, check completed)

## Requirements

### Requirement 1 — Authentication

**User Story:** As a user, I want to authenticate with GitHub using a Personal Access Token, so that GhBonk can access my pull request data.

#### Acceptance Criteria

1. THE GhBonk SHALL provide a UI for the User to enter, update, and delete a GitHub PAT.
2. THE GhBonk SHALL store the PAT in the macOS Keychain.
3. WHEN the User submits a PAT, THE GhBonk SHALL validate the token by making a test API call to GitHub and display the result.
4. IF the stored PAT becomes invalid or expired, THEN THE GhBonk SHALL notify the User and disable polling until a valid PAT is provided.

---

### Requirement 2 — Repository Configuration

**User Story:** As a user, I want to configure which repositories GhBonk monitors, so that I only see relevant pull request activity.

#### Acceptance Criteria

1. THE GhBonk SHALL provide a UI for the User to add, remove, and reorder entries in the Repo_List.
2. THE GhBonk SHALL persist the Repo_List to local storage in Application Support.
3. WHEN no Repo_List entries exist, THE GhBonk SHALL display a prompt guiding the User to add a repository.
4. THE GhBonk SHALL include `aws/aws-sdk-java-v2` as the default entry in a fresh Repo_List.
5. WHEN a Repo_List entry is added, THE GhBonk SHALL validate that the repository exists and is accessible with the current PAT.

---

### Requirement 3 — Polling

**User Story:** As a user, I want GhBonk to periodically fetch PR data from GitHub, so that my dashboard and notifications stay current without manual refresh.

#### Acceptance Criteria

1. THE GhBonk SHALL poll the GitHub REST API at the configured Polling_Interval for each Watched_Repo.
2. THE GhBonk SHALL allow the User to configure the Polling_Interval with a minimum of 30 seconds.
3. WHEN a poll cycle completes, THE GhBonk SHALL update local state with any new or changed Tracked_PRs and PR_Events.
4. IF a poll request fails due to a network error, THEN THE GhBonk SHALL retry with exponential backoff up to 3 attempts before reporting the failure to the User.
5. IF a poll request returns an HTTP 403 rate-limit response, THEN THE GhBonk SHALL pause polling until the rate-limit reset time indicated in the response headers.
6. THE GhBonk SHALL identify Authored_PRs by matching the PR author to the authenticated User.
7. THE GhBonk SHALL identify Reviewing_PRs by matching direct reviewer assignments (excluding team-based assignments) to the authenticated User.

---

### Requirement 4 — Desktop Notifications

**User Story:** As a user, I want to receive macOS desktop notifications for important PR events, so that I can respond promptly without constantly checking GitHub.

#### Acceptance Criteria

1. WHEN a new PR_Event matches an active Filtering_Rule, THE GhBonk SHALL deliver a macOS desktop notification containing the PR title, repository name, and event summary.
2. THE GhBonk SHALL allow the User to enable or disable desktop notifications globally.
3. THE GhBonk SHALL allow the User to enable or disable Dock badge count independently of desktop notifications.
4. WHILE desktop notifications are enabled, THE GhBonk SHALL display the count of unread notification-worthy events as a Dock badge.
5. WHEN the User views or dismisses a notification, THE GhBonk SHALL decrement the Dock badge count accordingly.

---

### Requirement 5 — Filtering Rules

**User Story:** As a user, I want configurable filtering rules that control which events generate notifications, so that I am not overwhelmed by noise.

#### Acceptance Criteria

1. THE GhBonk SHALL display all Filtering_Rules in a dedicated UI section with their name, description, and current enabled state.
2. THE GhBonk SHALL allow the User to toggle each Filtering_Rule on or off independently.
3. WHEN a Filtering_Rule is toggled, THE GhBonk SHALL apply the change to subsequent PR_Events without requiring a restart.
4. THE GhBonk SHALL persist Filtering_Rule states across application launches.
5. THE GhBonk SHALL evaluate Filtering_Rules in defined priority order, applying the first matching rule.

---

### Requirement 6 — CI Notifications for Authored PRs

**User Story:** As a user, I want notifications about CI check outcomes on my authored PRs (with sensible exclusions), so that I know immediately when a build needs attention.

#### Acceptance Criteria

1. THE GhBonk SHALL exclude the SonarCloud_Check from all CI notifications regardless of outcome.
2. WHEN any Check_Run (except SonarCloud_Check) on an Authored_PR completes with a failure status, THE GhBonk SHALL generate a notification.
3. WHEN the SDK_Build_Check on an Authored_PR completes with a success status, THE GhBonk SHALL generate a notification.
4. THE GhBonk SHALL suppress success notifications for all Check_Runs other than the SDK_Build_Check.
5. THE GhBonk SHALL NOT generate CI notifications for Reviewing_PRs.

---

### Requirement 7 — Notification Debug Mode

**User Story:** As a user, I want a debug mode that explains why each notification was allowed or blocked, so that I can verify and tune my filtering rules.

#### Acceptance Criteria

1. THE GhBonk SHALL provide a toggle in settings to enable or disable Debug Mode.
2. WHILE Debug Mode is enabled, THE GhBonk SHALL annotate each delivered notification with the name of the Filtering_Rule that allowed it.
3. WHILE Debug Mode is enabled, THE GhBonk SHALL annotate each suppressed event in Notification_History with the name of the Filtering_Rule that blocked it and a human-readable reason.

---

### Requirement 8 — Notification History

**User Story:** As a user, I want to review a history of all notification events (delivered and suppressed), so that I can audit what happened and understand filtering behavior.

#### Acceptance Criteria

1. THE GhBonk SHALL maintain a Notification_History log persisted in local storage.
2. THE GhBonk SHALL provide a UI view listing all entries in Notification_History in reverse chronological order.
3. THE GhBonk SHALL display for each history entry: timestamp, PR title, repository, event type, filter disposition (delivered or suppressed), and the Filtering_Rule that determined the disposition.
4. THE GhBonk SHALL allow the User to filter the Notification_History view by disposition (delivered, suppressed, or all).
5. THE GhBonk SHALL allow the User to clear the Notification_History.

---

### Requirement 9 — Dashboard

**User Story:** As a user, I want a dashboard showing the current state of all my tracked PRs, so that I have a single-pane-of-glass view of my GitHub workflow.

#### Acceptance Criteria

1. THE GhBonk SHALL display a Dashboard listing all Tracked_PRs grouped by role (Authored_PR, Reviewing_PR).
2. THE GhBonk SHALL display for each Tracked_PR: PR title, repository name, PR number, current state (open, draft, merged, closed), and review status summary.
3. THE GhBonk SHALL display the most recent PR_Event for each Tracked_PR with a timestamp and brief description.
4. THE GhBonk SHALL display the status of the SDK_Build_Check for each Authored_PR (pending, success, failure, or not applicable).
5. WHEN the User clicks a Tracked_PR in the Dashboard, THE GhBonk SHALL open the PR in the default web browser.

---

### Requirement 10 — Local Persistence

**User Story:** As a user, I want my settings and cached data to persist across launches, so that GhBonk is ready immediately without re-fetching everything on each start.

#### Acceptance Criteria

1. THE GhBonk SHALL persist all application state (Repo_List, Filtering_Rule states, Polling_Interval, Notification_History, cached PR data) in the macOS Application Support directory.
2. THE GhBonk SHALL use JSON or property list format for persisted data files.
3. WHEN GhBonk launches, THE GhBonk SHALL restore the previously persisted state without requiring a network connection.
4. IF persisted data is corrupted or unreadable, THEN THE GhBonk SHALL reset to defaults and inform the User.

---

### Requirement 11 — Application Lifecycle

**User Story:** As a user, I want GhBonk to behave as a standard macOS Dock application with a window, so that it integrates naturally with my desktop workflow.

#### Acceptance Criteria

1. THE GhBonk SHALL present as a standard macOS Dock application with a main window.
2. WHEN the User closes the main window, THE GhBonk SHALL continue running and polling in the background.
3. WHEN the User clicks the Dock icon while GhBonk is running without a visible window, THE GhBonk SHALL re-open the main window.
4. THE GhBonk SHALL support macOS system launch-at-login configuration.

---

### Requirement 12 — Extensibility for Build Failure Investigation

**User Story:** As a user, I want the architecture to support automated build failure investigation in the future, so that the feature can be added without major restructuring.

#### Acceptance Criteria

1. THE GhBonk SHALL model Check_Run failures as structured data including: check name, failure URL, run ID, and conclusion.
2. THE GhBonk SHALL provide extension points (protocol/interface) for plugging in build failure analysis modules without modifying core polling or notification logic.
3. THE GhBonk SHALL persist raw Check_Run failure payloads for future offline analysis.

---

### Requirement 13 — Technology Constraints

**User Story:** As a developer, I want clear technology constraints documented, so that implementation choices remain consistent.

#### Acceptance Criteria

1. THE GhBonk SHALL be implemented using Swift as the primary programming language.
2. THE GhBonk SHALL use SwiftUI as the primary UI framework with AppKit fallbacks where SwiftUI lacks capability.
3. THE GhBonk SHALL target macOS 14 (Sonoma) or later.
4. THE GhBonk SHALL use the GitHub REST API (not GraphQL) for all data fetching.
5. THE GhBonk SHALL use URLSession for all network requests.
