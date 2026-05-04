import BackgroundTasks
import SwiftUI

class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        UploadSessionDelegate.shared.backgroundCompletionHandler = completionHandler
    }
}

@main
struct CloudCompressorApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
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
                await SyncEngine.shared.uploadBatch()
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
                    await engine.downloadOnly()
                    engine.scheduleBackgroundSync()
                }
        }
    }
}
