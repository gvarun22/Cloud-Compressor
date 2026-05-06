import BackgroundTasks
import Photos

// MARK: - State types

enum SyncStatus: Equatable {
    case idle
    case running(String)
    case completed(Date)
    case failed(String)
}

// MARK: - SyncEngine

@Observable
@MainActor
final class SyncEngine {
    static let shared = SyncEngine()
    private init() {}

    var status: SyncStatus = .idle
    var uploadStates: [String: UploadState] = [:]  // contentHash → state
    var lastSyncResults: [SyncedVideo] = {
        guard let data = UserDefaults.standard.data(forKey: "lastSyncResults"),
              let saved = try? JSONDecoder().decode([SyncedVideo].self, from: data) else { return [] }
        return saved
    }()

    var isRunning: Bool {
        if case .running = status { return true }
        return false
    }

    private var lastAutoDownload: Date = .distantPast

    // Calls downloadOnly() only if not already running and > 5 min since last auto-download.
    func downloadIfDue() async {
        guard !isRunning, Date().timeIntervalSince(lastAutoDownload) > 300 else { return }
        lastAutoDownload = Date()
        await downloadOnly()
    }

    private let settings     = Settings.shared
    private let photo        = PhotoLibraryService.shared
    private let azure        = AzureService.shared

    private var syncTask: Task<Void, Never>?

    // MARK: - Public entry points

    // Called on app open — downloads completed jobs, shows delete prompts.
    func downloadOnly() async {
        guard !isRunning else { return }
        await downloadPhase()
        if case .running = status { status = .completed(Date()) }
    }

    // Called by Upload Batch button and background task — uploads a batch, no downloads.
    func startUploadBatch() {
        guard !isRunning else { return }
        syncTask = Task { await uploadBatch() }
    }

    func cancelSync() {
        syncTask?.cancel()
        syncTask = nil
        status = .idle
        uploadStates = [:]
    }

    func uploadBatch() async {
        guard !isRunning else { return }
        uploadStates = [:]
        await uploadPhase()
        if case .running = status { status = .completed(Date()) }
    }

    // MARK: - Download phase

    private func downloadPhase() async {
        status = .running("Checking for completed jobs…")

        let jobs: [CompletedJob]
        do { jobs = try await azure.getCompletedJobs() }
        catch { status = .failed("Download check failed: \(error.localizedDescription)"); return }

        // Re-queue any failed jobs so they get picked up by the next upload batch.
        let failedJobs = jobs.filter { $0.status == "failed" }
        for job in failedJobs {
            if let localId = job.localId, !localId.isEmpty {
                settings.removeProcessedLocal(localId)
            }
        }

        let readyJobs = jobs.filter { $0.status != "failed" }
        guard !readyJobs.isEmpty else { return }

        lastSyncResults = []  // clear only when new downloads are actually starting
        status = .running("Downloading \(readyJobs.count) job(s)…")
        for job in readyJobs {
            guard !Task.isCancelled else { break }
            await downloadAndSave(job)
        }
    }

    private func downloadAndSave(_ job: CompletedJob) async {
        guard let urlString = job.downloadUrl, let downloadURL = URL(string: urlString) else { return }
        do {
            let (tempURL, _) = try await URLSession.shared.download(from: downloadURL)

            // Use original filename so Photos stores it correctly.
            // Sanitise in case originalName contains path separators.
            let rawName  = job.originalName ?? "\(job.jobId).mov"
            let filename = rawName.replacingOccurrences(of: "/", with: "_")
            let named    = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
            if FileManager.default.fileExists(atPath: named.path) {
                try FileManager.default.removeItem(at: named)
            }
            try FileManager.default.moveItem(at: tempURL, to: named)
            defer { try? FileManager.default.removeItem(at: named) }

            let savedId = try await photo.saveVideoToLibrary(from: named)
            if let savedId {
                lastSyncResults.append(SyncedVideo(
                    filename: filename,
                    originalSizeBytes: job.originalSizeBytes,
                    compressedSizeBytes: job.compressedSizeBytes,
                    localIdentifier: savedId,
                    savedAt: Date()
                ))
                if let data = try? JSONEncoder().encode(lastSyncResults) {
                    UserDefaults.standard.set(data, forKey: "lastSyncResults")
                }
            }

            // Mark processed so the original is never re-uploaded.
            if let photoId = job.photoId, !photoId.isEmpty {
                settings.markProcessed(photoId)
            }
            if let localId = job.localId, !localId.isEmpty {
                settings.markProcessedLocal(localId)
                await photo.deleteAsset(localIdentifier: localId)
            }

            try await azure.acknowledgeJob(jobId: job.jobId)
        } catch {
            print("[SyncEngine] Download failed for job \(job.jobId): \(error)")
        }
    }

    // MARK: - Upload phase

