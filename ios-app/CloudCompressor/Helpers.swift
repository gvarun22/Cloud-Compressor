import Foundation

func formatBytes(_ bytes: Int64) -> String {
    guard bytes > 0 else { return "iCloud" }
    let formatter = ByteCountFormatter()
    formatter.countStyle = .file
    return formatter.string(fromByteCount: bytes)
}

func formatDuration(_ duration: TimeInterval) -> String {
    let total = Int(duration)
    let m = total / 60
    let s = total % 60
    return String(format: "%d:%02d", m, s)
}
