import AppIntents

// Exposes Cloud Compressor actions to the iOS Shortcuts app so the user can:
//   • Schedule them via Personal Automation (e.g. "Time of Day 2:00 AM → Upload Batch")
//   • Trigger them from a Home Screen / Lock Screen widget or Siri
//
// After installing a new build, the shortcuts auto-register on first launch and
// appear in Shortcuts → search "Cloud Compressor".

struct UploadBatchIntent: AppIntent {
    static var title: LocalizedStringResource = "Upload Batch"
    static var description = IntentDescription(
        "Start uploading the next batch of videos for compression. Batch size and concurrency are taken from Settings."
    )

    // Open the app so the upload runs in the host process (photo library access,
    // SyncEngine state, background URLSession). The user can navigate away immediately;
    // uploads continue in the background URLSession after the app suspends.
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        SyncEngine.shared.startUploadBatch()
        return .result(dialog: "Upload batch started.")
    }
}

struct SyncNowIntent: AppIntent {
    static var title: LocalizedStringResource = "Sync Now"
    static var description = IntentDescription(
        "Download completed compressions, then start uploading the next batch."
    )

    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        await SyncEngine.shared.downloadOnly()
        SyncEngine.shared.startUploadBatch()
        return .result(dialog: "Sync started.")
    }
}

struct CloudCompressorShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: UploadBatchIntent(),
            phrases: [
                "Upload batch in \(.applicationName)",
                "Start upload in \(.applicationName)"
            ],
            shortTitle: "Upload Batch",
            systemImageName: "icloud.and.arrow.up"
        )
        AppShortcut(
            intent: SyncNowIntent(),
            phrases: [
                "Sync now in \(.applicationName)",
                "Sync \(.applicationName)"
            ],
            shortTitle: "Sync Now",
            systemImageName: "arrow.triangle.2.circlepath.icloud"
        )
    }
}