    private func uploadPhase() async {
        let authStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard authStatus == .authorized || authStatus == .limited else { return }

        status = .running("Updating upload queue…")
        await refreshUploadQueue()

        guard !settings.uploadQueue.isEmpty, !Task.isCancelled else {
            if !Task.isCancelled {
                status = .running("All videos up to date.")
                try? await Task.sleep(for: .seconds(1))
            }
            return
        }

        let activeLocks: Set<String>
        do { activeLocks = Set(try await azure.getActivePhotoIds()) }
        catch { activeLocks = [] }

        // Walk queue front-to-back (largest first), filling the batch.
        // Each candidate needs a hash — but only for the few items we actually upload.
        var toUpload: [(localId: String, filename: String, hash: String)] = []
        var idx = 0
        while toUpload.count < settings.maxUploadsPerSync, idx < settings.uploadQueue.count {
            guard !Task.isCancelled else { break }
            let item = settings.uploadQueue[idx]; idx += 1

            guard let (asset, resource) = await photo.fetchAssetAndResource(localIdentifier: item.localId) else {
                settings.markProcessedLocal(item.localId)   // gone from library
                continue
            }
            if let tag = await photo.readEncodeTag(for: asset), tag == settings.encodeSettingsTag {
                settings.markProcessedLocal(item.localId)   // already compressed
                continue
            }
            guard let hash = try? await photo.contentHash(for: resource) else { continue }
            if activeLocks.contains(hash) { continue }      // in-flight from previous session
            if settings.processedPhotoIds.contains(hash) {
                settings.markProcessedLocal(item.localId)
                continue
            }
            toUpload.append((localId: item.localId, filename: item.filename, hash: hash))
        }

        guard !toUpload.isEmpty, !Task.isCancelled else {
            if !Task.isCancelled {
                status = .running("All videos up to date.")
                try? await Task.sleep(for: .seconds(1))
            }
            return
        }

        status = .running("Uploading \(toUpload.count) of \(settings.uploadQueue.count) remaining…")

        let maxConcurrent = settings.maxConcurrentUploads
        await withTaskGroup(of: Void.self) { group in
            var inFlight = 0
            for item in toUpload {
                guard !Task.isCancelled else { break }
                if inFlight >= maxConcurrent { await group.next(); inFlight -= 1 }
                let (localId, filename, hash) = (item.localId, item.filename, item.hash)
                group.addTask { await SyncEngine.shared.uploadOne(hash: hash, filename: filename, localId: localId) }
                inFlight += 1
            }
            await group.waitForAll()
        }
    }

    // Merges the current photo library into the persistent queue.
    // fetchVideos() returns assets sorted by size desc with no hash I/O —
    // only new assets (not queued, not processed) are inserted.
    private func refreshUploadQueue() async {
        let allVideos = await photo.fetchVideos()
        let queuedIds = Set(settings.uploadQueue.map { $0.localId })

        let newItems: [UploadQueueItem] = allVideos.compactMap { video in
            guard !queuedIds.contains(video.id),
                  !settings.processedLocalIds.contains(video.id) else { return nil }
            return UploadQueueItem(localId: video.id, sizeBytes: video.fileSize, filename: video.filename)
        }
        guard !newItems.isEmpty else { return }

        // Insert new items and re-sort. Existing order is preserved since both lists are
        // already sorted; the merge keeps the invariant with one sort pass.
        var updated = settings.uploadQueue + newItems
        updated.sort { $0.sizeBytes > $1.sizeBytes }
        settings.setUploadQueue(updated)
    }

    // MARK: - Single upload (nonisolated so tasks run off the main actor concurrently)

    nonisolated func uploadOne(hash: String, filename: String, localId: String) async {
        await MainActor.run { SyncEngine.shared.uploadStates[hash] = .uploading(0) }
        do {
            let resp = try await AzureService.shared.getUploadUrl(filename: filename, photoId: hash, localId: localId)
            guard let sasURL = URL(string: resp.uploadUrl) else {
                throw NSError(domain: "CloudCompressor", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Bad SAS URL: \(resp.uploadUrl.prefix(80))"])
            }

            let tempURL = try await PhotoLibraryService.shared.exportOriginalVideo(localIdentifier: localId)
            defer { try? FileManager.default.removeItem(at: tempURL) }

            try await AzureService.shared.uploadFile(at: tempURL, to: sasURL) { progress in
                Task { @MainActor in
                    SyncEngine.shared.uploadStates[hash] = .uploading(progress)
                }
            }

            await MainActor.run {
                SyncEngine.shared.uploadStates[hash] = .done
                Settings.shared.markProcessedLocal(localId)
            }
        } catch {
            await MainActor.run {
                SyncEngine.shared.uploadStates[hash] = .failed(error.localizedDescription)
            }
        }
    }

    // MARK: - Background task scheduling

    static let bgTaskIdentifier = "cloudcompressor.bgsync"

    func scheduleBackgroundSync() {
        let request = BGProcessingTaskRequest(identifier: Self.bgTaskIdentifier)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower       = false
        request.earliestBeginDate           = settings.quietWindowEnabled
            ? settings.nextQuietWindowStart()
            : Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }
}
