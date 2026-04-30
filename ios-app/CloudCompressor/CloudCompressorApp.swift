import BackgroundTasks
import SwiftUI

@main
struct CloudCompressorApp: App {
    private let engine = SyncEngine.shared

    init() {
        // Must register before the first scene is active.
        // Add "cloudcompressor.bgsync" to BGTaskSchedulerPermittedIdentifiers in Info.plist.
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: SyncEngine.bgTaskIdentifier,
            using: nil
        ) { task in
            guard let processingTask = task as? BGProcessingTask else { return }

            let settings = Settings.shared
            guard settings.isInQuietWindow() else {
                // Outside quiet window — complete immediately and reschedule.
                processingTask.setTaskCompleted(success: true)
                Task { @MainActor in SyncEngine.shared.scheduleBackgroundSync() }
                return
            }

            let syncTask = Task {
                await SyncEngine.shared.sync()
                processingTask.setTaskCompleted(success: true)
                SyncEngine.shared.scheduleBackgroundSync()
            }

            processingTask.expirationHandler = {
                syncTask.cancel()
                processingTask.setTaskCompleted(success: false)
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .task {
                    guard Settings.shared.autoSyncOnOpen else { return }
                    await engine.sync()
                    engine.scheduleBackgroundSync()
                }
        }
    }
}
