import Foundation

/// Plans an import into a folder that already has files in it ("Add to existing folder").
/// Nothing here touches the disk except reading the folder listing.
enum ExistingFolder {
    struct Listing {
        /// Regular, non-hidden files at the top level of the folder, keyed by lowercased name.
        var files: [String: DestFile]
        /// Every name at the top level (files, folders, hidden items), lowercased. New copies never use one.
        var takenNames: Set<String>
    }

    struct Plan {
        /// Card file id -> the file already in the folder that counts as the same photo/video.
        var alreadyThere: [String: DestFile]
        /// Card file id -> the name a new copy gets. Never one of `Listing.takenNames`.
        var destNames: [String: String]
    }

    static func list(_ dir: URL) -> Listing {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        let urls = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys, options: [])) ?? []
        var files: [String: DestFile] = [:]
        var taken = Set<String>()
        for url in urls {
            let name = url.lastPathComponent
            taken.insert(name.lowercased())
            guard !name.hasPrefix("."),
                  let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
            files[name.lowercased()] = DestFile(url: url, name: name, size: Int64(v.fileSize ?? 0),
                                                modified: v.contentModificationDate ?? .distantPast)
        }
        return Listing(files: files, takenNames: taken)
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
        var used = Set<String>()                 // folder files already claimed by a card file
        var alreadyThere: [String: DestFile] = [:]

        // 1. Exact name + size.
        for f in media {
            let key = f.name.lowercased()
            if let d = listing.files[key], d.size == f.size, !used.contains(key) {
                alreadyThere[f.id] = d
                used.insert(key)
            }
        }

        // 2. A "-N" name made by an earlier import, same size.
        var suffixed: [String: [(n: Int, file: DestFile)]] = [:]   // "dsc00001.arw" -> [(2, DSC00001-2.ARW)]
        for (key, d) in listing.files {
            guard let (original, n) = unsuffixed(key) else { continue }
            suffixed[original, default: []].append((n, d))
        }
        for f in media where alreadyThere[f.id] == nil {
            let candidates = (suffixed[f.name.lowercased()] ?? []).sorted { $0.n < $1.n }
            if let hit = candidates.first(where: { $0.file.size == f.size && !used.contains($0.file.name.lowercased()) }) {
                alreadyThere[f.id] = hit.file
                used.insert(hit.file.name.lowercased())
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
        return Plan(alreadyThere: alreadyThere, destNames: destNames)
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
