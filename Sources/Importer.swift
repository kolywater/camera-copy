import Foundation
import CryptoKit

enum Importer {
    static let chunkSize = 8 * 1024 * 1024
    static let manifestName = "checksums.sha256"

    struct CopyResult {
        /// Hash of the bytes read from the card while copying.
        let sourceHash: String
        /// Hash of a second, separate read of the card after copying.
        let sourceRereadHash: String
        /// Hash of the copy, read back from disk.
        let destHash: String

        var allMatch: Bool { sourceHash == destHash && sourceRereadHash == destHash }
    }

    enum ImportError: LocalizedError {
        case cannotCreate(String)
        case sizeMismatch(expected: Int64, got: Int64)
        case nameTaken(String)
        var errorDescription: String? {
            switch self {
            case .cannotCreate(let p): return "Couldn't create \(p)"
            case .sizeMismatch(let e, let g): return "Size mismatch: card \(e) bytes, copied \(g) bytes"
            case .nameTaken(let n): return "A different file named \(n) is already in the folder, so it was left alone"
            }
        }
    }

    /// Copies `src` to `dst`, hashing the card bytes as they're read, and flushing the copy all the way
    /// to disk. Then it re-reads the copy from disk and re-reads the card, each bypassing the cache, and
    /// hashes both separately. A bad read from the card shows up as a mismatch, not a "verified" copy.
    /// With `mayReplace` false, an existing file at `dst` is never touched: the copy fails instead.
    static func copyAndVerify(from src: URL, to dst: URL, expectedSize: Int64, modified: Date, mayReplace: Bool = true,
                              cancel: CancelToken, progress: (Int64) -> Void) throws -> CopyResult {
        let fm = FileManager.default
        if !mayReplace, fm.fileExists(atPath: dst.path) { throw ImportError.nameTaken(dst.lastPathComponent) }
        let partial = dst.deletingLastPathComponent().appendingPathComponent("." + dst.lastPathComponent + ".partial")
        try? fm.removeItem(at: partial)

        let sourceHash: String
        do {
            guard fm.createFile(atPath: partial.path, contents: nil) else {
                throw ImportError.cannotCreate(partial.path)
            }
            let input = try FileHandle(forReadingFrom: src)
            defer { try? input.close() }
            _ = fcntl(input.fileDescriptor, F_NOCACHE, 1)

            let output = try FileHandle(forWritingTo: partial)
            defer { try? output.close() }
            _ = fcntl(output.fileDescriptor, F_NOCACHE, 1)

            var hasher = SHA256()
            var written: Int64 = 0
            while true {
                if cancel.isCancelled { throw CancellationError() }
                guard let data = try input.read(upToCount: chunkSize), !data.isEmpty else { break }
                hasher.update(data: data)
                try output.write(contentsOf: data)
                written += Int64(data.count)
                progress(Int64(data.count))
            }
            // F_FULLFSYNC forces the drive to commit its own write cache, not just the OS's.
            if fcntl(output.fileDescriptor, F_FULLFSYNC) != 0 {
                try output.synchronize()
            }
            if written != expectedSize {
                throw ImportError.sizeMismatch(expected: expectedSize, got: written)
            }
            sourceHash = hex(hasher.finalize())
            try output.close()
            if mayReplace, fm.fileExists(atPath: dst.path) {
                // Retrying a failed file: replace the bad copy only now that a full new copy exists.
                _ = try fm.replaceItemAt(dst, withItemAt: partial)
            } else {
                // moveItem refuses to overwrite, so a file that appeared meanwhile is never replaced.
                try fm.moveItem(at: partial, to: dst)
            }
        } catch {
            try? fm.removeItem(at: partial)
            throw error
        }

        try? fm.setAttributes([.modificationDate: modified, .creationDate: modified], ofItemAtPath: dst.path)

        let destHash = try hashFile(dst, cancel: cancel, progress: progress)
        let sourceRereadHash = try hashFile(src, cancel: cancel, progress: progress)
        return CopyResult(sourceHash: sourceHash, sourceRereadHash: sourceRereadHash, destHash: destHash)
    }

    /// Reads one destination file's on-disk attributes.
    static func destFile(at url: URL) -> DestFile? {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let v = try? url.resourceValues(forKeys: keys), v.isRegularFile == true else { return nil }
        return DestFile(url: url, name: url.lastPathComponent, size: Int64(v.fileSize ?? 0),
                        modified: v.contentModificationDate ?? .distantPast)
    }

    static func hashFile(_ url: URL, cancel: CancelToken, progress: (Int64) -> Void) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        _ = fcntl(handle.fileDescriptor, F_NOCACHE, 1)
        var hasher = SHA256()
        while true {
            if cancel.isCancelled { throw CancellationError() }
            guard let data = try handle.read(upToCount: chunkSize), !data.isEmpty else { break }
            hasher.update(data: data)
            progress(Int64(data.count))
        }
        return hex(hasher.finalize())
    }

    /// SHA-256 of just the first `bytes` of a file. Two files whose first megabyte differs can't be the
    /// same, so this rules out most look-alikes cheaply before a full hash.
    static func hashPrefix(_ url: URL, bytes: Int = 1024 * 1024) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        _ = fcntl(handle.fileDescriptor, F_NOCACHE, 1)
        return hex(SHA256.hash(data: try handle.read(upToCount: bytes) ?? Data()))
    }

    /// Lists what is really in the destination folder, keyed by lowercased file name.
    static func listDestination(_ dir: URL) -> [String: DestFile] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys,
                                                                 options: [.skipsHiddenFiles])) ?? []
        var result: [String: DestFile] = [:]
        for url in urls {
            guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
            if url.lastPathComponent == manifestName { continue }
            result[url.lastPathComponent.lowercased()] = DestFile(url: url, name: url.lastPathComponent,
                                                                  size: Int64(v.fileSize ?? 0),
                                                                  modified: v.contentModificationDate ?? .distantPast)
        }
        return result
    }

    /// Writes a `shasum -a 256 -c` compatible manifest so the folder can be re-verified any time later.
    static func writeManifest(_ entries: [(name: String, hash: String)], to dir: URL, named name: String = manifestName) throws {
        let text = entries.map { "\($0.hash)  \($0.name)" }.joined(separator: "\n") + "\n"
        try text.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    /// The manifest name for an import into an existing folder: never one that is already there,
    /// so an earlier import's checksums are kept as they were.
    static func newManifestName(taken: Set<String>, date: Date = Date()) -> String {
        if !taken.contains(manifestName.lowercased()) { return manifestName }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        var name = "checksums-\(f.string(from: date)).sha256"
        var n = 2
        while taken.contains(name.lowercased()) {
            name = "checksums-\(f.string(from: date))-\(n).sha256"; n += 1
        }
        return name
    }

    private static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}
