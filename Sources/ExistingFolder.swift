import Foundation

/// Plans an import into a folder that already has files in it ("Add to existing folder").
/// Nothing here touches the disk except reading the folder listing.
enum ExistingFolder {
    struct Listing {
        var root: URL
        /// Every regular, non-hidden file in the folder and all its subfolders, keyed by lowercased
        /// name (several files can share a name in different subfolders). Top-level files come first,
        /// then deeper ones, in path order.
        var files: [String: [DestFile]]
        /// Every name at the top level (files, folders, hidden items), lowercased. New copies go in the
        /// top folder and never use one of these.
        var takenNames: Set<String>

        /// "2025/Trip/DSC1.ARW" for a file in a subfolder, "DSC1.ARW" at the top.
        func relativePath(_ d: DestFile) -> String {
            let rootPath = root.standardizedFileURL.path, p = d.url.standardizedFileURL.path
            return p.hasPrefix(rootPath + "/") ? String(p.dropFirst(rootPath.count + 1)) : d.name
        }
    }

    struct Plan {
        /// Card file id -> the folder file shown as its match before importing (a same-name-and-size
        /// candidate, confirmed or not by checksum during the import).
        var alreadyThere: [String: DestFile]
        /// Card file id -> every same-name-and-size folder file, best first. The import compares them
        /// by checksum in this order; each folder file can stand in for only one card file.
        var candidates: [String: [DestFile]]
        /// Card file id -> the name a new copy gets in the top folder. Never one of `Listing.takenNames`.
        var destNames: [String: String]
    }

    /// Lists the folder and every subfolder, like verify-card.sh searches the destination. Hidden files
    /// and folders (which covers ._ files, .DS_Store, .Spotlight-V100, .Trashes, .fseventsd) are skipped,
    /// and symlinked folders aren't followed, so a link can't make it loop. Unreadable subfolders are
    /// skipped too: a file that can't be found there is simply copied again, the safe direction.
    static func list(_ dir: URL) -> Listing {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        var taken = Set<String>()
        for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] { taken.insert(name.lowercased()) }

