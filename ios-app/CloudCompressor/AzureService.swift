import Foundation

class AzureService {
    static let shared = AzureService()
    private init() {}
    private let settings = Settings.shared

    private var authHeaders: [String: String] {
        ["x-functions-key": settings.functionKey]
    }

    private let backgroundSession: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: "cloudcompressor.upload")
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        config.timeoutIntervalForRequest  = 3600   // 1 h — allows iOS to schedule the transfer after app suspension
        config.timeoutIntervalForResource = 86400  // 24 h — covers large files on slow connections
        return URLSession(configuration: config, delegate: UploadSessionDelegate.shared, delegateQueue: nil)
    }()

    func getUploadUrl(filename: String, photoId: String, localId: String) async throws -> UploadUrlResponse {
        var comps = URLComponents(string: "\(Settings.shared.baseURL)/Get-UploadUrl")!
        comps.queryItems = [
            URLQueryItem(name: "filename", value: filename),
            URLQueryItem(name: "photoId",  value: photoId),
            URLQueryItem(name: "localId",  value: localId),
            URLQueryItem(name: "deviceId", value: Settings.shared.deviceId),
            URLQueryItem(name: "crf",      value: String(Settings.shared.crf))
        ]
        var req = URLRequest(url: comps.url!)
        authHeaders.forEach { req.setValue($1, forHTTPHeaderField: $0) }
        let (data, response) = try await URLSession.shared.data(for: req)
        try assertOK(response)
        return try JSONDecoder().decode(UploadUrlResponse.self, from: data)
    }

    func getCompletedJobs() async throws -> [CompletedJob] {
        var comps = URLComponents(string: "\(Settings.shared.baseURL)/Get-CompletedJobs")!
        comps.queryItems = [URLQueryItem(name: "deviceId", value: Settings.shared.deviceId)]
        var req = URLRequest(url: comps.url!)
        authHeaders.forEach { req.setValue($1, forHTTPHeaderField: $0) }
        let (data, response) = try await URLSession.shared.data(for: req)
        try assertOK(response)
        return try JSONDecoder().decode([CompletedJob].self, from: data)
    }

    func getActivePhotoIds() async throws -> [String] {
        var req = URLRequest(url: URL(string: "\(Settings.shared.baseURL)/Get-ActivePhotoIds")!)
        authHeaders.forEach { req.setValue($1, forHTTPHeaderField: $0) }
        let (data, response) = try await URLSession.shared.data(for: req)
        try assertOK(response)
        return try JSONDecoder().decode([String].self, from: data)
    }

    func acknowledgeJob(jobId: String) async throws {
        var comps = URLComponents(string: "\(Settings.shared.baseURL)/Acknowledge-Job")!
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

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let task = backgroundSession.uploadTask(with: req, fromFile: fileURL)
            UploadSessionDelegate.shared.register(taskId: task.taskIdentifier, continuation: cont, progress: progress)
            task.resume()
        }
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

final class UploadSessionDelegate: NSObject, URLSessionTaskDelegate, URLSessionDelegate, @unchecked Sendable {
    static let shared = UploadSessionDelegate()
    private override init() {}

    var backgroundCompletionHandler: (() -> Void)?

    private let lock = NSLock()
    private var continuations: [Int: CheckedContinuation<Void, Error>] = [:]
    private var progressHandlers: [Int: (Double) -> Void] = [:]

    func register(taskId: Int, continuation: CheckedContinuation<Void, Error>, progress: @escaping (Double) -> Void) {
        lock.withLock {
            continuations[taskId] = continuation
            progressHandlers[taskId] = progress
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64,
                    totalBytesExpectedToSend: Int64) {
        let p = totalBytesExpectedToSend > 0
            ? Double(totalBytesSent) / Double(totalBytesExpectedToSend) : 0
        let handler = lock.withLock { progressHandlers[task.taskIdentifier] }
        DispatchQueue.main.async { handler?(p) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let cont = lock.withLock {
            let c = continuations.removeValue(forKey: task.taskIdentifier)
            progressHandlers.removeValue(forKey: task.taskIdentifier)
            return c
        }
        if let error {
            cont?.resume(throwing: error)
        } else if let http = task.response as? HTTPURLResponse,
                  !(200...299).contains(http.statusCode) {
            cont?.resume(throwing: AzureService.AzureError.httpError(http.statusCode))
        } else {
            cont?.resume()
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async {
            self.backgroundCompletionHandler?()
            self.backgroundCompletionHandler = nil
        }
    }
}
