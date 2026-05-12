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

    // MARK: - Processed hashes (synced with remote — survives reinstall and works across devices)
    //
    // processedHashes: content hash → CRF used
    //   crf == 0  → original video was uploaded (original now deleted; guard against re-upload if deletion failed)
    //   crf  > 0  → compressed copy at this CRF (skip if same CRF; re-encode if different)
    //
    // processedLocalIds: PHAsset.localIdentifier → fast device-local dedup (not synced, device-specific)
    // compressedCrfs:    localId of compressed copy → CRF (device-local; drives re-encode trigger on CRF change)
    // uploadQueue:       two-tier sorted queue (unencoded first, re-encode candidates second)

    private(set) var processedHashes: [String: Int] = [:]
    private(set) var processedLocalIds: Set<String> = []
    private(set) var compressedCrfs: [String: Int] = [:]
    private(set) var uploadQueue: [UploadQueueItem] = []

    // Accumulated entries waiting to be pushed to the remote hash store.
    private(set) var pendingHashPushes: [ProcessedHashEntry] = []

    func markProcessed(_ hash: String, crf: Int = 0, filename: String? = nil) {
        processedHashes[hash] = crf
        persistProcessedHashes()
        pendingHashPushes.append(ProcessedHashEntry(
            thumbprint:  hash,
            crf:         crf,
            processedAt: Self.iso8601.string(from: Date()),
            filename:    filename
        ))
    }

    func mergeRemoteHashes(_ entries: [ProcessedHashEntry]) {
        for entry in entries {
            processedHashes[entry.thumbprint] = entry.crf
        }
        persistProcessedHashes()
    }

    func takePendingHashPushes() -> [ProcessedHashEntry] {
        let pending = pendingHashPushes
        pendingHashPushes = []
        return pending
    }

    func markProcessedLocal(_ localId: String) {
        processedLocalIds.insert(localId)
        uploadQueue.removeAll { $0.localId == localId }
        UserDefaults.standard.set(Array(processedLocalIds), forKey: "processedLocalIds")
        persistQueue()
    }

    func markCompressed(_ localId: String, crf: Int) {
        compressedCrfs[localId] = crf
        persistCompressedCrfs()
        markProcessedLocal(localId)
    }

    func setUploadQueue(_ items: [UploadQueueItem]) {
        uploadQueue = items
        persistQueue()
    }

    func removeProcessedLocal(_ localId: String) {
        processedLocalIds.remove(localId)
        UserDefaults.standard.set(Array(processedLocalIds), forKey: "processedLocalIds")
    }

    func clearProcessed() {
        processedHashes    = [:]
        processedLocalIds  = []
        compressedCrfs     = [:]
        uploadQueue        = []
        pendingHashPushes  = []
        UserDefaults.standard.removeObject(forKey: "processedHashes")
        UserDefaults.standard.removeObject(forKey: "processedPhotoIds")
        UserDefaults.standard.removeObject(forKey: "processedLocalIds")
        UserDefaults.standard.removeObject(forKey: "compressedCrfs")
        UserDefaults.standard.removeObject(forKey: "uploadQueue")
        Self.saveLastSyncedAt(nil)
    }

    private func persistProcessedHashes() {
        if let data = try? JSONEncoder().encode(processedHashes) {
            UserDefaults.standard.set(data, forKey: "processedHashes")
        }
    }

    private func persistCompressedCrfs() {
        if let data = try? JSONEncoder().encode(compressedCrfs) {
            UserDefaults.standard.set(data, forKey: "compressedCrfs")
        }
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

    var crf: Int {
        didSet {
            set("crf", crf)
            // Remove compressed copies encoded at a different CRF so they re-enter the queue.
            let toRequeue = compressedCrfs.filter { $0.value != crf }.map { $0.key }
            guard !toRequeue.isEmpty else { return }
            toRequeue.forEach { processedLocalIds.remove($0) }
            UserDefaults.standard.set(Array(processedLocalIds), forKey: "processedLocalIds")
        }
    }

    // Parses "cloudcompressor:v1:crf22:2026-05-07T..." or older "cloudcompressor:crf22:h265:..."
    // Returns the CRF value embedded in the tag, or nil if not a pipeline tag.
    static func parseCrf(from tag: String) -> Int? {
        guard tag.hasPrefix("cloudcompressor:") else { return nil }
        for part in tag.split(separator: ":") {
            if part.hasPrefix("crf"), let n = Int(part.dropFirst(3)) { return n }
        }
        return nil
    }

    // MARK: - Init

    private init() {
        let ud = UserDefaults.standard
        baseURL              = ud.string(forKey: "baseURL")          ?? "https://YOUR-FUNC.azurewebsites.net/api"
        functionKey          = ud.string(forKey: "functionKey")      ?? ""
        autoSyncOnOpen       = ud.object(forKey: "autoSyncOnOpen")   == nil ? true : ud.bool(forKey: "autoSyncOnOpen")
        maxConcurrentUploads = ud.object(forKey: "maxConcurrentUploads") == nil ? 2 : ud.integer(forKey: "maxConcurrentUploads")
        maxUploadsPerSync    = ud.object(forKey: "maxUploadsPerSync")    == nil ? 5 : ud.integer(forKey: "maxUploadsPerSync")
        processedLocalIds    = Set(ud.stringArray(forKey: "processedLocalIds") ?? [])
        if let data = ud.data(forKey: "uploadQueue"),
           let queue = try? JSONDecoder().decode([UploadQueueItem].self, from: data) {
            uploadQueue = queue
        }
        crf = ud.object(forKey: "crf") == nil ? 22 : ud.integer(forKey: "crf")
        if let data = ud.data(forKey: "compressedCrfs"),
           let crfs = try? JSONDecoder().decode([String: Int].self, from: data) {
            compressedCrfs = crfs
        }
        deviceId           = Settings.loadOrCreateDeviceId()
        quietWindowEnabled = ud.bool(forKey: "quietWindowEnabled")
        quietWindowStartHour   = ud.object(forKey: "quietWindowStartHour")   == nil ? 2  : ud.integer(forKey: "quietWindowStartHour")
        quietWindowStartMinute = ud.integer(forKey: "quietWindowStartMinute")
        quietWindowEndHour     = ud.object(forKey: "quietWindowEndHour")     == nil ? 6  : ud.integer(forKey: "quietWindowEndHour")
        quietWindowEndMinute   = ud.integer(forKey: "quietWindowEndMinute")

        // Load processedHashes (new store). Migrate old processedPhotoIds entries on first run.
        if let data = ud.data(forKey: "processedHashes"),
           let hashes = try? JSONDecoder().decode([String: Int].self, from: data) {
            processedHashes = hashes
        } else {
            // One-time migration from legacy Set<String> — import as crf=0 (original hashes)
            let legacy = Set(ud.stringArray(forKey: "processedPhotoIds") ?? [])
            if !legacy.isEmpty {
                processedHashes = Dictionary(uniqueKeysWithValues: legacy.map { ($0, 0) })
                if let data = try? JSONEncoder().encode(processedHashes) {
                    ud.set(data, forKey: "processedHashes")
                }
            }
        }
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

    // MARK: - Keychain helpers

    private static let deviceIdAccount   = "cloudcompressor.deviceId"   as CFString
    private static let lastSyncedAccount = "cloudcompressor.lastSynced" as CFString

    static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func loadLastSyncedAt() -> Date? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword, kSecAttrAccount: lastSyncedAccount, kSecReturnData: true
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let str  = String(data: data, encoding: .utf8) else { return nil }
        return iso8601.date(from: str)
    }

    static func saveLastSyncedAt(_ date: Date?) {
        let data: Data? = date.flatMap { Data(iso8601.string(from: $0).utf8) }
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrAccount: lastSyncedAccount]
        if let data {
            let attrs: [CFString: Any] = [kSecValueData: data]
            if SecItemUpdate(query as CFDictionary, attrs as CFDictionary) == errSecItemNotFound {
                var add = query
                add[kSecValueData] = data
                add[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
                SecItemAdd(add as CFDictionary, nil)
            }
        } else {
            SecItemDelete(query as CFDictionary)
        }
    }

    private static func loadOrCreateDeviceId() -> String {
        let account = deviceIdAccount
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword, kSecAttrAccount: account, kSecReturnData: true
        ]
        var result: AnyObject?
        if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
           let data = result as? Data,
           let stored = String(data: data, encoding: .utf8) {
            return stored
        }
        let generated = UserDefaults.standard.string(forKey: "deviceId") ?? UUID().uuidString
        UserDefaults.standard.removeObject(forKey: "deviceId")
        let add: [CFString: Any] = [
            kSecClass:          kSecClassGenericPassword,
            kSecAttrAccount:    account,
            kSecValueData:      Data(generated.utf8),
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        SecItemAdd(add as CFDictionary, nil)
        return generated
    }
}
