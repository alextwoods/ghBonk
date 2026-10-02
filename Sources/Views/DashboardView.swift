import AppKit
import SwiftUI

// MARK: - DashboardView

/// Dashboard displaying all tracked PRs grouped by role (Authored / Reviewing).
///
/// Requirements:
/// - 9.1: Displays all tracked PRs grouped by role.
/// - 9.2: Shows PR title, repo name, PR number, state, review status.
/// - 9.3: Shows most recent PR_Event with timestamp.
/// - 9.4: Shows SDK Build status for authored PRs.
/// - 9.5: Clicking a PR opens it in the default browser.
struct DashboardView: View {

    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var controller: AppController
    @State private var isRefreshing = false

    var body: some View {
        Group {
            if appState.trackedPRs.isEmpty {
                emptyStateView
            } else {
                prListView
            }
        }
        .navigationTitle("Dashboard")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task {
                        isRefreshing = true
                        await controller.pollNow()
                        isRefreshing = false
                    }
                } label: {
                    if isRefreshing {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                }
                .disabled(isRefreshing || appState.pollingStatus == .idle)
                .help("Poll GitHub now")
            }
        }
    }

    // MARK: - Computed Groupings

    private var authoredPRs: [TrackedPR] {
        appState.trackedPRs
            .filter { $0.role == .authored }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    private var reviewingPRs: [TrackedPR] {
        appState.trackedPRs
            .filter { $0.role == .reviewing }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    // MARK: - Empty State

    private var emptyStateView: some View {
        VStack(spacing: 12) {
            Image(systemName: "tray")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("No tracked PRs")
                .font(.title2)
                .fontWeight(.medium)
            Text("PRs you author or are assigned to review will appear here once polling begins.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Unread Notifications

    private var unreadNotifications: [NotificationHistoryEntry] {
        appState.notificationHistory
            .filter { $0.disposition == .delivered && !$0.isRead }
            .sorted { $0.timestamp > $1.timestamp }
    }

    // MARK: - PR List

    private var prListView: some View {
        List {
            if !unreadNotifications.isEmpty {
                Section {
                    ForEach(unreadNotifications) { entry in
                        HStack(spacing: 8) {
                            Circle()
                                .fill(.blue)
                                .frame(width: 8, height: 8)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.prTitle)
                                    .font(.callout)
                                    .lineLimit(1)
                                Text(entry.repository.fullName + " · " + entry.summary)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(relativeTime(entry.timestamp))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                            Button {
                                Task { await controller.markOneRead(id: entry.id) }
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.borderless)
                            .help("Dismiss")
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            openNotificationPR(entry)
                        }
                    }

                    Button {
                        Task { await controller.markAllRead() }
                    } label: {
                        Label("Mark All Read", systemImage: "checkmark.circle")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.blue)
                } header: {
                    HStack {
                        Text("New")
                        Spacer()
                        Text("\(unreadNotifications.count)")
                            .font(.caption)
                            .fontWeight(.bold)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.blue.opacity(0.15))
                            .foregroundStyle(.blue)
                            .clipShape(Capsule())
                    }
                }
            }

            if !authoredPRs.isEmpty {
                Section("Authored") {
                    ForEach(authoredPRs) { pr in
                        PRRowView(pr: pr, showSDKBuild: true)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                openPR(pr)
                            }
                    }
                }
            }

            if !reviewingPRs.isEmpty {
                Section("Reviewing") {
                    ForEach(reviewingPRs) { pr in
                        PRRowView(pr: pr, showSDKBuild: false)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                openPR(pr)
                            }
                    }
                }
            }
        }
    }

    // MARK: - Actions

    /// Opens the given PR's GitHub URL in the default browser (Requirement 9.5).
    private func openPR(_ pr: TrackedPR) {
        let urlString = "https://github.com/\(pr.repository.fullName)/pull/\(pr.number)"
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }

    /// Opens the PR associated with a notification in the browser.
    private func openNotificationPR(_ entry: NotificationHistoryEntry) {
        let urlString = "https://github.com/\(entry.repository.fullName)/pull/\(entry.prNumber)"
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }

    private func eventLabel(_ eventType: PREventType) -> String {
        switch eventType {
        case .reviewRequested: return "Review Requested"
        case .reviewSubmitted: return "Review Submitted"
        case .commentAdded: return "Comment"
        case .checkCompleted: return "Check Completed"
        case .prStateChanged: return "State Changed"
        case .prMerged: return "Merged"
        case .newCommitPushed: return "New Commits"
        case .enteredMergeQueue: return "Merge Queue"
        case .mergeQueueFailed: return "Merge Failed"
        }
    }

    private func relativeTime(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - PRRowView

/// A single row in the Dashboard list representing one Tracked PR.
private struct PRRowView: View {

    let pr: TrackedPR
    let showSDKBuild: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Primary line: title
            Text(pr.title)
                .font(.body)
                .fontWeight(.medium)
                .lineLimit(1)

            // Secondary line: repo name, PR number, badges
            HStack(spacing: 8) {
                Text("\(pr.repository.fullName) #\(pr.number)")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                stateBadge

                reviewStatusBadge

                if showSDKBuild {
                    sdkBuildIndicator
                }
            }

            // Latest event with relative timestamp
            if let event = pr.latestEvent {
                HStack(spacing: 4) {
                    Text(event.summary)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)

                    Spacer()

                    Text(relativeTimestamp(for: event.timestamp))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - State Badge

    private var stateBadge: some View {
        Text(pr.state.rawValue.capitalized)
            .font(.caption2)
            .fontWeight(.semibold)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(stateColor.opacity(0.15))
            .foregroundStyle(stateColor)
            .clipShape(Capsule())
    }

    private var stateColor: Color {
        switch pr.state {
        case .open: return .green
        case .draft: return .gray
        case .merged: return .purple
        case .closed: return .red
        case .queued: return .orange
        }
    }

    // MARK: - Review Status Badge

    private var reviewStatusBadge: some View {
        HStack(spacing: 3) {
            reviewStatusIcon
            Text(pr.reviewSummary.displayLabel)
                .font(.caption2)
        }
        .foregroundStyle(reviewStatusColor)
    }

    private var reviewStatusIcon: some View {
        Group {
            switch pr.reviewSummary.status {
            case .approved:
                Image(systemName: "checkmark.circle.fill")
            case .changesRequested:
                Image(systemName: "exclamationmark.circle.fill")
            case .commented:
                Image(systemName: "text.bubble")
            case .pending:
                Image(systemName: "clock")
            }
        }
        .font(.caption2)
    }

    private var reviewStatusColor: Color {
        switch pr.reviewSummary.status {
        case .approved: return .green
        case .changesRequested: return .orange
        case .commented: return .blue
        case .pending: return .secondary
        }
    }

    // MARK: - SDK Build Status Indicator

    @ViewBuilder
    private var sdkBuildIndicator: some View {
        if let status = pr.sdkBuildStatus, status != .notApplicable {
            HStack(spacing: 3) {
                sdkBuildIcon(for: status)
                Text("SDK")
                    .font(.caption2)
            }
            .foregroundStyle(sdkBuildColor(for: status))
        }
    }

    private func sdkBuildIcon(for status: CheckStatus) -> some View {
        Group {
            switch status {
            case .success:
                Image(systemName: "checkmark.circle.fill")
            case .failure:
                Image(systemName: "xmark.circle.fill")
            case .pending:
                Image(systemName: "circle.dotted")
            case .notApplicable:
                Image(systemName: "minus.circle")
            }
        }
        .font(.caption2)
    }

    private func sdkBuildColor(for status: CheckStatus) -> Color {
        switch status {
        case .success: return .green
        case .failure: return .red
        case .pending: return .orange
        case .notApplicable: return .secondary
        }
    }

    // MARK: - Relative Timestamp

    private func relativeTimestamp(for date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
