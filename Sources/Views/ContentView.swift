import SwiftUI

// MARK: - Sidebar Selection

enum SidebarSelection: Hashable {
    case dashboard
    case history
    case settings
}

// MARK: - ContentView

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @State private var selection: SidebarSelection? = .dashboard

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Label("Dashboard", systemImage: "square.grid.2x2")
                    .tag(SidebarSelection.dashboard)
                Label("History", systemImage: "clock")
                    .tag(SidebarSelection.history)
                Label("Settings", systemImage: "gear")
                    .tag(SidebarSelection.settings)
            }
            .navigationTitle("ghBonk")
        } detail: {
            switch selection {
            case .dashboard:
                DashboardView()
            case .history:
                HistoryView(appState: appState)
            case .settings:
                SettingsView()
            case nil:
                Text("Select an item")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(minWidth: 700, minHeight: 500)
    }
}
