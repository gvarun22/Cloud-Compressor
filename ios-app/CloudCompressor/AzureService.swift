import Foundation

class AzureService {
    static let shared = AzureService()
    private init() {}
    private let settings = Settings.shared

    private var authHeaders: [String: String] {
        ["x-functions-key": settings.functionKey]
    }

    func getUploadUrl(filename: String, photoId: String) async throws -> UploadUrlResponse {
        var comps = URLComponents(string: "\(settings.baseURL)/Get-UploadUrl")!
        comps.queryItems = [
            URLQueryItem(name: "filename", value: filename),
            URLQueryItem(name: "photoId",  value: photoId)
        ]
        var req = URLRequest(url: comps.url!)
        authHeaders.forEach { req.setValue($1, forHTTPHeaderField: $0) }
        let (data, response) = try await URLSession.shared.data(for: req)
        try assertOK(response)
        return try JSONDecoder().decode(UploadUrlResponse.self, from: data)
    }

    func getCompletedJobs() async throws -> [CompletedJob] {
        var req = URLRequest(url: URL(string: "\(settings.baseURL)/Get-CompletedJobs")!)
        authHeaders.forEach { req.setValue($1, forHTTPHeaderField: $0) }
        let (data, response) = try await URLSession.shared.data(for: req)
        try assertOK(response)
        return try JSONDecoder().decode([CompletedJob].self, from: data)
    }

    /// Returns content hashes (photoIds) for all jobs that are pending/submitted/processing/ready.
    /// These are the distributed locks — any hash in this set should not be re-uploaded.
    func getActivePhotoIds() async throws -> [String] {
        var req = URLRequest(url: URL(string: "\(settings.baseURL)/Get-ActivePhotoIds")!)
        authHeaders.forEach { req.setValue($1, forHTTPHeaderField: $0) }
        let (data, response) = try await URLSession.shared.data(for: req)
        try assertOK(response)
        return try JSONDecoder().decode([String].self, from: data)
    }

    func acknowledgeJob(jobId: String) async throws {
        var comps = URLComponents(string: "\(settings.baseURL)/Acknowledge-Job")!
        comps.queryItems = [URLQueryItem(name: "jobId", value: jobId)]
        var req = URLRequest(url: comps.url!)
        authHeaders.forEach { req.setValue($1, forHTTPHeaderField: $0) }
        let (_, response) = try await URLSession.shared.data(for: req)
        try assertOK(response)
    }

    func uploadFile(at fileURL: URL, to sasURL: URL, progress: @escaping (Double) -> Void) async throws {
        var req = URLRequest(url: sasURL)
        req.httpMethod = "PUT"
        req.setValue("BlockBlob",                forHTTPHeaderField: "x-ms-blob-type")
        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")

        let delegate = UploadProgressDelegate(onProgress: progress)
        let (_, response) = try await URLSession.shared.upload(for: req, fromFile: fileURL, delegate: delegate)
        try assertOK(response)
    }

    private func assertOK(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw AzureError.httpError(code)
        }
    }

    enum AzureError: LocalizedError {
        case httpError(Int)
        var errorDescription: String? {
            switch self {
            case .httpError(401): return "Unauthorized — check your function key in Settings."
            case .httpError(let c): return "Server returned \(c)."
            }
        }
    }
}

private class UploadProgressDelegate: NSObject, URLSessionTaskDelegate {
    let onProgress: (Double) -> Void
    init(onProgress: @escaping (Double) -> Void) { self.onProgress = onProgress }

    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        let p = totalBytesExpectedToSend > 0
            ? Double(totalBytesSent) / Double(totalBytesExpectedToSend) : 0
        DispatchQueue.main.async { self.onProgress(p) }
    }
}
