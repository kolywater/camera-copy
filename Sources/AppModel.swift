import SwiftUI
import AppKit
import Observation

enum ViewMode: String, CaseIterable, Identifiable {
    case list, grid
    var id: String { rawValue }
}

enum DestinationMode: String, CaseIterable, Identifiable {
    /// Make a new folder for this card (the original behavior).
    case newFolder
    /// Copy into a folder that already exists, skipping files it already has. Nothing in it is replaced.
    case existingFolder
    var id: String { rawValue }
}

enum Phase: Equatable {
    case idle, scanning, ready, importing, done
}

@Observable
@MainActor
final class AppModel {
    var sourcePath = ""
    var folderName = ""
    var parentPath: String {
        didSet { UserDefaults.standard.set(parentPath, forKey: "parentPath") }
    }

    var destinationMode: DestinationMode = .newFolder {
        didSet { if destinationMode != oldValue { destinationChanged() } }
    }
    var existingFolderPath = ""
    /// Existing-folder mode: card file id -> the file the folder already has (same name and size).
    var alreadyThere: [String: DestFile] = [:]
    /// Existing-folder mode: card file id -> every same-name-and-size file anywhere in the folder, best first.
    @ObservationIgnored private var candidateLists: [String: [DestFile]] = [:]

    var phase: Phase = .idle
    var cardFiles: [CardFile] = []
    var skippedFiles: [String] = []
    var statuses: [String: VerifyStatus] = [:]
    /// Card file id -> the file actually found in the destination folder.
    var destFiles: [String: DestFile] = [:]
    /// Files in the destination folder that don't correspond to anything on the card.
    var extraDestFiles: [DestFile] = []
    var destinationURL: URL?

    var bytesDone: Int64 = 0
    var bytesTotal: Int64 = 0
    /// "About 4 min left" while importing; "Estimating…" for the first few seconds.
    var timeLeftText: String?
    /// Lets a quick retry's time-left loop take over from the previous run's.
    @ObservationIgnored private var runGeneration = 0
    var currentIndex = 0
    var currentFileName = ""
    var wasCancelled = false
    var manifestError: String?

    var scanError: String?
    var alertMessage: String?

    /// The separate verify-card.sh check. It only runs when the user clicks "Run Independent Check".
    var independentCheck = IndependentCheck()

    /// The names CardScanner gave each file, used as-is in new-folder mode.
    @ObservationIgnored private var scannedDestNames: [String: String] = [:]
    /// Every name in the destination folder before this import started. Those files are never replaced.
    @ObservationIgnored private var preexistingNames: Set<String> = []
    @ObservationIgnored private(set) var manifestFileName = Importer.manifestName
    /// How many files the running import (or retry) copies.
    var runCount = 0

    /// Copies and verifies one file; tests swap in a faulty one to check how bad copies are reported.
    typealias Copier = @Sendable (_ from: URL, _ to: URL, _ size: Int64, _ modified: Date, _ mayReplace: Bool,
                                  _ cancel: CancelToken, _ progress: (Int64) -> Void) throws -> Importer.CopyResult
    @ObservationIgnored var copier: Copier = {
        try Importer.copyAndVerify(from: $0, to: $1, expectedSize: $2, modified: $3, mayReplace: $4, cancel: $5, progress: $6)
    }
    /// Fingerprints one file (used to confirm "already there" in an existing folder).
    @ObservationIgnored var hasher: @Sendable (URL, CancelToken, (Int64) -> Void) throws -> String = {
        try Importer.hashFile($0, cancel: $1, progress: $2)
    }

    @ObservationIgnored private var cancelToken: CancelToken?
    /// Keeps the Mac from idle-sleeping in the middle of a long import.
    @ObservationIgnored private var sleepActivity: NSObjectProtocol?
    @ObservationIgnored private var mountObserver: NSObjectProtocol?
    @ObservationIgnored private var unmountObserver: NSObjectProtocol?
    /// The source card was ejected or unplugged. Import results stay on screen as a record.
    var sourceEjected = false

