import SwiftUI

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    private var engine: SyncEngine { SyncEngine.shared }

    var body: some View {
        TabView {
            LibraryView()
                .tabItem { Label("Library", systemImage: "photo.on.rectangle.angled") }

            DownloadsView()
                .tabItem { Label("Last Sync", systemImage: "arrow.down.circle") }

            SettingsView()
                .tabItem { Label("Settings", systemImage: "gear") }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                guard Settings.shared.autoSyncOnOpen else { return }
                Task { @MainActor in await engine.downloadIfDue() }
            case .background:
                engine.scheduleBackgroundSync()
            default:
                break
            }
        }
    }
}
