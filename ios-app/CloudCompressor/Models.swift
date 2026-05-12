import Foundation

struct CompletedJob: Codable, Identifiable {
    let status: String?          // "ready" or "failed"
    let jobId: String
    let downloadUrl: String?
    let photoId: String?
    let localId: String?
    let originalName: String?
    let originalSizeBytes: Int64
    let compressedSizeBytes: Int64
    let completedAt: String?
    let crf: Int?

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

struct SyncedVideo: Identifiable, Codable {
    let id: UUID
    let filename: String
    let originalSizeBytes: Int64
    let compressedSizeBytes: Int64
    let localIdentifier: String  // PHAsset.localIdentifier of the saved compressed video
    let savedAt: Date

    init(filename: String, originalSizeBytes: Int64, compressedSizeBytes: Int64,
         localIdentifier: String, savedAt: Date) {
        self.id               = UUID()
        self.filename         = filename
        self.originalSizeBytes  = originalSizeBytes
        self.compressedSizeBytes = compressedSizeBytes
        self.localIdentifier  = localIdentifier
        self.savedAt          = savedAt
    }

    var savingsPercent: Int {
        guard originalSizeBytes > 0 else { return 0 }
        return Int((1.0 - Double(compressedSizeBytes) / Double(originalSizeBytes)) * 100)
    }
}

enum UploadState {
    case uploading(Double)
    case done(Date)
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
    var previousCrf: Int?   // nil = never encoded; non-nil = previously encoded at this CRF
}

struct ProcessedHashEntry: Codable {
    let thumbprint: String
    let crf: Int            // 0 = original video (uploaded and deleted); >0 = compressed copy at this CRF
    let processedAt: String // ISO8601 UTC e.g. "2026-05-11T09:00:00Z"
    let filename: String?
}
