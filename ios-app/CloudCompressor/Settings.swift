import Foundation
import Security

@Observable
final class Settings {
    static let shared = Settings()

    // MARK: - Azure

    var baseURL: String {
        didSet { set("baseURL", baseURL) }
    }
    var functionKey: String {
        didSet { set("functionKey", functionKey) }
    }

    // MARK: - Sync behaviour

    var autoSyncOnOpen: Bool {
        didSet { set("autoSyncOnOpen", autoSyncOnOpen) }
    }
    var maxConcurrentUploads: Int {
        didSet { set("maxConcurrentUploads", maxConcurrentUploads) }
    }
    var maxUploadsPerSync: Int {
        didSet { set("maxUploadsPerSync", maxUploadsPerSync) }
    }

    // MARK: - Device identity (stable per install, used to filter Azure jobs by device)

    let deviceId: String

    // MARK: - Processed originals (persisted to prevent re-upload after compression)

    private(set) var processedPhotoIds: Set<String> = []   // content hashes (legacy dedup)
    private(set) var processedLocalIds: Set<String> = []   // PHAsset.localIdentifier (fast dedup)
    private(set) var uploadQueue: [UploadQueueItem] = []   // sorted by sizeBytes desc

    func markProcessed(_ photoId: String) {
        processedPhotoIds.insert(photoId)
        UserDefaults.standard.set(Array(processedPhotoIds), forKey: "processedPhotoIds")
    }

    func markProcessedLocal(_ localId: String) {
        processedLocalIds.insert(localId)
        uploadQueue.removeAll { $0.localId == localId }
        UserDefaults.standard.set(Array(processedLocalIds), forKey: "processedLocalIds")
        persistQueue()
    }

    func setUploadQueue(_ items: [UploadQueueItem]) {
        uploadQueue = items
        persistQueue()
    }

    func clearProcessed() {
        processedPhotoIds = []
        processedLocalIds = []
        uploadQueue = []
        UserDefaults.standard.removeObject(forKey: "processedPhotoIds")
        UserDefaults.standard.removeObject(forKey: "processedLocalIds")
        UserDefaults.standard.removeObject(forKey: "uploadQueue")
    }

    private func persistQueue() {
        if let data = try? JSONEncoder().encode(uploadQueue) {
            UserDefaults.standard.set(data, forKey: "uploadQueue")
        }
    }

    // MARK: - Quiet window (background task only runs within this time range)

    var quietWindowEnabled: Bool {
        didSet { set("quietWindowEnabled", quietWindowEnabled) }
    }
    var quietWindowStartHour: Int {
        didSet { set("quietWindowStartHour", quietWindowStartHour) }
    }
    var quietWindowStartMinute: Int {
        didSet { set("quietWindowStartMinute", quietWindowStartMinute) }
    }
    var quietWindowEndHour: Int {
        didSet { set("quietWindowEndHour", quietWindowEndHour) }
    }
    var quietWindowEndMinute: Int {
        didSet { set("quietWindowEndMinute", quietWindowEndMinute) }
    }

    // MARK: - Encode settings
    // Must match the -metadata comment= value written by StartEncoding.cs.
    // If you change the FFmpeg command in Azure, update this string to match.
    let encodeSettingsTag = "cloudcompressor:crf24:h265:veryfast:hvc1"

    // MARK: - Init

    private init() {
        let ud = UserDefaults.standard
        baseURL              = ud.string(forKey: "baseURL")          ?? "https://YOUR-FUNC.azurewebsites.net/api"
        functionKey          = ud.string(forKey: "functionKey")      ?? ""
        autoSyncOnOpen       = ud.object(forKey: "autoSyncOnOpen")   == nil ? true : ud.bool(forKey: "autoSyncOnOpen")
        maxConcurrentUploads = ud.object(forKey: "maxConcurrentUploads") == nil ? 2 : ud.integer(forKey: "maxConcurrentUploads")
        maxUploadsPerSync    = ud.object(forKey: "maxUploadsPerSync")    == nil ? 5 : ud.integer(forKey: "maxUploadsPerSync")
        processedPhotoIds    = Set(ud.stringArray(forKey: "processedPhotoIds") ?? [])
        processedLocalIds    = Set(ud.stringArray(forKey: "processedLocalIds") ?? [])
        if let data = ud.data(forKey: "uploadQueue"),
           let queue = try? JSONDecoder().decode([UploadQueueItem].self, from: data) {
            uploadQueue = queue
        }
        deviceId             = Settings.loadOrCreateDeviceId()
        quietWindowEnabled   = ud.bool(forKey: "quietWindowEnabled")
        quietWindowStartHour = ud.object(forKey: "quietWindowStartHour")   == nil ? 2 : ud.integer(forKey: "quietWindowStartHour")
        quietWindowStartMinute = ud.integer(forKey: "quietWindowStartMinute")
        quietWindowEndHour   = ud.object(forKey: "quietWindowEndHour")     == nil ? 6 : ud.integer(forKey: "quietWindowEndHour")
        quietWindowEndMinute = ud.integer(forKey: "quietWindowEndMinute")
    }

    // MARK: - Helpers

    func isInQuietWindow() -> Bool {
        guard quietWindowEnabled else { return true }
        let cal = Calendar.current
        let now = cal.dateComponents([.hour, .minute], from: Date())
        let nowMins   = (now.hour   ?? 0) * 60 + (now.minute   ?? 0)
        let startMins = quietWindowStartHour * 60 + quietWindowStartMinute
        let endMins   = quietWindowEndHour   * 60 + quietWindowEndMinute
        if startMins <= endMins {
            return nowMins >= startMins && nowMins < endMins
        } else {
            // Window wraps midnight (e.g. 23:00–05:00)
            return nowMins >= startMins || nowMins < endMins
        }
    }

    func nextQuietWindowStart() -> Date {
        let cal = Calendar.current
        var comps = cal.dateComponents([.year, .month, .day], from: Date())
        comps.hour   = quietWindowStartHour
        comps.minute = quietWindowStartMinute
        comps.second = 0
        var candidate = cal.date(from: comps)!
        if candidate <= Date() { candidate = cal.date(byAdding: .day, value: 1, to: candidate)! }
        return candidate
    }

    private func set(_ key: String, _ value: some Any) {
        UserDefaults.standard.set(value, forKey: key)
    }

    private static func loadOrCreateDeviceId() -> String {
        let account = "cloudcompressor.deviceId" as CFString
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrAccount: account,
            kSecReturnData:  true
        ]
        var result: AnyObject?
        if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
           let data = result as? Data,
           let stored = String(data: data, encoding: .utf8) {
            return stored
        }
        // Migrate from UserDefaults (previous storage) so existing Azure jobs still match
        let generated = UserDefaults.standard.string(forKey: "deviceId") ?? UUID().uuidString
        UserDefaults.standard.removeObject(forKey: "deviceId")
        let add: [CFString: Any] = [
            kSecClass:            kSecClassGenericPassword,
            kSecAttrAccount:      account,
            kSecValueData:        Data(generated.utf8),
            kSecAttrAccessible:   kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        SecItemAdd(add as CFDictionary, nil)
        return generated
    }
}
