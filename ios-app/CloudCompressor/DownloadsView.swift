import AVKit
import Photos
import SwiftUI

struct DownloadsView: View {
    private var engine: SyncEngine { SyncEngine.shared }
    @State private var selectedVideo: SyncedVideo?

    var body: some View {
        NavigationStack {
            Group {
                if engine.lastSyncResults.isEmpty {
                    ContentUnavailableView(
                        "No Recent Downloads",
                        systemImage: "arrow.down.circle",
                        description: Text("Compressed videos appear here after each sync so you can verify them.")
                    )
                } else {
                    List(engine.lastSyncResults) { video in
                        Button { selectedVideo = video } label: {
                            SyncedVideoRow(video: video)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .navigationTitle("Last Sync")
            .sheet(item: $selectedVideo) { video in
                VideoPreviewSheet(video: video)
            }
        }
    }
}

struct SyncedVideoRow: View {
    let video: SyncedVideo

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(video.filename).font(.body).lineLimit(1)
            HStack(spacing: 4) {
                Text("\(formatBytes(video.originalSizeBytes)) → \(formatBytes(video.compressedSizeBytes))")
                if video.savingsPercent > 0 {
                    Text("·")
                    Text("\(video.savingsPercent)% smaller").foregroundStyle(.green)
                } else if video.savingsPercent < 0 {
                    Text("·")
                    Text("\(abs(video.savingsPercent))% larger").foregroundStyle(.orange)
                }
            }
            .font(.caption).foregroundStyle(.secondary)
            Label("Tap to preview", systemImage: "play.circle")
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
    }
}

struct VideoPreviewSheet: View {
    let video: SyncedVideo
    @State private var player: AVPlayer?
    @State private var notFound = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Group {
                    if let player {
                        VideoPlayer(player: player)
                    } else if notFound {
                        ContentUnavailableView(
                            "Video Not Found",
                            systemImage: "exclamationmark.circle",
                            description: Text("The video may have been deleted from Photos.")
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ProgressView("Loading…")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }

                Divider()
                HStack {
                    Text("\(formatBytes(video.originalSizeBytes)) → \(formatBytes(video.compressedSizeBytes))")
                        .foregroundStyle(.secondary)
                    Spacer()
                    if video.savingsPercent > 0 {
                        Text("\(video.savingsPercent)% smaller").foregroundStyle(.green)
                    } else if video.savingsPercent < 0 {
                        Text("\(abs(video.savingsPercent))% larger").foregroundStyle(.orange)
                    }
                }
                .font(.caption)
                .padding(.horizontal)
                .padding(.vertical, 10)
            }
            .navigationTitle(video.filename)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task { await loadPlayer() }
        .onDisappear { player?.pause() }
    }

    private func loadPlayer() async {
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: [video.localIdentifier], options: nil)
        guard let asset = assets.firstObject else { notFound = true; return }

        let avAsset: AVAsset? = await withCheckedContinuation { cont in
            let opts = PHVideoRequestOptions()
            opts.version = .current
            opts.isNetworkAccessAllowed = true
            PHImageManager.default().requestAVAsset(forVideo: asset, options: opts) { avAsset, _, _ in
                cont.resume(returning: avAsset)
            }
        }

        guard let avAsset else { notFound = true; return }
        let playerItem = AVPlayerItem(asset: avAsset)
        player = AVPlayer(playerItem: playerItem)
        player?.play()
    }
}

private func formatBytes(_ bytes: Int64) -> String {
    let formatter = ByteCountFormatter()
    formatter.allowedUnits = [.useGB, .useMB]
    formatter.countStyle = .file
    return formatter.string(fromByteCount: bytes)
}
