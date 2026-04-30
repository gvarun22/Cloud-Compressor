import Foundation

struct CompletedJob: Codable, Identifiable {
    let jobId: String
    let downloadUrl: String
    let photoId: String?
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
