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
    var lastSyncResults: [SyncedVideo] = []

    var isRunning: Bool {
        if case .running = status { return true }
        return false
    }

    private let settings     = Settings.shared
    private let photo        = PhotoLibraryService.shared
    private let azure        = AzureService.shared

    private var syncTask: Task<Void, Never>?

    // MARK: - Public entry points

    func startSync() {
        guard !isRunning else { return }
        syncTask = Task { await sync() }
    }

    func cancelSync() {
        syncTask?.cancel()
        syncTask = nil
        status = .idle
        uploadStates = [:]
    }

    func sync() async {
        guard !isRunning else { return }
        uploadStates = [:]
        lastSyncResults = []

        await downloadPhase()

        guard !Task.isCancelled else { status = .idle; return }

        await uploadPhase()

        if case .running = status {
            status = .completed(Date())
        }
    }

    // MARK: - Download phase

    private func downloadPhase() async {
        status = .running("Checking for completed jobs…")

        let jobs: [CompletedJob]
        do { jobs = try await azure.getCompletedJobs() }
        catch { status = .failed("Download check failed: \(error.localizedDescription)"); return }

        guard !jobs.isEmpty else { return }

        status = .running("Downloading \(jobs.count) job(s)…")
        for job in jobs {
            guard !Task.isCancelled else { break }
            await downloadAndSave(job)
        }
    }

    private func downloadAndSave(_ job: CompletedJob) async {
        guard let downloadURL = URL(string: job.downloadUrl) else { return }
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
            }

            // Mark the original's content hash as processed so it is never re-uploaded,
            // even if the deletion dialog is dismissed or runs in background.
            if let photoId = job.photoId, !photoId.isEmpty {
                settings.markProcessed(photoId)
            }

            // Attempt to delete the original — iOS shows a confirmation dialog.
            // This works reliably in the foreground; may silently fail in background.
            if let localId = job.localId, !localId.isEmpty {
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

        status = .running("Scanning library…")

        let allVideos = await Task.detached(priority: .userInitiated) {
            PhotoLibraryService.shared.fetchVideos()
        }.value
        guard !allVideos.isEmpty else { return }

        let activeLocks: Set<String>
        do { activeLocks = Set(try await azure.getActivePhotoIds()) }
        catch { activeLocks = [] }

        status = .running("Evaluating \(allVideos.count) video(s)…")
        var toUpload: [(video: VideoItem, hash: String)] = []

        for video in allVideos {
            guard !Task.isCancelled else { break }

            let assets = PHAsset.fetchAssets(withLocalIdentifiers: [video.id], options: nil)
            guard let asset = assets.firstObject else { continue }

            let resources = PHAssetResource.assetResources(for: asset)
            guard let resource = resources.first(where: { $0.type == .video }) else { continue }

            if let tag = await photo.readEncodeTag(for: asset),
               tag == settings.encodeSettingsTag { continue }

            guard let hash = try? await photo.contentHash(for: resource) else { continue }

            if activeLocks.contains(hash) { continue }
            if settings.processedPhotoIds.contains(hash) { continue }

            toUpload.append((video: video, hash: hash))
        }

        guard !toUpload.isEmpty, !Task.isCancelled else {
            if !Task.isCancelled {
                status = .running("All videos up to date.")
                try? await Task.sleep(for: .seconds(1))
            }
            return
        }

        let batch = Array(toUpload.prefix(settings.maxUploadsPerSync))
        status = .running("Uploading \(batch.count) of \(toUpload.count) video(s)…")

        let maxConcurrent = settings.maxConcurrentUploads
        await withTaskGroup(of: Void.self) { group in
            var inFlight = 0
            for item in batch {
                guard !Task.isCancelled else { break }
                if inFlight >= maxConcurrent {
                    await group.next()
                    inFlight -= 1
                }
                let hash     = item.hash
                let filename = item.video.filename
                let localId  = item.video.id
                group.addTask {
                    await SyncEngine.shared.uploadOne(hash: hash, filename: filename, localId: localId)
                }
                inFlight += 1
            }
            await group.waitForAll()
        }
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

            await MainActor.run { SyncEngine.shared.uploadStates[hash] = .done }
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
