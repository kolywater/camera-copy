import Foundation

/// Every word the sidebar shows about an import or a check, in one place so it can be tested.
///
/// In Existing Folder mode with nothing new on the card, the run only compares files: it reads,
/// copies nothing (unless a file turns out to differ) and writes nothing. Its wording says "check",
/// never "import"; copying words appear only once a differing file really is being copied.
extension AppModel {
    /// "photos", "videos" or "files", for the given card files.
    func noun(for files: [CardFile], count: Int) -> String {
        let kinds = Set(files.map(\.kind))
        let plural = count != 1
        switch kinds {
        case [.photo]: return plural ? "photos" : "photo"
        case [.video]: return plural ? "videos" : "video"
        default: return plural ? "files" : "file"
        }
    }

    /// Before starting: the files that would only be compared.
    var checkOnlyBeforeStart: Bool {
        destinationMode == .existingFolder && existingFolderError == nil && !searchingFolder
            && !cardFiles.isEmpty && filesToCopyCount == 0
    }

    var importButtonTitle: String {
        if cardFiles.isEmpty { return "Import" }
        guard destinationMode == .existingFolder, existingFolderError == nil else {
            return "Import \(Format.count(cardFiles.count)) Files"
        }
        if searchingFolder { return "Searching the Folder…" }
        let n = filesToCopyCount
        if n == 0 {
            let all = cardFiles.count
            return "Check \(Format.count(all)) \(noun(for: cardFiles, count: all).capitalized) Are Identical"
        }
        return "Import \(Format.count(n)) New \(n == 1 ? "File" : "Files")"
    }

    /// The sidebar section shown while running.
    var runSectionTitle: String { runIsCheckOnly ? "Checking" : "Importing" }

    var cancelTitle: String { runIsCheckOnly ? "Stop Checking" : "Cancel Import" }

    /// The line above the progress bar.
    var runHeadline: String {
        switch runStage {
        case .comparing:
            return runIsCheckOnly ? "Comparing… (nothing will be copied)" : "Comparing files already in the folder…"
        case .copying where runIsCheckOnly:
            return "Copying \(Format.count(differingCount)) that differ, as new names"
        case .copying:
            return "Copying and verifying…"
        }
    }

    /// The note under the chosen existing folder, before starting.
    var existingFolderSummary: String {
        let there = alreadyThere.count, new = filesToCopyCount
        if new == 0 {
            return "The folder has all \(Format.count(there)) \(noun(for: cardFiles, count: there)) by name and size. "
                + "Checking compares each one by SHA-256 and copies nothing unless one differs."
        }
        if there == 0 { return "\(Format.count(new)) to copy. None of them are in the folder yet." }
        return "\(Format.count(new)) to copy, \(Format.count(there)) with the same name and size. "
            + "Those are compared by SHA-256; any that differ are copied with a new name."
    }

    enum ResultTone { case good, stopped, bad }

    var resultTone: ResultTone {
        if allVerified { return .good }
        if problemCount == 0 && (notCheckedCount > 0 || wasCancelled) { return .stopped }
        return .bad
    }

    var resultTitle: String {
        let there = alreadyThereCount, copied = verifiedCount
        if runIsCheckOnly || (copied == 0 && there > 0 && problemCount == 0) {
            if allVerified {
                if differingCount > 0 {
                    return "\(Format.count(there)) identical, \(Format.count(differingCount)) copied as new names"
                }
                return "All \(Format.count(there)) already in the folder, identical"
            }
            if problemCount == 0 && notCheckedCount > 0 {
                return "Stopped: \(Format.count(there)) of \(Format.count(there + notCheckedCount)) confirmed identical"
            }
        }
        if allVerified && there > 0 { return "\(Format.count(copied)) copied, \(Format.count(there)) already there" }
        if allVerified { return "All \(Format.count(cardFiles.count)) files verified" }
        if wasCancelled && problemCount == 0 { return "Import stopped" }
        if wasCancelled { return "Import cancelled" }
        return "\(Format.count(problemCount)) files have problems"
    }

    var resultDetail: String {
        let copied = verifiedCount
        let nothingCopied = copied == 0 ? "Nothing was copied." : nil
        if allVerified {
            if copied == 0 { return "Nothing copied. Each one was compared by SHA-256 with the folder's copy." }
            let saved = manifestWritten ? " Checksums saved to \(manifestFileName)." : ""
            let differ = differingCount > 0
                ? " \(Format.count(differingCount)) had the same name and size as a file in the folder but different contents, so they were copied alongside it; nothing in the folder was changed." : ""
            return "Every copy's SHA-256 checksum matches two separate reads of the card.\(saved)\(differ)"
        }
        if problemCount == 0 {
            let rest = notCheckedCount > 0 ? "\(Format.count(notCheckedCount)) not checked. " : ""
            return rest + (nothingCopied ?? "\(Format.count(copied)) copied and verified.")
        }
        let there = alreadyThereCount > 0 ? ", \(Format.count(alreadyThereCount)) already there" : ""
        let notChecked = notCheckedCount > 0 ? ", \(Format.count(notCheckedCount)) not checked" : ""
        return "\(Format.count(copied)) verified\(there)\(notChecked), \(Format.count(problemCount)) not. Don't wipe this card."
    }

    /// Asked when quitting during a run.
    var quitWarning: (title: String, detail: String) {
        runIsCheckOnly && differingCount == 0
            ? ("A check is still running", "Quitting stops the check. Nothing has been copied.")
            : ("An import is still running", "If you quit now, the folder will be incomplete and nothing on the card will be verified.")
    }
}
