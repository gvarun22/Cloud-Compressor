import SwiftUI

struct ContentView: View {
    var body: some View {
        TabView {
            LibraryView()
                .tabItem { Label("Library", systemImage: "photo.on.rectangle.angled") }

            DownloadsView()
                .tabItem { Label("Last Sync", systemImage: "arrow.down.circle") }

            SettingsView()
                .tabItem { Label("Settings", systemImage: "gear") }
        }
    }
}
