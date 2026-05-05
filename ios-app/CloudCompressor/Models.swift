import Foundation

struct CompletedJob: Codable, Identifiable {
    let jobId: String
    let downloadUrl: String
    let photoId: String?
    let localId: String?
    let originalName: String?
    let originalSizeBytes: Int64
    let compressedSizeBytes: Int64
    let completedAt: String?

    var id: String { jobId }

    var savingsPercent: Int {
        guard originalSizeBytes > 0 else { return 0 }
        return Int((1.0 - Double(compressedSizeBytes) / Double(originalSizeBytes)) * 100)
    }
}

struct UploadUrlResponse: Codable {
    let uploadUrl: String
    let jobId: String
}

struct VideoItem: Identifiable {
    let id: String          // PHAsset.localIdentifier
    let filename: String
    let fileSize: Int64     // 0 if iCloud-only and not downloaded
    let creationDate: Date?
    let duration: TimeInterval
}

struct SyncedVideo: Identifiable {
    let id = UUID()
    let filename: String
    let originalSizeBytes: Int64
    let compressedSizeBytes: Int64
    let localIdentifier: String  // PHAsset.localIdentifier of the saved compressed video
    let savedAt: Date

    var savingsPercent: Int {
        guard originalSizeBytes > 0 else { return 0 }
        return Int((1.0 - Double(compressedSizeBytes) / Double(originalSizeBytes)) * 100)
    }
}

enum UploadState {
    case uploading(Double)
    case done
    case failed(String)
}

enum DownloadState {
    case downloading
    case saving
    case done
    case failed(String)
}

struct UploadQueueItem: Codable, Equatable {
    let localId: String
    let sizeBytes: Int64
    let filename: String
}