    init() {
        parentPath = UserDefaults.standard.string(forKey: "parentPath")
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures").path

        mountObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didMountNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let url = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL else { return }
            MainActor.assumeIsolated { self?.volumeMounted(url) }
        }

        unmountObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didUnmountNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let url = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL else { return }
            MainActor.assumeIsolated { self?.volumeUnmounted(url) }
        }

        if let card = Self.findCameraCard() {
            sourcePath = card.path
            scanSource()
        }
    }

    // MARK: - Derived state

    var sanitizedFolderName: String {
        folderName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var destinationPreview: String {
        let name = sanitizedFolderName.isEmpty ? "<folder name>" : sanitizedFolderName
        return (parentPath as NSString).appendingPathComponent(name)
    }

    var sourceDisplayName: String {
        guard !sourcePath.isEmpty else { return "No card" }
        let url = URL(fileURLWithPath: sourcePath)
        return (try? url.resourceValues(forKeys: [.volumeLocalizedNameKey]).volumeLocalizedName)
            .flatMap { url.path == "/" ? nil : (url.deletingLastPathComponent().path == "/Volumes" ? $0 : nil) }
            ?? url.lastPathComponent
    }

    var parentDisplayName: String {
        FileManager.default.displayName(atPath: parentPath)
    }

    var totalCardBytes: Int64 { cardFiles.reduce(0) { $0 + $1.size } }

    var canImport: Bool {
        guard (phase == .ready || phase == .done) && !sourceEjected && !cardFiles.isEmpty else { return false }
        switch destinationMode {
        case .newFolder: return folderNameError == nil
        // Even with nothing new, importing confirms by checksum that the matching files really are the same.
        case .existingFolder: return existingFolderError == nil
        }
    }

    var existingFolderDisplayName: String {
        existingFolderPath.isEmpty ? "Choose…" : FileManager.default.displayName(atPath: existingFolderPath)
    }

    var existingFolderError: String? {
        if existingFolderPath.isEmpty { return "Choose a folder" }
        var isDir: ObjCBool = false
        if !FileManager.default.fileExists(atPath: existingFolderPath, isDirectory: &isDir) || !isDir.boolValue {
            return "That folder isn't there anymore"
        }
        if isOnCard(URL(fileURLWithPath: existingFolderPath)) { return "That folder is on the card" }
        return nil
    }

    /// Files the next import will copy (in existing-folder mode, those the folder doesn't have yet).
    var filesToCopyCount: Int {
        destinationMode == .existingFolder ? cardFiles.count - alreadyThere.count : cardFiles.count
    }

    var alreadyThereCount: Int {
        cardFiles.filter { statuses[$0.id] == .alreadyThere }.count
    }

    private func isOnCard(_ url: URL) -> Bool {
        guard !sourcePath.isEmpty else { return false }
        let root = URL(fileURLWithPath: sourcePath).standardizedFileURL.path
        let p = url.standardizedFileURL.path
        return p == root || p.hasPrefix(root + "/")
    }

    var folderNameError: String? {
        let n = sanitizedFolderName
        if n.isEmpty { return "Enter a folder name" }
        if n.contains("/") || n.contains(":") { return "Folder name can't contain / or :" }
        if n.hasPrefix(".") { return "Folder name can't start with ." }
        return nil
    }

    var verifiedCount: Int {
        cardFiles.filter { statuses[$0.id]?.isVerified == true && destFiles[$0.id] != nil }.count
    }

    func isProblem(_ file: CardFile) -> Bool {
        guard phase == .done else { return false }
        return statuses[file.id]?.isSafe != true || destFiles[file.id] == nil
    }

    var problemCount: Int { cardFiles.filter(isProblem).count }

    var allVerified: Bool {
        phase == .done && !wasCancelled && !cardFiles.isEmpty && problemCount == 0
    }

    // MARK: - Source

    static func findCameraCard() -> URL? {
        let volumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil,
                                                            options: [.skipHiddenVolumes]) ?? []
        return volumes.first { isCameraCard($0) }
    }

    static func isCameraCard(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.appendingPathComponent("DCIM").path)
            || FileManager.default.fileExists(atPath: url.appendingPathComponent("PRIVATE/M4ROOT").path)
    }

    private func volumeMounted(_ url: URL) {
        // A new card can reuse the old card's volume name and file names, so drop cached thumbnails.
        ThumbnailLoader.shared.removeAll()
        guard phase != .importing, Self.isCameraCard(url) else { return }

        // The same card coming back after a failed import: keep the results so the failures can be retried.
        let volume = url.standardizedFileURL.path
        let source = URL(fileURLWithPath: sourcePath).standardizedFileURL.path
        if phase == .done, sourceEjected, problemCount > 0, source == volume || source.hasPrefix(volume + "/") {
            reconnectIfSameCard(newVolume: url)
            return
        }

        // A new card after a finished import is a new shoot, so it needs a new folder name.
        if phase == .done { folderName = "" }
        sourcePath = url.path
        scanSource()
    }

    /// Rescans and keeps the current results only if the card holds exactly the same files as before.
    private func reconnectIfSameCard(newVolume: URL) {
        let root = URL(fileURLWithPath: sourcePath)
        let previous = cardFiles.map { "\($0.relativePath)|\($0.size)|\($0.modified.timeIntervalSince1970)" }
        Task.detached {
            let scanned = (try? CardScanner.scan(root: root))?.media
                .map { "\($0.relativePath)|\($0.size)|\($0.modified.timeIntervalSince1970)" }
            await MainActor.run {
                if scanned == previous {
                    self.sourceEjected = false
                } else {
                    self.folderName = ""
                    self.sourcePath = newVolume.path
                    self.scanSource()
                }
            }
        }
    }

    private func volumeUnmounted(_ url: URL) {
        let volume = url.standardizedFileURL.path
        let source = URL(fileURLWithPath: sourcePath).standardizedFileURL.path
        guard !sourcePath.isEmpty, source == volume || source.hasPrefix(volume + "/") else { return }
        markSourceEjected()
    }

    private func markSourceEjected() {
        sourceEjected = true
        // Keep a finished import on screen as a record; otherwise there's nothing left to show.
        if phase == .ready || phase == .scanning || phase == .idle {
            cardFiles = []
            skippedFiles = []
            resetResults()
            phase = .idle
        }
    }

    func chooseSource() {
        guard phase != .importing else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: sourcePath.isEmpty ? "/Volumes" : sourcePath)
        panel.prompt = "Use as Source"
        if panel.runModal() == .OK, let url = panel.url {
            sourcePath = url.path
            scanSource()
        }
    }

    func chooseParent() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: parentPath)
        panel.prompt = "Save Imports Here"
        if panel.runModal() == .OK, let url = panel.url {
            parentPath = url.path
        }
    }

    func chooseExistingFolder() {
        guard phase != .importing else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: existingFolderPath.isEmpty ? parentPath : existingFolderPath)
        panel.prompt = "Add to This Folder"
        panel.message = "Choose a folder. Files already in it are skipped, and nothing in it is replaced."
        if panel.runModal() == .OK, let url = panel.url {
            existingFolderPath = url.path
            destinationChanged()
        }
    }

    /// A different destination starts a fresh import plan; finished results belong to the old one.
    private func destinationChanged() {
        guard phase != .importing else { return }
        if phase == .done {
            resetResults()
            for f in cardFiles { statuses[f.id] = .pending }
            phase = .ready
        }
        planDestination()
    }

    /// Works out which card files the chosen folder already has, and the names new copies get.
    /// Returns the folder listing it used, or nil in new-folder mode.
    @discardableResult
    private func planDestination() -> ExistingFolder.Listing? {
        guard destinationMode == .existingFolder, existingFolderError == nil else {
            for i in cardFiles.indices { cardFiles[i].destName = scannedDestNames[cardFiles[i].id] ?? cardFiles[i].name }
            alreadyThere = [:]
            candidateLists = [:]
            if phase == .ready { for f in cardFiles where statuses[f.id] == .alreadyThere { statuses[f.id] = .pending } }
            return nil
        }
        let listing = ExistingFolder.list(URL(fileURLWithPath: existingFolderPath))
        let plan = ExistingFolder.plan(cardFiles, listing: listing)
        for i in cardFiles.indices {
            let id = cardFiles[i].id
            cardFiles[i].destName = plan.alreadyThere[id].map(listing.relativePath) ?? plan.destNames[id] ?? cardFiles[i].name
        }
        alreadyThere = plan.alreadyThere
        candidateLists = plan.candidates
        if phase == .ready {
            for f in cardFiles { statuses[f.id] = plan.alreadyThere[f.id] != nil ? .alreadyThere : .pending }
        }
        return listing
    }

    /// The card and folder of the last finished import, offered to the independent check.
    var lastImport: (card: String, folder: String)? {
        guard phase == .done, let destinationURL, !sourcePath.isEmpty else { return nil }
        return (sourcePath, destinationURL.path)
    }

    /// Runs verify-card.sh on the last import's card and folder.
    func runIndependentCheckOnLastImport() {
        guard let target = lastImport, !sourceEjected else { return }
        independentCheck.run(card: target.card, folder: target.folder)
    }

    /// Asks for any card (or folder copied from one) and any folder, then runs verify-card.sh on them.
    func chooseAndRunIndependentCheck() {
        guard phase != .importing else { return }
        let card = NSOpenPanel()
        card.canChooseDirectories = true; card.canChooseFiles = false
        card.directoryURL = URL(fileURLWithPath: sourcePath.isEmpty ? "/Volumes" : sourcePath)
        card.message = "Choose the card to check (its top folder, so videos in PRIVATE are included)."
        card.prompt = "Use This Card"
        guard card.runModal() == .OK, let cardURL = card.url else { return }
        let folder = NSOpenPanel()
        folder.canChooseDirectories = true; folder.canChooseFiles = false
        folder.directoryURL = URL(fileURLWithPath: destinationURL?.path ?? parentPath)
        folder.message = "Choose the folder this card was imported into."
        folder.prompt = "Check This Folder"
        guard folder.runModal() == .OK, let folderURL = folder.url else { return }
        independentCheck.run(card: cardURL.path, folder: folderURL.path)
    }

    func scanSource() {
        guard phase != .importing else { return }
        independentCheck.reset()
        let path = sourcePath.trimmingCharacters(in: .whitespacesAndNewlines)
        resetResults()
        sourceEjected = false
        cardFiles = []
        skippedFiles = []
        scanError = nil
        guard !path.isEmpty else { phase = .idle; return }

        phase = .scanning
        let root = URL(fileURLWithPath: path)
        Task.detached {
            let result = Result { try CardScanner.scan(root: root) }
            await MainActor.run {
                guard self.sourcePath.trimmingCharacters(in: .whitespacesAndNewlines) == path else { return }
                switch result {
                case .success(let r):
                    self.cardFiles = r.media
                    self.skippedFiles = r.skipped
                    self.scannedDestNames = Dictionary(uniqueKeysWithValues: r.media.map { ($0.id, $0.destName) })
                    for f in r.media { self.statuses[f.id] = .pending }
                    self.alreadyThere = [:]
                    self.phase = .ready
                    self.planDestination()
                case .failure(let e):
                    self.scanError = e.localizedDescription
                    self.phase = .idle
                }
            }
        }
    }

    private func resetResults() {
        statuses = [:]
        destFiles = [:]
        extraDestFiles = []
        destinationURL = nil
        bytesDone = 0
        bytesTotal = 0
        currentIndex = 0
        currentFileName = ""
        wasCancelled = false
        manifestError = nil
    }

    // MARK: - Import

    func startImport() {
        guard canImport else { return }
        if destinationMode == .existingFolder { startImportIntoExisting(); return }
        let dest = URL(fileURLWithPath: parentPath).appendingPathComponent(sanitizedFolderName)
        let fm = FileManager.default

        if fm.fileExists(atPath: dest.path) {
            alertMessage = "A folder named “\(sanitizedFolderName)” already exists in \(parentPath). Pick a different name."
            return
        }

        let sourceRoot = URL(fileURLWithPath: sourcePath).standardizedFileURL.path
        if dest.standardizedFileURL.path.hasPrefix(sourceRoot + "/") {
            alertMessage = "The destination is on the card itself. Choose a location on another drive."
            return
        }

        let needed = totalCardBytes
        if let free = try? URL(fileURLWithPath: parentPath)
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage,
           free < needed + 1_000_000_000 {
            alertMessage = "Not enough space: this import needs \(Format.size(needed)) but only \(Format.size(free)) is free."
            return
        }

        do {
            try fm.createDirectory(at: dest, withIntermediateDirectories: true)
        } catch {
            alertMessage = "Couldn't create the folder: \(error.localizedDescription)"
            return
        }

        resetResults()
        for f in cardFiles { statuses[f.id] = .pending }
        destinationURL = dest
        preexistingNames = []
        manifestFileName = Importer.manifestName
        run(cardFiles, into: dest)
    }

    /// Copies only the card files the folder doesn't already have. Never replaces or deletes anything in it.
    private func startImportIntoExisting() {
        let dest = URL(fileURLWithPath: existingFolderPath)
        if phase == .done {
            resetResults()
            phase = .ready
        }
        // Re-read the folder now, in case it changed since it was chosen.
        guard let listing = planDestination() else {
            alertMessage = existingFolderError ?? "Choose a folder to add to."
            return
        }
        // Same name and size is only a candidate: run() compares checksums before calling it "already there".
        let toCopy = cardFiles.filter { alreadyThere[$0.id] == nil }
        let candidates = cardFiles.compactMap { f in alreadyThere[f.id].map { (card: f, folder: candidateLists[f.id] ?? [$0]) } }

        let needed = toCopy.reduce(0) { $0 + $1.size }
        if let free = try? dest.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage,
           free < needed + 1_000_000_000 {
            alertMessage = "Not enough space: this import needs \(Format.size(needed)) but only \(Format.size(free)) is free."
            return
        }

        resetResults()
        for f in cardFiles { statuses[f.id] = .pending }
        destinationURL = dest
        preexistingNames = listing.takenNames
        manifestFileName = Importer.newManifestName(taken: listing.takenNames)
        run(toCopy, into: dest, confirming: candidates)
    }

    var canRetry: Bool {
        phase == .done && destinationURL != nil && !sourceEjected && problemCount > 0
    }

    /// Copies and verifies again only the files that failed, into the same folder.
    func retryFailed() {
        guard canRetry, let dest = destinationURL else { return }
        let failed = cardFiles.filter(isProblem)
        for f in failed { statuses[f.id] = .pending }
        // A file that was only a same-name-and-size candidate is compared again, never copied over.
        let candidates = failed.compactMap { f in alreadyThere[f.id].map { (card: f, folder: candidateLists[f.id] ?? [$0]) } }
        run(failed.filter { alreadyThere[$0.id] == nil }, into: dest, confirming: candidates)
    }

    /// Copies `files` into `dest`. First, each of `candidates` (a card file and the folder files, anywhere
    /// in the folder, with the same name and size) is compared by SHA-256: if one has the same contents
    /// it counts as already there (each folder file only once); otherwise the card file is copied
    /// under a new, free name in the top folder, and the folder's own files are left alone.
    private func run(_ files: [CardFile], into dest: URL, confirming candidates: [(card: CardFile, folder: [DestFile])] = []) {
        independentCheck.reset()       // its result belonged to the folder as it was before this import
        bytesDone = 0
        bytesTotal = files.reduce(0) { $0 + $1.size } * 3   // copy + read back the copy + re-read the card
            + candidates.reduce(0) { $0 + $1.card.size } * 2  // read the card file + read the folder file
        runCount = files.count + candidates.count
        timeLeftText = "Estimating…"
        currentIndex = 0
        wasCancelled = false
        manifestError = nil
        phase = .importing

        let token = CancelToken()
        cancelToken = token
        let preexisting = preexistingNames
        let manifestName = manifestFileName
        let copier = self.copier, hasher = self.hasher
        sleepActivity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled], reason: "Copying photos and videos")

        // Once a second, update the time left from the bytes done so far.
        runGeneration += 1
        let generation = runGeneration
        Task { @MainActor in
            var estimator = TimeLeftEstimator()
            while self.phase == .importing && self.runGeneration == generation {
                if let seconds = estimator.sample(done: self.bytesDone, total: self.bytesTotal) {
                    self.timeLeftText = TimeLeftEstimator.text(seconds)
                }
                try? await Task.sleep(for: .seconds(1))
            }
            if self.runGeneration == generation { self.timeLeftText = nil }
        }

        Task.detached(priority: .userInitiated) {
            // 1. Compare each same-name-and-size candidate with the folder's file, by checksum.
            var different: [CardFile] = []
            var claimed = Set<String>()                      // folder files already standing in for a card file
            var folderHashes: [String: String] = [:]
            for (index, c) in candidates.enumerated() {
                if token.isCancelled { break }
                await MainActor.run {
                    self.currentIndex = index + 1
                    self.currentFileName = c.card.name
                    self.statuses[c.card.id] = .copying
                }
                let status: VerifyStatus
                var match: DestFile?
                do {
                    let progress: (Int64) -> Void = { n in Task { @MainActor in self.bytesDone += n } }
                    let onCard = try hasher(c.card.url, token, progress)
                    for (i, d) in c.folder.enumerated() where !claimed.contains(d.url.path) {
                        if i > 0 { await MainActor.run { self.bytesTotal += d.size } }
                        let inFolder: String
                        if let known = folderHashes[d.url.path] {
                            inFolder = known
                        } else {
                            // A folder file that can't be read just isn't a match; the card file then gets copied.
                            do { inFolder = try hasher(d.url, token, progress) } catch is CancellationError { throw CancellationError() } catch { continue }
                            folderHashes[d.url.path] = inFolder
                        }
                        if inFolder == onCard { match = d; break }
                    }
                    if let match {
                        claimed.insert(match.url.path)
                        status = .alreadyThere
                    } else {
                        different.append(c.card)
                        status = .pending
                    }
                } catch is CancellationError {
                    status = .failed("Cancelled")
                } catch {
                    status = .failed("Couldn't compare with the folder: \(error.localizedDescription)")
                }
                let matched = match
                await MainActor.run {
                    self.statuses[c.card.id] = status
                    if let matched, let i = self.cardFiles.firstIndex(where: { $0.id == c.card.id }) {
                        self.alreadyThere[c.card.id] = matched
                        self.cardFiles[i].destName = ExistingFolder.Listing(root: dest, files: [:], takenNames: []).relativePath(matched)
                    }
                }
            }
            // Different photos that only share a name and size get a new name and are copied.
            let differing = different
            let renamed: [CardFile] = await MainActor.run {
                var taken = preexisting.union(self.cardFiles.map { $0.destName.lowercased() })
                return differing.map { card in
                    // New copies go in the top folder: the card's own name if it's free there, else "-2", "-3"…
                    let name = taken.contains(card.name.lowercased()) ? ExistingFolder.freeName(card.name, taken: taken) : card.name
                    taken.insert(name.lowercased())
                    self.alreadyThere[card.id] = nil
                    self.bytesTotal += card.size * 3
                    if let i = self.cardFiles.firstIndex(where: { $0.id == card.id }) { self.cardFiles[i].destName = name }
                    var updated = card
                    updated.destName = name
                    return updated
                }
            }
            let toCopy = files + renamed
            let offset = candidates.count

            // 2. Copy and verify.
            for (index, file) in toCopy.enumerated() {
                if token.isCancelled { break }
                await MainActor.run {
                    self.currentIndex = offset + index + 1
                    self.currentFileName = file.name
                    self.statuses[file.id] = .copying
                }

                let target = dest.appendingPathComponent(file.destName)
                let status: VerifyStatus
                do {
                    let r = try copier(file.url, target, file.size, file.modified,
                                       !preexisting.contains(file.destName.lowercased()), token) { n in
                        Task { @MainActor in self.bytesDone += n }
                    }
                    if r.allMatch {
                        status = .verified(hash: r.destHash)
                    } else if r.sourceHash != r.sourceRereadHash {
                        status = .failed("The card gave different data on two reads, so the card or reader may be failing")
                    } else {
                        status = .failed("Checksum mismatch: the copy differs from the card")
                    }
                } catch is CancellationError {
                    status = .failed("Cancelled")
                } catch {
                    status = .failed(error.localizedDescription)
                }

                let destFile = Importer.destFile(at: target)
                await MainActor.run {
                    self.statuses[file.id] = status
                    if let destFile { self.destFiles[file.id] = destFile }
                }
            }

            // The manifest always covers every verified file in the folder, including earlier runs.
            let manifest: [(name: String, hash: String)] = await MainActor.run {
                self.cardFiles.compactMap { f in
                    if case .verified(let hash) = self.statuses[f.id] { return (f.destName, hash) }
                    return nil
                }
            }
            var manifestError: String?
            do {
                try Importer.writeManifest(manifest, to: dest, named: manifestName)
            } catch {
                manifestError = error.localizedDescription
            }
            let savedError = manifestError
            await MainActor.run { self.manifestError = savedError }
            await self.reconcile(dest: dest, cancelled: token.isCancelled)
        }
    }

    func cancelImport() {
        cancelToken?.cancel()
    }

    /// Final pass: list the destination folder from scratch and check every card file is there, at full size.
    private func reconcile(dest: URL, cancelled: Bool) {
        let listing = Importer.listDestination(dest)
        var expected = Set<String>()
        var found: [String: DestFile] = [:]

        for file in cardFiles {
            // Confirmed already there, possibly in a subfolder: look at that very file again.
            if statuses[file.id] == .alreadyThere, let match = alreadyThere[file.id] {
                guard let d = Importer.destFile(at: match.url) else {
                    statuses[file.id] = .failed("No longer in the folder")
                    continue
                }
                if d.size != file.size { statuses[file.id] = .failed("Size in folder (\(d.size)) differs from card (\(file.size))") }
                found[file.id] = d
                continue
            }
            let key = file.destName.lowercased()
            expected.insert(key)
            guard let d = listing[key] else {
                if statuses[file.id]?.isSafe == true {
                    statuses[file.id] = .failed("Missing from folder")
                } else if statuses[file.id] == .pending || statuses[file.id] == .copying {
                    statuses[file.id] = .failed(cancelled ? "Not copied (cancelled)" : "Not copied")
                }
                continue
            }
            if d.size != file.size, statuses[file.id]?.isSafe == true {
                statuses[file.id] = .failed("Size in folder (\(d.size)) differs from card (\(file.size))")
            }
            found[file.id] = d
        }

        destFiles = found
        // An existing folder can hold anything, so only a new folder's leftovers count as unexpected.
        extraDestFiles = destinationMode == .existingFolder ? []
            : listing.filter { !expected.contains($0.key) }.map(\.value).sorted { $0.name < $1.name }
        wasCancelled = cancelled
        currentFileName = ""
        phase = .done
        cancelToken = nil
        if let sleepActivity { ProcessInfo.processInfo.endActivity(sleepActivity) }
        sleepActivity = nil
    }

    // MARK: - After import

    func revealDestination() {
        guard let destinationURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([destinationURL])
    }

    func ejectCard() {
        guard !independentCheck.isRunning else {
            alertMessage = "The independent check is still reading the card. Stop it or wait for it to finish, then eject."
            return
        }
        let url = URL(fileURLWithPath: sourcePath)
        let volume = (try? url.resourceValues(forKeys: [.volumeURLKey]).volume) ?? url
        do {
            try NSWorkspace.shared.unmountAndEjectDevice(at: volume)
            markSourceEjected()
        } catch {
            alertMessage = "Couldn't eject: \(error.localizedDescription)"
        }
    }
}
