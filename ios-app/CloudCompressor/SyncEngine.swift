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

    var isRunning: Bool {
        if case .running = status { return true }
        return false
    }

    private let settings     = Settings.shared
    private let photo        = PhotoLibraryService.shared
    private let azure        = AzureService.shared

    // MARK: - Entry point

    func sync() async {
        guard !isRunning else { return }
        uploadStates = [:]

        await downloadPhase()
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
            await downloadAndSave(job)
        }
    }

    private func downloadAndSave(_ job: CompletedJob) async {
        guard let downloadURL = URL(string: job.downloadUrl) else { return }
        do {
            let (tempURL, _) = try await URLSession.shared.download(from: downloadURL)

            let ext    = (job.originalName as NSString?)?.pathExtension ?? "mov"
            let named  = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(ext.isEmpty ? "mov" : ext)
            try FileManager.default.moveItem(at: tempURL, to: named)
            defer { try? FileManager.default.removeItem(at: named) }

            // PHPhotoLibrary reads the embedded creation_time so the video lands at the
            // original recording date in the timeline, not today.
            try await photo.saveVideoToLibrary(from: named)
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

        // 1. Fast scan — no IO per asset
        let allVideos = photo.fetchVideos()
        guard !allVideos.isEmpty else { return }

        // 2. Fetch distributed locks from Azure
        let activeLocks: Set<String>
        do { activeLocks = Set(try await azure.getActivePhotoIds()) }
        catch { activeLocks = [] }  // no lock set → risk a duplicate at worst, not a crash

        // 3. Evaluate each video: compute hash + check encode tag + check lock
        status = .running("Evaluating \(allVideos.count) video(s)…")
        var toUpload: [(video: VideoItem, hash: String)] = []

        for video in allVideos {
            let assets = PHAsset.fetchAssets(withLocalIdentifiers: [video.id], options: nil)
            guard let asset = assets.firstObject else { continue }

            let resources = PHAssetResource.assetResources(for: asset)
            guard let resource = resources.first(where: { $0.type == .video }) else { continue }

            // Permanent marker: video already compressed with current settings
            if let tag = await photo.readEncodeTag(for: asset),
               tag == settings.encodeSettingsTag { continue }

            // Compute content hash (reads first 4 MB — the stable cross-device identity)
            guard let hash = try? await photo.contentHash(for: resource) else { continue }

            // Distributed lock: job already in flight or ready for download
            if activeLocks.contains(hash) { continue }

            toUpload.append((video: video, hash: hash))
        }

        guard !toUpload.isEmpty else {
            status = .running("All videos up to date.")
            try? await Task.sleep(for: .seconds(1))
            return
        }

        status = .running("Uploading \(toUpload.count) video(s)…")

        // 4. Bounded concurrent uploads (sliding window — like a semaphore)
        let maxConcurrent = settings.maxConcurrentUploads
        await withTaskGroup(of: Void.self) { group in
            var inFlight = 0
            for item in toUpload {
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
            let resp = try await AzureService.shared.getUploadUrl(filename: filename, photoId: hash)
            guard let sasURL = URL(string: resp.uploadUrl) else { throw URLError(.badURL) }

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
            : Date(timeIntervalSinceNow: 15 * 60)  // no quiet window → try again in 15 min
        try? BGTaskScheduler.shared.submit(request)
    }
}
