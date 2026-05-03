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

            let syncTask = Task { @MainActor in
                guard Settings.shared.isInQuietWindow() else {
                    processingTask.setTaskCompleted(success: true)
                    SyncEngine.shared.scheduleBackgroundSync()
                    return
                }
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
