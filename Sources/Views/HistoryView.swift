import SwiftUI
import AppKit

// MARK: - HistoryView

/// Notification History view listing all notification events in reverse chronological order.
///
/// Requirements:
/// - 8.2: Lists all notification history in reverse chronological order.
/// - 8.3: Each entry shows timestamp, PR title, repository, event type, disposition, matched rule name.
/// - 8.4: Allows filtering by disposition (delivered, suppressed, or all).
/// - 8.5: Allows clearing the history.
/// - 7.3: Shows debug annotations (rule name, reason) when debug mode is active.
struct HistoryView: View {

    @EnvironmentObject private var appState: AppState
    @StateObject private var viewModel: HistoryViewModel
    @State private var showClearConfirmation = false

    init(appState: AppState) {
        _viewModel = StateObject(wrappedValue: HistoryViewModel(appState: appState))
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()

            if viewModel.filteredHistory.isEmpty {
                emptyStateView
            } else {
                historyListView
            }
        }
        .navigationTitle("Notification History")
        .task {
            viewModel.refresh()
        }
        .onReceive(appState.$notificationHistory) { _ in
            viewModel.refresh()
        }
        .alert("Clear History", isPresented: $showClearConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Clear", role: .destructive) {
                viewModel.clearHistory()
            }
        } message: {
            Text("Are you sure you want to clear all notification history? This cannot be undone.")
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack {
            Picker("Filter", selection: $viewModel.dispositionFilter) {
                ForEach(HistoryViewModel.DispositionFilter.allCases, id: \.self) { filter in
                    Text(filter.rawValue.capitalized).tag(filter)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 240)
            .onChange(of: viewModel.dispositionFilter) { _, _ in
                viewModel.refresh()
            }

            Spacer()

            Button(role: .destructive) {
                showClearConfirmation = true
            } label: {
                Label("Clear History", systemImage: "trash")
            }
            .disabled(appState.notificationHistory.isEmpty)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    // MARK: - Empty State

    private var emptyStateView: some View {
        VStack(spacing: 12) {
            Image(systemName: "clock.badge.questionmark")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("No notification history yet")
                .font(.title2)
                .fontWeight(.medium)
            Text("Notification events will appear here as GhBonk monitors your pull requests.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - History List

    private var historyListView: some View {
        List {
            ForEach(viewModel.filteredHistory) { entry in
                HistoryRowView(entry: entry, debugMode: appState.settings.debugMode)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        openPR(entry)
                    }
            }
        }
    }

    private func openPR(_ entry: NotificationHistoryEntry) {
        let urlString = "https://github.com/\(entry.repository.fullName)/pull/\(entry.prNumber)"
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }
}

// MARK: - HistoryRowView

/// A single row in the history list representing one notification event.
private struct HistoryRowView: View {

    let entry: NotificationHistoryEntry
    let debugMode: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Primary line: PR title + disposition badge
            HStack(alignment: .firstTextBaseline) {
                Text(entry.prTitle)
                    .font(.body)
                    .fontWeight(.medium)
                    .lineLimit(1)

                Spacer()

                dispositionBadge
            }

            // Secondary line: repository, event type, matched rule
            HStack(spacing: 8) {
                Text(entry.repository.fullName)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text(eventTypeLabel(for: entry.eventType))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let ruleName = entry.matchedRuleName {
                    Text(ruleName)
                        .font(.caption2)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.12))
                        .clipShape(Capsule())
                }
            }

            // Timestamp
            HStack {
                Text(formattedTimestamp(entry.timestamp))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

                Spacer()
            }

            // Debug annotation: reason string (only in debug mode)
            if debugMode, let reason = entry.reason {
                Text(reason)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .italic()
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Disposition Badge

    private var dispositionBadge: some View {
        Text(entry.disposition == .delivered ? "Delivered" : "Suppressed")
            .font(.caption2)
            .fontWeight(.semibold)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(dispositionColor.opacity(0.15))
            .foregroundStyle(dispositionColor)
            .clipShape(Capsule())
    }

    private var dispositionColor: Color {
        switch entry.disposition {
        case .delivered: return .green
        case .suppressed: return .red
        }
    }

    // MARK: - Helpers

    private func eventTypeLabel(for eventType: PREventType) -> String {
        switch eventType {
        case .reviewRequested: return "Review Requested"
        case .reviewSubmitted: return "Review Submitted"
        case .commentAdded: return "Comment Added"
        case .checkCompleted: return "Check Completed"
        case .prStateChanged: return "State Changed"
        case .prMerged: return "PR Merged"
        case .newCommitPushed: return "New Commits Pushed"
        case .enteredMergeQueue: return "Entered Merge Queue"
        case .mergeQueueFailed: return "Merge Queue Failed"
        }
    }

    private func formattedTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            formatter.dateFormat = "h:mm a"
        } else if calendar.isDate(date, equalTo: Date(), toGranularity: .year) {
            formatter.dateFormat = "MMM d, h:mm a"
        } else {
            formatter.dateFormat = "MMM d, yyyy, h:mm a"
        }
        return formatter.string(from: date)
    }
}
