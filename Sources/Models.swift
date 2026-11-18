import Foundation

enum MediaKind {
    case photo, video
}

/// A photo or video found on the card, plus the file name it will get in the destination folder.
struct CardFile: Identifiable, Hashable {
    var id: String { relativePath }
    let url: URL
    let relativePath: String
    let name: String
    let size: Int64
    let modified: Date
    let kind: MediaKind
    var destName: String
}

/// A file that actually exists in the destination folder (read back from disk, not assumed).
struct DestFile: Hashable {
    let url: URL
    let name: String
    let size: Int64
    let modified: Date
}

enum VerifyStatus: Equatable {
    case pending
    case copying
    case verified(hash: String)
    /// Add-to-existing-folder mode: the folder already has this file (same name and size), so it wasn't copied.
    case alreadyThere
    /// A same-name-and-size file that wasn't compared because the check was stopped. Neutral, not a failure.
    case notChecked
    case failed(String)

    var isVerified: Bool {
        if case .verified = self { return true }
        return false
    }

    /// Safely in the destination: copied and verified now, or already there before the import.
    var isSafe: Bool { isVerified || self == .alreadyThere }
}

final class CancelToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
    }
}

enum Format {
    static let bytes: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f
    }()

    static func size(_ n: Int64) -> String { bytes.string(fromByteCount: n) }

    static let date: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .medium
        return f
    }()

    static func count(_ n: Int) -> String {
        NumberFormatter.localizedString(from: NSNumber(value: n), number: .decimal)
    }
}
