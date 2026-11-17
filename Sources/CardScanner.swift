import Foundation

enum CardScanner {
    static let photoExtensions: Set<String> = ["arw", "jpg", "jpeg", "hif", "heif", "heic", "dng"]
    static let videoExtensions: Set<String> = ["mp4", "mov", "mts", "m2ts", "mxf"]
    /// Sony writes small JPEG previews of each clip here; they are not real photos.
    static let excludedDirectories: Set<String> = ["THMBNL"]

    struct Result {
        var media: [CardFile]
        /// Non-media files on the card that will not be copied (shown to the user so nothing is silently ignored).
        var skipped: [String]
    }

    enum ScanError: LocalizedError {
        case notFound(String)
        case unreadable([String])
        var errorDescription: String? {
            switch self {
            case .notFound(let p): return "Can't read \(p). Is the card plugged in?"
            case .unreadable(let items):
                return "Couldn't read part of the card, so some files might be missed. Try re-inserting it. Unreadable: "
                    + items.prefix(5).joined(separator: ", ") + (items.count > 5 ? " (+\(items.count - 5) more)" : "")
            }
        }
    }

    static func scan(root: URL) throws -> Result {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else {
            throw ScanError.notFound(root.path)
        }

        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        // Any folder or file we fail to read must stop the scan: a silently skipped folder would
        // make the import look complete when it isn't.
        var unreadable: [String] = []
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: keys,
                                             options: [.skipsHiddenFiles],
                                             errorHandler: { url, error in
                                                 unreadable.append("\(url.lastPathComponent) (\(error.localizedDescription))")
                                                 return true
                                             }) else {
            throw ScanError.notFound(root.path)
        }

        let rootPath = root.standardizedFileURL.path
        func relative(_ url: URL) -> String {
            let p = url.standardizedFileURL.path
            if p.hasPrefix(rootPath + "/") { return String(p.dropFirst(rootPath.count + 1)) }
            return url.lastPathComponent
        }

        var media: [CardFile] = []
        var skipped: [String] = []

        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: Set(keys))
            if values.isDirectory == true {
                if excludedDirectories.contains(url.lastPathComponent.uppercased()) {
                    enumerator.skipDescendants()
                    skipped.append(relative(url) + "/ (camera-generated clip thumbnails)")
                }
                continue
            }
            guard values.isRegularFile == true else { continue }

            let ext = url.pathExtension.lowercased()
            let kind: MediaKind?
            if photoExtensions.contains(ext) { kind = .photo }
            else if videoExtensions.contains(ext) { kind = .video }
            else { kind = nil }

            guard let kind else {
                skipped.append(relative(url))
                continue
            }
            media.append(CardFile(url: url,
                                  relativePath: relative(url),
                                  name: url.lastPathComponent,
                                  size: Int64(values.fileSize ?? 0),
                                  modified: values.contentModificationDate ?? .distantPast,
                                  kind: kind,
                                  destName: url.lastPathComponent))
        }

        if !unreadable.isEmpty { throw ScanError.unreadable(unreadable) }

        media.sort {
            if $0.modified != $1.modified { return $0.modified < $1.modified }
            return $0.relativePath < $1.relativePath
        }

        // Everything lands flat in one folder, so make sure two files never share a name
        // (e.g. DSC00001.ARW in both 100MSDCF and 101MSDCF). Files sharing a folder and base name
        // (a RAW+JPEG pair) are renamed together so they stay paired.
        func split(_ name: String) -> (base: String, ext: String) {
            ((name as NSString).deletingPathExtension, (name as NSString).pathExtension)
        }
        func groupKey(_ f: CardFile) -> String {
            ((f.relativePath as NSString).deletingLastPathComponent + "/" + split(f.name).base).lowercased()
        }
        var groups: [String: [Int]] = [:]
        var groupOrder: [String] = []
        for i in media.indices {
            let key = groupKey(media[i])
            if groups[key] == nil { groupOrder.append(key) }
            groups[key, default: []].append(i)
        }
        var used = Set<String>()
        for key in groupOrder {
            let members = groups[key]!
            var n = 1
            while true {
                let names = members.map { i -> String in
                    let (base, ext) = split(media[i].name)
                    return n == 1 ? media[i].name : "\(base)-\(n).\(ext)"
                }
                if names.allSatisfy({ !used.contains($0.lowercased()) }) {
                    for (i, name) in zip(members, names) {
                        media[i].destName = name
                        used.insert(name.lowercased())
                    }
                    break
                }
                n += 1
            }
        }

        return Result(media: media, skipped: skipped.sorted())
    }
}
