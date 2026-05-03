import Photos
import SwiftUI

struct LibraryView: View {
    private var engine: SyncEngine { SyncEngine.shared }

    var body: some View {
        NavigationStack {
            Group {
                let authStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
                if authStatus == .notDetermined {
                    accessPrompt
                } else if authStatus == .denied || authStatus == .restricted {
                    ContentUnavailableView(
                        "Access Denied",
                        systemImage: "lock.fill",
                        description: Text("Enable photo access in Settings → Privacy → Photos.")
                    )
                } else {
                    syncStatusView
                }
            }
            .navigationTitle("Library")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if engine.isRunning {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Sync Now") {
                            Task { await engine.sync() }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Sub-views

    private var accessPrompt: some View {
        VStack(spacing: 16) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 48)).foregroundStyle(.secondary)
            Text("Photo library access is required to read your videos.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
            Button("Grant Access") {
                Task {
                    await PHPhotoLibrary.requestAuthorization(for: .readWrite)
                }
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
    }

    private var syncStatusView: some View {
        List {
            Section {
                statusRow
            }

            if !engine.uploadStates.isEmpty {
                Section("Current Uploads") {
                    ForEach(Array(engine.uploadStates), id: \.key) { hash, state in
                        UploadProgressRow(hash: hash, state: state)
                    }
                }
            }
        }
    }

    private var statusRow: some View {
        HStack(spacing: 12) {
            Image(systemName: statusIcon)
                .foregroundStyle(statusColor)
                .font(.title2)
            VStack(alignment: .leading, spacing: 2) {
                Text(statusTitle).font(.headline)
                Text(statusSubtitle).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private var statusIcon: String {
        switch engine.status {
        case .idle:         return "clock.arrow.2.circlepath"
        case .running:      return "arrow.trianglehead.2.clockwise.rotate.90"
        case .completed:    return "checkmark.circle.fill"
        case .failed:       return "xmark.circle.fill"
        }
    }

    private var statusColor: Color {
        switch engine.status {
        case .idle:      return .secondary
        case .running:   return .accentColor
        case .completed: return .green
        case .failed:    return .red
        }
    }

    private var statusTitle: String {
        switch engine.status {
        case .idle:                return "Ready"
        case .running(let msg):    return msg
        case .completed(let date): return "Last sync: \(date.formatted(date: .omitted, time: .shortened))"
        case .failed(let msg):     return "Sync failed"
        }
    }

    private var statusSubtitle: String {
        switch engine.status {
        case .idle:      return "Tap Sync Now or sync runs automatically on open."
        case .running:   return "Uploads run \(Settings.shared.maxConcurrentUploads) at a time."
        case .completed: return "Videos encoded on Azure appear in Downloads tab."
        case .failed(let msg): return msg
        }
    }
}

struct UploadProgressRow: View {
    let hash: String
    let state: UploadState

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(hash).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            switch state {
            case .uploading(let p):
                ProgressView(value: p).tint(.accentColor)
                Text("\(Int(p * 100))%").font(.caption).foregroundStyle(.secondary)
            case .done:
                Label("Uploaded", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    .font(.caption)
            case .failed(let msg):
                Label(msg, systemImage: "xmark.circle.fill").foregroundStyle(.red)
                    .font(.caption).lineLimit(2)
            }
        }
        .padding(.vertical, 2)
    }
}
