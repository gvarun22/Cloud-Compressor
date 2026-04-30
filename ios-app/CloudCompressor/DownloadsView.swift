import SwiftUI

// Downloads are handled automatically by SyncEngine on every sync pass.
// This view shows completed jobs that are ready but not yet downloaded,
// and lets the user manually trigger a download check.

struct DownloadsView: View {
    @ObservedObject private var engine = SyncEngine.shared
    @StateObject private var vm = DownloadsViewModel()

    var body: some View {
        NavigationStack {
            Group {
                if vm.isLoading {
                    ProgressView("Checking for completed jobs…")
                } else if vm.jobs.isEmpty {
                    ContentUnavailableView(
                        "No Completed Jobs",
                        systemImage: "arrow.down.circle",
                        description: Text("Sync runs automatically on open. Pull to refresh.")
                    )
                } else {
                    List(vm.jobs) { job in
                        JobRow(job: job, state: vm.downloadStates[job.jobId]) {
                            Task { await vm.download(job) }
                        }
                    }
                    .refreshable { await vm.refresh() }
                }
            }
            .navigationTitle("Downloads")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Refresh") { Task { await vm.refresh() } }
                        .disabled(vm.isLoading)
                }
            }
        }
        .task { await vm.refresh() }
    }
}

struct JobRow: View {
    let job: CompletedJob
    let state: DownloadState?
    let onDownload: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(job.originalName ?? job.jobId).font(.body).lineLimit(1)

            HStack(spacing: 6) {
                Text("\(formatBytes(job.originalSizeBytes)) → \(formatBytes(job.compressedSizeBytes))")
                if job.savingsPercent > 0 {
                    Text("·")
                    Text("\(job.savingsPercent)% smaller").foregroundStyle(.green)
                } else if job.savingsPercent < 0 {
                    Text("·")
                    Text("\(abs(job.savingsPercent))% larger").foregroundStyle(.orange)
                }
            }
            .font(.caption).foregroundStyle(.secondary)

            Group {
                switch state {
                case .none:
                    Button("Download & Save to Photos", action: onDownload)
                        .buttonStyle(.borderedProminent).controlSize(.small)
                case .downloading:
                    HStack(spacing: 6) { ProgressView().controlSize(.mini); Text("Downloading…") }
                case .saving:
                    HStack(spacing: 6) { ProgressView().controlSize(.mini); Text("Saving to Photos…") }
                case .done:
                    Label("Saved to Photos", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                case .failed(let msg):
                    Label(msg, systemImage: "xmark.circle.fill").foregroundStyle(.red).lineLimit(2)
                }
            }
            .font(.caption)
        }
        .padding(.vertical, 4)
    }
}

@MainActor
class DownloadsViewModel: ObservableObject {
    @Published var jobs: [CompletedJob] = []
    @Published var downloadStates: [String: DownloadState] = [:]
    @Published var isLoading = false

    func refresh() async {
        isLoading = true
        defer { isLoading = false }
        do { jobs = try await AzureService.shared.getCompletedJobs() }
        catch { print("GetCompletedJobs error: \(error)") }
    }

    func download(_ job: CompletedJob) async {
        guard let downloadURL = URL(string: job.downloadUrl) else { return }
        downloadStates[job.jobId] = .downloading
        do {
            let (tempURL, _) = try await URLSession.shared.download(from: downloadURL)
            let ext   = (job.originalName as NSString?)?.pathExtension ?? "mov"
            let named = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(ext.isEmpty ? "mov" : ext)
            try FileManager.default.moveItem(at: tempURL, to: named)
            defer { try? FileManager.default.removeItem(at: named) }

            downloadStates[job.jobId] = .saving
            try await PhotoLibraryService.shared.saveVideoToLibrary(from: named)
            try await AzureService.shared.acknowledgeJob(jobId: job.jobId)

            downloadStates[job.jobId] = .done
            jobs.removeAll { $0.jobId == job.jobId }
        } catch {
            downloadStates[job.jobId] = .failed(error.localizedDescription)
        }
    }
}