        var found: [DestFile] = []
        if let walk = fm.enumerator(at: dir, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles],
                                    errorHandler: { _, _ in true }) {
            for case let url as URL in walk {
                guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
                found.append(DestFile(url: url, name: url.lastPathComponent, size: Int64(v.fileSize ?? 0),
                                      modified: v.contentModificationDate ?? .distantPast))
            }
        }
        let depth = { (d: DestFile) in d.url.pathComponents.count }
        found.sort { depth($0) != depth($1) ? depth($0) < depth($1) : $0.url.path < $1.url.path }
        return Listing(root: dir, files: Dictionary(grouping: found) { $0.name.lowercased() }, takenNames: taken)
    }

    /// A candidate for "already there" is a file in the folder with the same name (ignoring case) and
    /// the same size. It is only a candidate: the import compares checksums before trusting it
    /// (Sony RAWs from one camera are all the same size).
    ///
    /// The card scanner renames clashing names with a "-2", "-3"… suffix (and renames a RAW+JPEG pair
    /// together), so an earlier import of this card may hold "DSC00001-2.ARW". A card file also counts as
    /// already there if the folder has one of those suffixed names with the same size. Each folder file
    /// can stand in for only one card file.
    ///
    /// Files still to copy get a name nobody in the folder uses. A RAW+JPEG pair keeps the suffix its
    /// partner already has in the folder when that name is free, so the pair stays matched.
    static func plan(_ media: [CardFile], listing: Listing) -> Plan {
        // "-N" names made by an earlier import: "dsc00001.arw" -> [(2, …/DSC00001-2.ARW), …]
        var suffixed: [String: [(n: Int, file: DestFile)]] = [:]
        for (key, ds) in listing.files {
            guard let (original, n) = unsuffixed(key) else { continue }
            for d in ds { suffixed[original, default: []].append((n, d)) }
        }
        // Every same-size candidate, best first: the exact name (top folder first), then "-2", "-3"…
        var candidates: [String: [DestFile]] = [:]
        var exact: [String: [DestFile]] = [:]
        for f in media {
            let key = f.name.lowercased()
            exact[f.id] = (listing.files[key] ?? []).filter { $0.size == f.size }
            let dashed = (suffixed[key] ?? []).filter { $0.file.size == f.size }.sorted { $0.n < $1.n }.map(\.file)
            let all = exact[f.id]! + dashed
            if !all.isEmpty { candidates[f.id] = all }
        }

        // The match shown before importing: exact names first for every card file, then "-N" names,
        // each folder file used once.
        var used = Set<String>()                 // folder file paths already claimed by a card file
        var alreadyThere: [String: DestFile] = [:]
        for f in media {
            if let d = exact[f.id]?.first(where: { !used.contains($0.url.path) }) {
                alreadyThere[f.id] = d; used.insert(d.url.path)
            }
        }
        for f in media where alreadyThere[f.id] == nil {
            if let d = candidates[f.id]?.first(where: { !used.contains($0.url.path) }) {
                alreadyThere[f.id] = d; used.insert(d.url.path)
            }
        }

        // 3. Names for the files still to copy, keeping RAW+JPEG pairs together.
        var taken = listing.takenNames
        var destNames: [String: String] = [:]
        var groups: [String: [CardFile]] = [:]
        var order: [String] = []
        for f in media {
            let key = groupKey(f)
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(f)
        }
        for key in order {
            let members = groups[key]!
            let toCopy = members.filter { alreadyThere[$0.id] == nil }
            guard !toCopy.isEmpty else { continue }
            // The suffix the pair's partner already has in the folder (1 = no suffix).
            let partnerN = members.compactMap { m -> Int? in
                guard let d = alreadyThere[m.id] else { return nil }
                return d.name.lowercased() == m.name.lowercased() ? 1 : unsuffixed(d.name.lowercased())?.n
            }.first
            func names(_ n: Int) -> [String] { toCopy.map { suffixedName($0.name, n) } }
            func free(_ n: Int) -> Bool { names(n).allSatisfy { !taken.contains($0.lowercased()) } }
            var n = partnerN ?? 1
            if !free(n) {
                n = 1
                while !free(n) { n += 1 }
            }
            for (f, name) in zip(toCopy, names(n)) {
                destNames[f.id] = name
                taken.insert(name.lowercased())
            }
        }
        return Plan(alreadyThere: alreadyThere, candidates: candidates, destNames: destNames)
    }

    /// Files sharing a card folder and base name (a RAW+JPEG pair) form one group, as in CardScanner.
    private static func groupKey(_ f: CardFile) -> String {
        ((f.relativePath as NSString).deletingLastPathComponent + "/"
            + (f.name as NSString).deletingPathExtension).lowercased()
    }

    /// The first "-2", "-3"… version of `name` that nobody uses.
    static func freeName(_ name: String, taken: Set<String>) -> String {
        var n = 2
        while taken.contains(suffixedName(name, n).lowercased()) { n += 1 }
        return suffixedName(name, n)
    }

    static func suffixedName(_ name: String, _ n: Int) -> String {
        guard n > 1 else { return name }
        let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        return ext.isEmpty ? "\(base)-\(n)" : "\(base)-\(n).\(ext)"
    }

    /// "dsc00001-2.arw" -> ("dsc00001.arw", 2). Only suffixes of 2 or more, as the scanner makes.
    private static func unsuffixed(_ name: String) -> (String, n: Int)? {
        let ext = (name as NSString).pathExtension
        let stem = (name as NSString).deletingPathExtension
        guard let dash = stem.lastIndex(of: "-") else { return nil }
        let digits = stem[stem.index(after: dash)...]
        guard !digits.isEmpty, digits.allSatisfy(\.isASCII), digits.allSatisfy(\.isNumber),
              let n = Int(digits), n >= 2 else { return nil }
        let base = String(stem[..<dash])
        return (ext.isEmpty ? base : base + "." + ext, n)
    }
}
