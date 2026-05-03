import AVFoundation
import CryptoKit
import Photos

class PhotoLibraryService {
    static let shared = PhotoLibraryService()
    private init() {}

    // MARK: - Authorization

    func requestAuthorization() async -> PHAuthorizationStatus {
        await PHPhotoLibrary.requestAuthorization(for: .readWrite)
    }

    // MARK: - Library scan (fast — no IO per asset)

    func fetchVideos() -> [VideoItem] {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.video.rawValue)
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]

        let assets = PHAsset.fetchAssets(with: options)
        var items: [VideoItem] = []

        assets.enumerateObjects { asset, _, _ in
            let resources = PHAssetResource.assetResources(for: asset)
            guard let resource = resources.first(where: { $0.type == .video }) else { return }
            let fileSize = (resource.value(forKey: "fileSize") as? Int64) ?? 0
            items.append(VideoItem(
                id:           asset.localIdentifier,
                filename:     resource.originalFilename,
                fileSize:     fileSize,
                creationDate: asset.creationDate,
                duration:     asset.duration
            ))
        }

        return items.sorted { $0.fileSize > $1.fileSize }
    }

    // MARK: - Content hash (SHA256 of first 4 MB)
    // Uses PHAssetResourceManager.requestData with early cancellation so we never
    // download more than 4 MB even for iCloud-only assets.

    func contentHash(for resource: PHAssetResource) async throws -> String {
        var hasher = SHA256()
        var bytesRead = 0
        let maxBytes  = 4 * 1024 * 1024
        var requestId: PHAssetResourceDataRequestID = 0

        let opts = PHAssetResourceRequestOptions()
        opts.isNetworkAccessAllowed = true

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            requestId = PHAssetResourceManager.default().requestData(
                for: resource,
                options: opts,
                dataReceivedHandler: { data in
                    guard bytesRead < maxBytes else { return }
                    let toRead = min(data.count, maxBytes - bytesRead)
                    hasher.update(data: data.prefix(toRead))
                    bytesRead += toRead
                    if bytesRead >= maxBytes {
                        PHAssetResourceManager.default().cancelDataRequest(requestId)
                    }
                },
                completionHandler: { error in
                    if let err = error as? NSError,
                       err.domain == "PHPhotosErrorDomain", err.code == 3072 {
                        cont.resume()           // expected: cancelled after reading maxBytes
                    } else if let error {
                        cont.resume(throwing: error)
                    } else {
                        cont.resume()
                    }
                }
            )
        }

        // 16 hex chars (8 bytes of SHA256) — sufficient uniqueness for this use case
        return hasher.finalize().prefix(8)
            .map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Encode tag (reads the comment metadata written by FFmpeg)
    // Searches all metadata formats so it works for both MOV and MP4.
    // Returns nil if the video has never been processed by this pipeline.

    func readEncodeTag(for asset: PHAsset) async -> String? {
        let avAsset: AVAsset? = await withCheckedContinuation { cont in
            let opts = PHVideoRequestOptions()
            opts.version = .current
            opts.isNetworkAccessAllowed = false
            PHImageManager.default().requestAVAsset(forVideo: asset, options: opts) { avAsset, _, _ in
                cont.resume(returning: avAsset)
            }
        }
        guard let avAsset else { return nil }

        do {
            var allItems: [AVMetadataItem] = []
            allItems += try await avAsset.load(.commonMetadata)
            allItems += try await avAsset.loadMetadata(for: .quickTimeUserData)
            allItems += try await avAsset.loadMetadata(for: .quickTimeMetadata)
            allItems += try await avAsset.loadMetadata(for: .iTunesMetadata)

            for item in allItems {
                if let value = try? await item.load(.stringValue),
                   value.hasPrefix("cloudcompressor:") {
                    return value
                }
            }
        } catch {}

        return nil
    }

    // MARK: - Export original (no transcoding)

    func exportOriginalVideo(localIdentifier: String) async throws -> URL {
        let result = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil)
        guard let asset = result.firstObject else { throw ExportError.assetNotFound }

        let resources = PHAssetResource.assetResources(for: asset)
        guard let resource = resources.first(where: { $0.type == .video }) else {
            throw ExportError.noVideoResource
        }

        let ext = (resource.originalFilename as NSString).pathExtension.lowercased()
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(ext.isEmpty ? "mov" : ext)

        let opts = PHAssetResourceRequestOptions()
        opts.isNetworkAccessAllowed = true

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            PHAssetResourceManager.default().writeData(for: resource, toFile: tempURL, options: opts) { error in
                if let error { cont.resume(throwing: error) }
                else         { cont.resume() }
            }
        }

        return tempURL
    }

    // MARK: - Delete original

    func deleteAsset(localIdentifier: String) async {
        let result = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil)
        guard result.count > 0 else { return }
        try? await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.deleteAssets(result)
        }
    }

    // MARK: - Save to library

    func saveVideoToLibrary(from url: URL) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
        }
    }

    enum ExportError: LocalizedError {
        case assetNotFound, noVideoResource
        var errorDescription: String? {
            switch self {
            case .assetNotFound:   return "Could not find video in photo library."
            case .noVideoResource: return "No video resource found for this asset."
            }
        }
    }
}
