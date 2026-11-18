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
            return runIsCheckOnly ? "Comparing… (nothing will be copied)"
                : "Checking \(Format.count(runCompareCount)) already in the folder, then copying \(Format.count(runCopyCount))"
        case .copying where runIsCheckOnly:
            return "Copying \(Format.count(differingCount)) that differ, as new names"
        case .copying:
            return "Copying and verifying…"
        }
    }

    /// The "3 of 378" line under the progress bar, saying which step it counts.
    var runCountText: String {
        switch runStage {
        case .comparing:
            return "Checking \(Format.count(currentIndex)) of \(Format.count(runCompareCount))"
        case .copying:
            let copyTotal = runCopyCount + differingCount
            return "Copying \(Format.count(max(0, currentIndex - runCompareCount))) of \(Format.count(copyTotal))"
        }
    }

    /// The hint before an existing folder is chosen.
    var existingFolderHint: String {
        "Files already in this folder or its subfolders are found by name and size, then confirmed by checksum. Nothing in it is replaced."
    }

    /// The note under the chosen existing folder, before starting. Nothing is called "already there"
    /// until its checksum has been compared.
    var existingFolderSummary: String {
        let there = alreadyThere.count, new = filesToCopyCount
        if new == 0 {
            return "All \(Format.count(there)) \(noun(for: cardFiles, count: there)) seem to be in the folder (same name and size). "
                + "Checking compares their checksums; nothing is copied unless one differs."
        }
        if there == 0 { return "None of the card's files are in this folder yet." }
        return "\(Format.count(new)) new \(new == 1 ? "file" : "files") to copy. \(Format.count(there)) more seem to be in the folder already; "
            + "they'll be confirmed by checksum."
    }

    /// The right-hand pane before a run.
    var emptyPaneText: (title: String, detail: String) {
        checkOnlyBeforeStart
            ? ("Not Checked Yet", "Files appear here once their checksums match the folder's copies.")
            : ("Not Imported Yet", "Copies will appear here, lined up with the card.")
    }

    /// The button that picks up a stopped run.
    var finishButtonTitle: String {
        switch (notCheckedCount > 0, notCopiedCount > 0) {
        case (true, false): return "Finish Checking (\(Format.count(notCheckedCount)))"
        case (false, true): return "Copy Remaining \(Format.count(notCopiedCount))"
        default: return "Finish the Remaining \(Format.count(unfinishedCount))"
        }
    }

    /// Under the card's name in the sidebar after it was removed.
    var ejectedDetail: String {
        if phase == .done && allVerified { return "Ejected · safe to remove" }
        if phase == .importing { return "Card removed during import" }
        if phase == .done {
            let unconfirmed = cardFiles.count - verifiedCount - alreadyThereCount
            return "Card removed. \(Format.count(unconfirmed)) \(unconfirmed == 1 ? "file wasn't" : "files weren't") confirmed, so keep the card."
        }
        return "Ejected · plug in a card"
    }

    /// The small line under a row's folder file.
    func rowSubtitle(_ file: CardFile, _ dest: DestFile) -> String? {
        if statuses[file.id] == .alreadyThere {
            return dest.name == file.name && dest.url.deletingLastPathComponent() == destinationURL ? nil
                : "already in the folder as \(file.destName)"
        }
        guard dest.name != file.name else { return nil }
        if differingIDs.contains(file.id) {
            return "a different file already had this name, so it was copied as \(dest.name)"
        }
        return "renamed to avoid a duplicate name"
    }

    /// green: confirmed; stopped: not finished (grey); attention: needs Aiden (drive full, card removed); bad: real failures.
    enum ResultTone { case good, stopped, attention, bad }

    var resultTone: ResultTone {
        if allVerified { return .good }
        if problemCount > 0 { return .bad }
        if diskFull || cardRemovedDuringRun { return .attention }
        return .stopped
    }

    private var keepCard: String { "Keep the card until it's finished." }

    var resultTitle: String {
        let there = alreadyThereCount, copied = verifiedCount
        if diskFull && problemCount == 0 { return "The destination drive is full" }
        if cardRemovedDuringRun && !allVerified {
            return runIsCheckOnly ? "The card was removed before the check finished" : "The card was removed before the import finished"
        }
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
        if problemCount == 0 { return "Import stopped" }
        return problemCount == 1 ? "1 file has a problem" : "\(Format.count(problemCount)) files have problems"
    }

    var resultDetail: String {
        let copied = verifiedCount, there = alreadyThereCount
        let nothingCopied = copied == 0 ? "Nothing was copied." : nil
        if allVerified {
            if copied == 0 { return "Nothing copied. Each one was compared by SHA-256 with the folder's copy." }
            let saved = manifestWritten ? " Checksums saved to \(manifestFileName)." : ""
            let differ = differingCount > 0
                ? " \(Format.count(differingCount)) had the same name and size as a file in the folder but different contents, so they were copied alongside it; nothing in the folder was changed." : ""
            if there > 0 {
                return "The \(Format.count(copied)) copies match two separate reads of the card; the \(Format.count(there)) already there have the same checksum as the card.\(saved)\(differ)"
            }
            return "Every copy's SHA-256 checksum matches two separate reads of the card.\(saved)\(differ)"
        }
        if problemCount == 0 {
            var parts: [String] = []
            if copied > 0 { parts.append("\(Format.count(copied)) copied and verified.") }
            if there > 0 && !runIsCheckOnly { parts.append("\(Format.count(there)) already there.") }
            if notCopiedCount > 0 { parts.append("\(Format.count(notCopiedCount)) not copied yet.") }
            if notCheckedCount > 0 { parts.append("\(Format.count(notCheckedCount)) not checked.") }
            if let nothingCopied { parts.append(nothingCopied) }
            if diskFull { parts.append("Free up space on the drive, then choose \(finishButtonTitle).") }
            else if cardRemovedDuringRun { parts.append("Put the card back in to finish.") }
            else { parts.append(keepCard) }
            return parts.joined(separator: " ")
        }
        let thereText = there > 0 ? ", \(Format.count(there)) already there" : ""
        let unfinished = unfinishedCount > 0 ? ", \(Format.count(unfinishedCount)) not finished" : ""
        return "\(Format.count(copied)) verified\(thereText)\(unfinished), \(Format.count(problemCount)) failed. Don't wipe this card."
    }

    /// Asked when quitting during a run.
    var quitWarning: (title: String, detail: String) {
        runIsCheckOnly && differingCount == 0
            ? ("A check is still running", "Quitting stops the check. Nothing has been copied.")
            : ("An import is still running", "If you quit now, the folder will be incomplete and nothing on the card will be verified.")
    }
}
