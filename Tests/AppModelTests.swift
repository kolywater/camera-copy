import XCTest

/// End-to-end imports through the app's model, on fake cards in a temp folder.
@MainActor
final class AppModelTests: TempDirTestCase {
    var card: URL { tmp.appendingPathComponent("CARD") }
    var out: URL { tmp.appendingPathComponent("out") }

    private func makeCard() throws {
        try makeFile("CARD/DCIM/100MSDCF/DSC00001.ARW", size: 5000, modified: day(1))
        try makeFile("CARD/DCIM/100MSDCF/DSC00001.JPG", size: 1500, modified: day(1))
        try makeFile("CARD/DCIM/101MSDCF/DSC00001.ARW", size: 5200, modified: day(2))
        try makeFile("CARD/DCIM/101MSDCF/DSC00001.JPG", size: 1700, modified: day(2))
        try makeFile("CARD/PRIVATE/M4ROOT/CLIP/C0001.MP4", size: 9000, modified: day(3))
        try makeFile("CARD/PRIVATE/M4ROOT/CLIP/C0001M01.XML", size: 100)
    }

    private func wait(_ model: AppModel, for phase: Phase, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(30)
        while model.phase != phase {
            if Date() > deadline { XCTFail("timed out waiting for \(phase), at \(model.phase)", file: file, line: line); return }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    /// Waits for the background search of the chosen folder to finish.
    private func searched(_ m: AppModel, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(30)
        while m.searchingFolder {
            if Date() > deadline { return XCTFail("folder search didn't finish", file: file, line: line) }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func readyModel() async throws -> AppModel {
        let m = AppModel()
        m.sourcePath = card.path
        m.parentPath = out.path
        m.scanSource()
        try await wait(m, for: .ready)
        return m
    }

    func testNewFolderImportCopiesVerifiesAndWritesChecksums() async throws {
        try makeCard()
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let m = try await readyModel()
        XCTAssertEqual(m.cardFiles.count, 5)
        XCTAssertEqual(m.skippedFiles, ["PRIVATE/M4ROOT/CLIP/C0001M01.XML"])
        XCTAssertNotNil(m.folderNameError)
        m.folderName = "  Shoot  "
        XCTAssertTrue(m.canImport)
        m.startImport()
        XCTAssertEqual(m.phase, .importing)
        XCTAssertEqual(m.timeLeftText, "Estimating…")
        try await wait(m, for: .done)
        XCTAssertTrue(m.allVerified)
        XCTAssertEqual(m.verifiedCount, 5)
        let shoot = out.appendingPathComponent("Shoot")
        XCTAssertEqual(try names(in: shoot), ["C0001.MP4", "DSC00001-2.ARW", "DSC00001-2.JPG", "DSC00001.ARW",
                                               "DSC00001.JPG", "checksums.sha256"])
        let check = Process()
        check.executableURL = URL(fileURLWithPath: "/usr/bin/shasum"); check.arguments = ["-a", "256", "-c", "checksums.sha256"]
        check.currentDirectoryURL = shoot; check.standardOutput = Pipe()
        try check.run(); check.waitUntilExit()
        XCTAssertEqual(check.terminationStatus, 0)

        // The same name again is refused, so nothing is ever merged by accident.
        m.startImport()
        XCTAssertTrue(m.alertMessage?.contains("already exists") == true)
    }

    func testFolderNameRules() async throws {
        try makeCard()
        let m = try await readyModel()
        for bad in ["", "   ", "a/b", "a:b", ".hidden"] {
            m.folderName = bad
            XCTAssertNotNil(m.folderNameError, bad)
            XCTAssertFalse(m.canImport, bad)
        }
        m.folderName = "Iceland"
        XCTAssertNil(m.folderNameError)
        XCTAssertTrue(m.destinationPreview.hasSuffix("/Iceland"))
    }

    func testRefusesADestinationOnTheCard() async throws {
        try makeCard()
        let m = try await readyModel()
        m.parentPath = card.appendingPathComponent("DCIM").path
        m.folderName = "Shoot"
        m.startImport()
        XCTAssertTrue(m.alertMessage?.contains("on the card") == true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: card.appendingPathComponent("DCIM/Shoot").path))
    }

    func testExistingFolderCopiesOnlyWhatIsMissingAndChangesNothingThere() async throws {
        try makeCard()
        let shoot = out.appendingPathComponent("Shoot")
        try FileManager.default.createDirectory(at: shoot, withIntermediateDirectories: true)
        // Already there: the first pair and the -2 RAW. A different photo uses the name C0001.MP4.
        try FileManager.default.copyItem(at: card.appendingPathComponent("DCIM/100MSDCF/DSC00001.ARW"), to: shoot.appendingPathComponent("DSC00001.ARW"))
        try FileManager.default.copyItem(at: card.appendingPathComponent("DCIM/100MSDCF/DSC00001.JPG"), to: shoot.appendingPathComponent("dsc00001.jpg"))
        try FileManager.default.copyItem(at: card.appendingPathComponent("DCIM/101MSDCF/DSC00001.ARW"), to: shoot.appendingPathComponent("DSC00001-2.ARW"))
        try makeFile("C0001.MP4", size: 123, in: shoot)
        try Data("old checksums".utf8).write(to: shoot.appendingPathComponent("checksums.sha256"))
        try makeFile("notes.txt", size: 10, in: shoot)
        let before = try snapshot(shoot)

        let m = try await readyModel()
        m.destinationMode = .existingFolder
        try await searched(m)
        XCTAssertEqual(m.existingFolderError, "Choose a folder")
        XCTAssertFalse(m.canImport)
        m.existingFolderPath = shoot.path
        m.destinationMode = .newFolder; m.destinationMode = .existingFolder     // re-plan with the folder chosen
        try await searched(m)
        XCTAssertNil(m.existingFolderError)
        XCTAssertEqual(m.alreadyThere.count, 3)
        XCTAssertEqual(m.filesToCopyCount, 2)
        XCTAssertEqual(m.statuses.values.filter { $0 == .notChecked }.count, 3, "grey 'seems to be there' until checked")
        XCTAssertEqual(m.statuses.values.filter { $0 == .alreadyThere }.count, 0, "nothing is green before its checksum is compared")
        XCTAssertEqual(m.existingFolderDisplayName, "Shoot")

        m.startImport()
        try await wait(m, for: .done)
        XCTAssertTrue(m.allVerified)
        XCTAssertEqual(m.verifiedCount, 2)
        XCTAssertEqual(m.alreadyThereCount, 3)
        XCTAssertTrue(m.extraDestFiles.isEmpty, "other files in an existing folder aren't 'unexpected'")
        XCTAssertNotEqual(m.manifestFileName, "checksums.sha256")

        let after = try snapshot(shoot)
        for (name, hash) in before { XCTAssertEqual(after[name], hash, "\(name) must be unchanged") }
        XCTAssertEqual(Set(after.keys).subtracting(before.keys),
                       ["DSC00001-2.JPG", "C0001-2.MP4", m.manifestFileName])
    }

    func testExistingFolderErrorsAndNothingNewToImport() async throws {
        try makeCard()
        let m = try await readyModel()
        m.existingFolderPath = tmp.appendingPathComponent("gone").path
        m.destinationMode = .existingFolder
        try await searched(m)
        XCTAssertEqual(m.existingFolderError, "That folder isn't there anymore")
        m.existingFolderPath = card.appendingPathComponent("DCIM").path
        XCTAssertEqual(m.existingFolderError, "That folder is on the card")
        XCTAssertFalse(m.canImport)

        // A folder that already has the whole card.
        let full = out.appendingPathComponent("Full")
        try FileManager.default.createDirectory(at: full, withIntermediateDirectories: true)
        for f in m.cardFiles { try FileManager.default.copyItem(at: f.url, to: full.appendingPathComponent(f.destName)) }
        m.existingFolderPath = full.path
        m.destinationMode = .newFolder; m.destinationMode = .existingFolder
        try await searched(m)
        XCTAssertEqual(m.filesToCopyCount, 0)
        XCTAssertTrue(m.canImport, "importing still confirms the matches by checksum")
        m.startImport()
        try await wait(m, for: .done)
        XCTAssertTrue(m.allVerified)
        XCTAssertEqual(m.verifiedCount, 0)
        XCTAssertEqual(m.alreadyThereCount, 5)
    }

    /// marlowe #2: Sony RAWs are all the same size, so the same name and size can still be a different photo.
    func testSameNameAndSizeButDifferentPhotoIsCopiedWithANewName() async throws {
        try makeCard()
        let shoot = out.appendingPathComponent("Shoot")
        let other = try makeFile("DSC00001.ARW", size: 5000, in: shoot)     // same name and size, different bytes
        let theirs = try Data(contentsOf: other)
        let m = try await readyModel()
        m.existingFolderPath = shoot.path
        m.destinationMode = .existingFolder
        try await searched(m)
        let card = try XCTUnwrap(m.cardFiles.first { $0.relativePath == "DCIM/100MSDCF/DSC00001.ARW" })
        XCTAssertNotNil(m.alreadyThere[card.id], "by name and size alone it looks the same")

        m.startImport()
        try await wait(m, for: .done)
        XCTAssertTrue(m.allVerified, "\(m.statuses)")
        XCTAssertEqual(m.alreadyThereCount, 0, "the checksum shows it's a different photo")
        let copied = try XCTUnwrap(m.destFiles[card.id])
        XCTAssertNotEqual(copied.name, "DSC00001.ARW")
        XCTAssertEqual(try Data(contentsOf: copied.url), try Data(contentsOf: card.url), "the card's photo was copied")
        XCTAssertEqual(try Data(contentsOf: other), theirs, "the folder's own photo is untouched")
    }

    func testMatchInASubfolderIsConfirmedAndNotCopied() async throws {
        try makeCard()
        let shoot = out.appendingPathComponent("Shoot")
        let sub = shoot.appendingPathComponent("2024/Day 1")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: card.appendingPathComponent("PRIVATE/M4ROOT/CLIP/C0001.MP4"), to: sub.appendingPathComponent("C0001.MP4"))
        let m = try await readyModel()
        m.existingFolderPath = shoot.path
        m.destinationMode = .existingFolder
        try await searched(m)
        let clip = try XCTUnwrap(m.cardFiles.first { $0.name == "C0001.MP4" })
        XCTAssertEqual(clip.destName, "2024/Day 1/C0001.MP4")
        m.startImport()
        try await wait(m, for: .done)
        XCTAssertTrue(m.allVerified, "\(m.statuses)")
        XCTAssertEqual(m.statuses[clip.id], .alreadyThere)
        XCTAssertEqual(m.destFiles[clip.id]?.url.standardizedFileURL, sub.appendingPathComponent("C0001.MP4").standardizedFileURL)
        XCTAssertFalse(try names(in: shoot).contains("C0001.MP4"), "not copied again into the top folder")
    }

    func testSameNameInASubfolderWithDifferentBytesIsCopiedToTheTopFolder() async throws {
        try makeCard()
        let shoot = out.appendingPathComponent("Shoot")
        let other = try makeFile("old/C0001.MP4", size: 9000, in: shoot)        // same name and size, other clip
        let theirs = try Data(contentsOf: other)
        let m = try await readyModel()
        m.existingFolderPath = shoot.path
        m.destinationMode = .existingFolder
        try await searched(m)
        let clip = try XCTUnwrap(m.cardFiles.first { $0.name == "C0001.MP4" })
        XCTAssertNotNil(m.alreadyThere[clip.id])
        m.startImport()
        try await wait(m, for: .done)
        XCTAssertTrue(m.allVerified, "\(m.statuses)")
        XCTAssertNotEqual(m.statuses[clip.id], .alreadyThere)
        let copy = shoot.appendingPathComponent("C0001.MP4")
        XCTAssertEqual(try Data(contentsOf: copy), try Data(contentsOf: clip.url), "copied into the top folder, its own name free there")
        XCTAssertEqual(try Data(contentsOf: other), theirs, "the subfolder's clip is untouched")
    }

    func testASecondCandidateMatchesWhenTheFirstDiffers() async throws {
        try makeCard()
        let shoot = out.appendingPathComponent("Shoot")
        try makeFile("a/C0001.MP4", size: 9000, in: shoot)                   // looks the same, isn't
        try FileManager.default.createDirectory(at: shoot.appendingPathComponent("b"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: card.appendingPathComponent("PRIVATE/M4ROOT/CLIP/C0001.MP4"),
                                         to: shoot.appendingPathComponent("b/C0001.MP4"))
        let m = try await readyModel()
        m.existingFolderPath = shoot.path
        m.destinationMode = .existingFolder
        try await searched(m)
        m.startImport()
        try await wait(m, for: .done)
        let clip = try XCTUnwrap(m.cardFiles.first { $0.name == "C0001.MP4" })
        XCTAssertEqual(m.statuses[clip.id], .alreadyThere)
        XCTAssertEqual(m.destFiles[clip.id]?.url.lastPathComponent, "C0001.MP4")
        XCTAssertTrue(m.destFiles[clip.id]?.url.path.hasSuffix("/b/C0001.MP4") == true)
        XCTAssertFalse(try names(in: shoot).contains("C0001.MP4"))
    }

    func testEachFolderFileStandsInForOnlyOneCardFile() async throws {
        // Two card files with identical contents (a duplicate), one copy somewhere in the folder.
        let dup = try makeFile("CARD/DCIM/100MSDCF/DSC5.JPG", size: 300, modified: day(1))
        try FileManager.default.createDirectory(at: card.appendingPathComponent("DCIM/101MSDCF"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: dup, to: card.appendingPathComponent("DCIM/101MSDCF/DSC5.JPG"))
        let shoot = out.appendingPathComponent("Shoot")
        try FileManager.default.createDirectory(at: shoot.appendingPathComponent("x"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: dup, to: shoot.appendingPathComponent("x/DSC5.JPG"))
        let m = try await readyModel()
        m.existingFolderPath = shoot.path
        m.destinationMode = .existingFolder
        try await searched(m)
        m.startImport()
        try await wait(m, for: .done)
        XCTAssertTrue(m.allVerified)
        XCTAssertEqual(m.alreadyThereCount, 1)
        XCTAssertEqual(m.verifiedCount, 1, "the second card file is copied, not matched to the same folder file")
    }

    /// marlowe #5: a card inside the chosen folder would match itself, and nothing would be copied.
    func testRefusesAFolderThatContainsTheCard() async throws {
        try makeCard()
        let m = try await readyModel()
        for folder in [tmp.path, tmp.path.uppercased(), card.path, card.path.lowercased()] {
            m.existingFolderPath = folder
            m.destinationMode = .newFolder; m.destinationMode = .existingFolder
            try await searched(m)
            XCTAssertEqual(m.existingFolderError, folder.lowercased() == card.path.lowercased() ? "That folder is on the card"
                           : "The card is inside that folder. Choose a folder outside the card.", folder)
            XCTAssertFalse(m.canImport, folder)
            XCTAssertTrue(m.alreadyThere.isEmpty, "nothing was matched against the card itself")
        }
        // A folder next to the card is fine.
        let beside = out.appendingPathComponent("Beside")
        try FileManager.default.createDirectory(at: beside, withIntermediateDirectories: true)
        m.existingFolderPath = beside.path
        m.destinationMode = .newFolder; m.destinationMode = .existingFolder
        try await searched(m)
        XCTAssertNil(m.existingFolderError)
    }

    func testFolderIsSearchedInTheBackgroundAndImportWaitsForIt() async throws {
        try makeCard()
        let shoot = out.appendingPathComponent("Shoot")
        for i in 0..<2000 { try makeFile("many/\(i % 40)/F\(i).JPG", size: 10, in: shoot) }
        let m = try await readyModel()
        m.existingFolderPath = shoot.path
        m.destinationMode = .existingFolder
        XCTAssertTrue(m.searchingFolder, "choosing the folder returns at once; the search runs in the background")
        XCTAssertFalse(m.canImport, "no import until the search is done")
        try await searched(m)
        XCTAssertTrue(m.canImport)
        m.startImport()
        try await wait(m, for: .done)
        XCTAssertTrue(m.allVerified)
        XCTAssertEqual(m.verifiedCount, 5)
    }

    /// marlowe #7: namesakes (same name and size, different photo) are ruled out by their first megabyte,
    /// without hashing them in full.
    func testNamesakesAreRuledOutWithoutFullHashes() async throws {
        try makeCard()
        let shoot = out.appendingPathComponent("Shoot")
        for year in 2010..<2025 { try makeFile("\(year)/C0001.MP4", size: 9000, in: shoot) }   // 15 namesakes
        let m = try await readyModel()
        let fullHashes = Counter()
        m.hasher = { url, cancel, progress in
            fullHashes.add(url.lastPathComponent)
            return try Importer.hashFile(url, cancel: cancel, progress: progress)
        }
        m.existingFolderPath = shoot.path
        m.destinationMode = .existingFolder
        try await searched(m)
        let clip = try XCTUnwrap(m.cardFiles.first { $0.name == "C0001.MP4" })
        XCTAssertEqual(m.alreadyThere[clip.id] != nil, true)
        m.startImport()
        try await wait(m, for: .done)
        XCTAssertTrue(m.allVerified)
        XCTAssertEqual(fullHashes.count, 0, "no namesake shares the first megabyte, so nothing is hashed in full")
        XCTAssertNotEqual(m.statuses[clip.id], .alreadyThere)
        XCTAssertTrue(try names(in: shoot).contains("C0001.MP4"), "the clip is copied into the top folder")
        XCTAssertEqual(m.bytesDone, m.bytesTotal, "progress reaches the end with the cheaper comparison")
    }

    // MARK: Never overwrite (marlowe #8)

    /// A copier that, partway through copying `name`, has someone else's file appear at the target.
    private func copierWithIntruder(on name: String, contents: String) -> AppModel.Copier {
        { from, to, size, modified, mayReplace, cancel, progress in
            var appeared = false
            return try Importer.copyAndVerify(from: from, to: to, expectedSize: size, modified: modified,
                                              mayReplace: mayReplace, cancel: cancel) { n in
                if from.lastPathComponent == name, !appeared {
                    appeared = true
                    try? Data(contents.utf8).write(to: to)
                }
                progress(n)
            }
        }
    }

    func testAFileAppearingMidImportUnderTheChosenNameSurvives() async throws {
        try makeCard()
        let m = try await readyModel()
        m.copier = copierWithIntruder(on: "C0001.MP4", contents: "another shooter's clip")
        m.folderName = "Shoot"
        m.startImport()
        try await wait(m, for: .done)
        let theirs = out.appendingPathComponent("Shoot/C0001.MP4")
        XCTAssertEqual(try String(contentsOf: theirs, encoding: .utf8), "another shooter's clip", "never overwritten")
        XCTAssertFalse(m.allVerified)
        XCTAssertEqual(m.problemCount, 1, "it fails visibly instead")
        XCTAssertEqual(m.verifiedCount, 4)
    }

    func testAFileAppearingMidImportInAnExistingFolderSurvives() async throws {
        try makeCard()
        let shoot = out.appendingPathComponent("Shoot")
        try FileManager.default.createDirectory(at: shoot, withIntermediateDirectories: true)
        let m = try await readyModel()
        m.copier = copierWithIntruder(on: "C0001.MP4", contents: "synced in")
        m.existingFolderPath = shoot.path
        m.destinationMode = .existingFolder
        try await searched(m)
        m.startImport()
        try await wait(m, for: .done)
        XCTAssertEqual(try String(contentsOf: shoot.appendingPathComponent("C0001.MP4"), encoding: .utf8), "synced in")
        XCTAssertEqual(m.problemCount, 1)
    }

    func testRetryReplacesOnlyItsOwnBadCopy() async throws {
        try makeCard()
        let m = try await readyModel()
        let real = m.copier
        // First attempt: the JPG copy comes out corrupt (reported by the verify step).
        m.copier = { from, to, size, modified, mayReplace, cancel, progress in
            let r = try real(from, to, size, modified, mayReplace, cancel, progress)
            if from.path.hasSuffix("100MSDCF/DSC00001.JPG") {
                try Data("garbage".utf8).write(to: to)
                return .init(sourceHash: r.sourceHash, sourceRereadHash: r.sourceHash, destHash: "garbage")
            }
            return r
        }
        m.folderName = "Shoot"
        m.startImport()
        try await wait(m, for: .done)
        XCTAssertEqual(m.problemCount, 1)
        let target = out.appendingPathComponent("Shoot/DSC00001.JPG")
        m.copier = real
        m.retryFailed()
        try await wait(m, for: .done)
        XCTAssertTrue(m.allVerified, "its own bad copy may be replaced")
        let jpg = try XCTUnwrap(m.cardFiles.first { $0.relativePath == "DCIM/100MSDCF/DSC00001.JPG" })
        XCTAssertEqual(try Data(contentsOf: target), try Data(contentsOf: jpg.url))
    }

    func testRetryNeverReplacesAFileSomeoneElsePutThere() async throws {
        try makeCard()
        let m = try await readyModel()
        let real = m.copier
        m.copier = { from, to, size, modified, mayReplace, cancel, progress in
            let r = try real(from, to, size, modified, mayReplace, cancel, progress)
            return from.path.hasSuffix("100MSDCF/DSC00001.JPG")
                ? .init(sourceHash: r.sourceHash, sourceRereadHash: r.sourceHash, destHash: "bad") : r
        }
        m.folderName = "Shoot"
        m.startImport()
        try await wait(m, for: .done)
        // Someone replaces the bad copy with their own file before the retry.
        let target = out.appendingPathComponent("Shoot/DSC00001.JPG")
        try FileManager.default.removeItem(at: target)
        try Data("someone else's".utf8).write(to: target)
        m.copier = real
        m.retryFailed()
        try await wait(m, for: .done)
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "someone else's", "a different file is never replaced")
        XCTAssertFalse(m.allVerified)
    }

    // MARK: Symlinked folder (#9) and a stuck search (#10)

    func testAFolderChosenThroughASymlinkIsTheRealFolder() async throws {
        try makeCard()
        let shoot = out.appendingPathComponent("Shoot")
        try FileManager.default.createDirectory(at: shoot.appendingPathComponent("old"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: card.appendingPathComponent("PRIVATE/M4ROOT/CLIP/C0001.MP4"),
                                         to: shoot.appendingPathComponent("old/C0001.MP4"))
        let link = tmp.appendingPathComponent("Link to Shoot")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: shoot)
        let m = try await readyModel()
        m.existingFolderPath = link.path
        m.destinationMode = .existingFolder
        try await searched(m)
        XCTAssertEqual(m.alreadyThere.count, 1, "the real folder is searched")
        m.startImport()
        try await wait(m, for: .done)
        XCTAssertTrue(m.allVerified, "new copies aren't reported missing: \(m.statuses)")
        XCTAssertEqual(m.verifiedCount, 4)
    }

    func testAFailedCardScanDoesNotLeaveTheSearchSpinning() async throws {
        try makeCard()
        let shoot = out.appendingPathComponent("Shoot")
        for i in 0..<3000 { try makeFile("many/F\(i).JPG", size: 1, in: shoot) }
        let m = try await readyModel()
        m.existingFolderPath = shoot.path
        m.destinationMode = .existingFolder
        XCTAssertTrue(m.searchingFolder)
        m.sourcePath = tmp.appendingPathComponent("unplugged").path
        m.scanSource()
        let deadline = Date().addingTimeInterval(10)
        while m.scanError == nil && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNotNil(m.scanError)
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertFalse(m.searchingFolder, "the spinner stops once the card can't be read")
    }

    func testAComparisonThatFailsCanBeRetried() async throws {
        try makeCard()
        let shoot = out.appendingPathComponent("Shoot")
        try FileManager.default.createDirectory(at: shoot, withIntermediateDirectories: true)
        let cardClip = card.appendingPathComponent("PRIVATE/M4ROOT/CLIP/C0001.MP4")
        try FileManager.default.copyItem(at: cardClip, to: shoot.appendingPathComponent("C0001.MP4"))
        let m = try await readyModel()
        m.existingFolderPath = shoot.path
        m.destinationMode = .existingFolder
        try await searched(m)
        try shell("/bin/chmod", ["000", cardClip.path])
        m.startImport()
        try await wait(m, for: .done)
        XCTAssertEqual(m.problemCount, 1)
        let clip = try XCTUnwrap(m.cardFiles.first { $0.name == "C0001.MP4" })
        guard case .failed(let reason) = m.statuses[clip.id] else { return XCTFail("\(String(describing: m.statuses[clip.id]))") }
        XCTAssertTrue(reason.contains("Couldn't compare"))
        try shell("/bin/chmod", ["644", cardClip.path])
        m.retryFailed()
        try await wait(m, for: .done)
        XCTAssertTrue(m.allVerified)
        XCTAssertEqual(m.statuses[clip.id], .alreadyThere, "compared again, not copied over the folder's file")
        XCTAssertEqual(try names(in: shoot).filter { $0.hasPrefix("C0001") }, ["C0001.MP4"])
    }

    /// marlowe #3c: what the user sees when the card or the copy gives different data.
    func testBadReadsAreReportedAsFailures() async throws {
        try makeCard()
        let m = try await readyModel()
        // Copies for real, then reports what a flaky card or a corrupted copy would produce.
        m.copier = { from, to, size, modified, mayReplace, cancel, progress in
            let r = try Importer.copyAndVerify(from: from, to: to, expectedSize: size, modified: modified,
                                               mayReplace: mayReplace, cancel: cancel, progress: progress)
            if from.path.hasSuffix("CLIP/C0001.MP4") {
                return .init(sourceHash: r.sourceHash, sourceRereadHash: "different", destHash: r.destHash)
            }
            if from.path.hasSuffix("100MSDCF/DSC00001.JPG") {
                return .init(sourceHash: r.sourceHash, sourceRereadHash: r.sourceHash, destHash: "corrupt")
            }
            return r
        }
        m.folderName = "Shoot"
        m.startImport()
        try await wait(m, for: .done)
        XCTAssertFalse(m.allVerified)
        XCTAssertEqual(m.problemCount, 2)
        let reasons = m.cardFiles.compactMap { f -> String? in
            if case .failed(let r) = m.statuses[f.id] { return "\(f.relativePath): \(r)" } else { return nil }
        }.sorted()
        XCTAssertEqual(reasons.count, 2)
        XCTAssertTrue(reasons.contains { $0.hasPrefix("DCIM/100MSDCF/DSC00001.JPG") && $0.contains("the copy differs from the card") }, "\(reasons)")
        XCTAssertTrue(reasons.contains { $0.hasPrefix("PRIVATE/M4ROOT/CLIP/C0001.MP4") && $0.contains("different data on two reads") }, "\(reasons)")
        let manifest = try String(contentsOf: out.appendingPathComponent("Shoot/checksums.sha256"), encoding: .utf8)
        XCTAssertFalse(manifest.contains("C0001.MP4"), "failed files never go in the checksums file")
        XCTAssertEqual(manifest.split(separator: "\n").count, 3)
    }

    func testSwitchingBackToNewFolderRestoresTheScannerNames() async throws {
        try makeCard()
        let m = try await readyModel()
        let scanned = m.cardFiles.map(\.destName)
        let shoot = out.appendingPathComponent("Shoot")
        try makeFile("DSC00001.ARW", size: 1, in: shoot)           // forces a different name in existing mode
        m.existingFolderPath = shoot.path
        m.destinationMode = .existingFolder
        try await searched(m)
        XCTAssertNotEqual(m.cardFiles.map(\.destName), scanned)
        m.destinationMode = .newFolder
        XCTAssertEqual(m.cardFiles.map(\.destName), scanned)
        XCTAssertTrue(m.alreadyThere.isEmpty)
    }

    func testFailedFileCanBeRetried() async throws {
        try makeCard()
        let m = try await readyModel()
        let unreadable = card.appendingPathComponent("PRIVATE/M4ROOT/CLIP/C0001.MP4")
        try shell("/bin/chmod", ["000", unreadable.path])
        m.folderName = "Shoot"
        m.startImport()
        try await wait(m, for: .done)
        XCTAssertFalse(m.allVerified)
        XCTAssertEqual(m.problemCount, 1)
        XCTAssertTrue(m.canRetry)
        try shell("/bin/chmod", ["644", unreadable.path])
        m.retryFailed()
        try await wait(m, for: .done)
        XCTAssertTrue(m.allVerified)
        XCTAssertEqual(m.runCount, 1, "the retry copies only the failed file")
    }

    func testCancelLeavesFilesMarkedNotCopied() async throws {
        try makeCard()
        let m = try await readyModel()
        m.folderName = "Shoot"
        m.startImport()
        m.cancelImport()
        try await wait(m, for: .done)
        XCTAssertTrue(m.wasCancelled)
        XCTAssertFalse(m.allVerified)
        XCTAssertEqual(m.problemCount, 0, "stopping isn't a failure")
        XCTAssertEqual(m.notCopiedCount, 5)
    }

    // MARK: Every state from Aiden's point of view (marlowe's UI audit)

    /// #23: stopping a normal import is calm and neutral, and Copy Remaining finishes it.
    func testStoppedImportIsNeutralAndCanBeFinished() async throws {
        try makeCard()
        let m = try await readyModel()
        m.hasher = { try Importer.hashFile($0, cancel: $1, progress: $2) }
        let real = m.copier
        m.copier = { from, to, size, modified, mayReplace, cancel, progress in
            Thread.sleep(forTimeInterval: 0.2)
            return try real(from, to, size, modified, mayReplace, cancel, progress)
        }
        m.folderName = "Shoot"
        m.startImport()
        while m.currentIndex < 3 { try await Task.sleep(for: .milliseconds(5)) }
        m.cancelImport()
        try await wait(m, for: .done)
        XCTAssertEqual(m.problemCount, 0)
        XCTAssertGreaterThan(m.notCopiedCount, 0)
        XCTAssertTrue(m.cardFiles.allSatisfy { !m.isProblem($0) }, "nothing red")
        XCTAssertEqual(m.resultTone, .stopped)
        XCTAssertEqual(m.resultTitle, "Import stopped")
        XCTAssertEqual(m.resultDetail, "\(m.verifiedCount) copied and verified. \(m.notCopiedCount) not copied yet. Keep the card until it's finished.")
        XCTAssertEqual(m.finishButtonTitle, "Copy Remaining \(m.notCopiedCount)")
        m.copier = real
        m.finishRemaining()
        try await wait(m, for: .done)
        XCTAssertTrue(m.allVerified)
        XCTAssertEqual(m.resultTitle, "All 5 files verified")
    }

    /// #28: the drive filling up is one clear line, the rest is "not copied yet", and it can be finished.
    func testDiskFullStopsWithOneClearMessage() async throws {
        try makeCard()
        let m = try await readyModel()
        let real = m.copier
        let calls = Counter()
        m.copier = { from, to, size, modified, mayReplace, cancel, progress in
            calls.add(from.lastPathComponent)
            if calls.count == 3 { throw CocoaError(.fileWriteOutOfSpace) }
            return try real(from, to, size, modified, mayReplace, cancel, progress)
        }
        m.folderName = "Shoot"
        m.startImport()
        try await wait(m, for: .done)
        XCTAssertEqual(calls.count, 3, "it stops trying once the drive is full")
        XCTAssertTrue(m.diskFull)
        XCTAssertEqual(m.problemCount, 0)
        XCTAssertEqual(m.notCopiedCount, 3)
        XCTAssertEqual(m.resultTone, .attention)
        XCTAssertEqual(m.resultTitle, "The destination drive is full")
        XCTAssertEqual(m.resultDetail, "2 copied and verified. 3 not copied yet. Free up space on the drive, then choose Copy Remaining 3.")
        m.copier = real
        m.finishRemaining()
        try await wait(m, for: .done)
        XCTAssertTrue(m.allVerified)
    }

    /// #18, #19: "already there" rows are never tinted red after a good run, and the words fit.
    func testAlreadyThereIsNeverAProblem() async throws {
        try makeCard()
        let shoot = out.appendingPathComponent("Shoot")
        try FileManager.default.createDirectory(at: shoot.appendingPathComponent("old"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: card.appendingPathComponent("PRIVATE/M4ROOT/CLIP/C0001.MP4"), to: shoot.appendingPathComponent("old/C0001.MP4"))
        let m = try await readyModel()
        try await chooseExisting(m, shoot)
        m.startImport()
        try await wait(m, for: .done)
        XCTAssertTrue(m.allVerified)
        XCTAssertTrue(m.cardFiles.allSatisfy { !m.isProblem($0) })
        XCTAssertEqual(m.resultTitle, "4 copied, 1 already there")
        XCTAssertTrue(m.resultDetail.hasPrefix("The 4 copies match two separate reads of the card; the 1 already there have the same checksum as the card."), m.resultDetail)
        let clip = try XCTUnwrap(m.cardFiles.first { $0.name == "C0001.MP4" })
        XCTAssertEqual(m.rowSubtitle(clip, try XCTUnwrap(m.destFiles[clip.id])), "already in the folder as old/C0001.MP4")
    }

    /// #22 (part 2): a stopped check never calls a subfolder candidate "Not in folder".
    func testStoppedSubfolderCandidateIsNotCheckedNotMissing() async throws {
        try makeCard()
        let shoot = out.appendingPathComponent("Shoot")
        for f in try CardScanner.scan(root: card).media {
            let sub = shoot.appendingPathComponent("year/\(f.destName)")
            try FileManager.default.createDirectory(at: sub.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: f.url, to: sub)
        }
        let m = try await readyModel()
        try await chooseExisting(m, shoot)
        m.hasher = slowHasher(0.3)
        m.startImport()
        while m.currentIndex < 2 { try await Task.sleep(for: .milliseconds(5)) }
        m.cancelImport()
        try await wait(m, for: .done)
        XCTAssertEqual(m.problemCount, 0)
        XCTAssertTrue(m.cardFiles.allSatisfy { m.statuses[$0.id] == .alreadyThere || m.statuses[$0.id] == .notChecked })
    }

    /// #33: a name taken mid-import gets a fresh name on Retry, and the other file is untouched.
    func testRetryAfterANameWasTakenUsesANewName() async throws {
        try makeCard()
        let m = try await readyModel()
        let real = m.copier
        m.copier = copierWithIntruder(on: "C0001.MP4", contents: "theirs")
        m.folderName = "Shoot"
        m.startImport()
        try await wait(m, for: .done)
        XCTAssertEqual(m.problemCount, 1)
        XCTAssertEqual(m.resultTitle, "1 file has a problem")
        m.copier = real
        m.retryFailed()
        try await wait(m, for: .done)
        XCTAssertTrue(m.allVerified)
        let shoot = out.appendingPathComponent("Shoot")
        XCTAssertEqual(try String(contentsOf: shoot.appendingPathComponent("C0001.MP4"), encoding: .utf8), "theirs")
        XCTAssertTrue(try names(in: shoot).contains("C0001-2.MP4"))
    }

    /// #30: a card removed after an unfinished run says to keep it, without calling it a failed import.
    func testCardRemovedAfterAStoppedRunSaysKeepTheCard() async throws {
        try makeCard()
        let m = try await readyModel()
        m.folderName = "Shoot"
        m.startImport()
        m.cancelImport()
        try await wait(m, for: .done)
        m.sourceEjected = true
        let unconfirmed = 5 - m.verifiedCount
        XCTAssertEqual(m.ejectedDetail, "Card removed. \(unconfirmed) \(unconfirmed == 1 ? "file wasn't" : "files weren't") confirmed, so keep the card.")
        XCTAssertFalse(m.canFinishRemaining, "finishing needs the card back")
    }

    /// marlowe v1.4 #3: never "0 files weren't confirmed, so keep the card".
    func testCardRemovedAfterEverythingWasConfirmed() async throws {
        try makeCard()
        let m = try await readyModel()
        m.folderName = "Shoot"
        m.startImport()
        try await wait(m, for: .done)
        XCTAssertTrue(m.allVerified)
        m.sourceEjected = true
        XCTAssertEqual(m.ejectedDetail, "Ejected · safe to remove")
        XCTAssertTrue(m.quitWarning.detail.contains("copied so far stay verified"), "the import quit warning doesn't overstate it")
    }

    /// #40: Eject waits when the independent check found missing files.
    func testEjectIsHeldBackByARedIndependentCheck() async throws {
        try makeCard()
        let m = try await readyModel()
        let script = tmp.appendingPathComponent("red.sh")
        try Data("echo 'MISSING: x'; exit 1\n".utf8).write(to: script)
        m.independentCheck = IndependentCheck(scriptURL: script)
        m.folderName = "Shoot"
        m.startImport()
        try await wait(m, for: .done)
        m.runIndependentCheckOnLastImport()
        while m.independentCheck.isRunning { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(m.independentCheck.state, .missing)
        m.ejectCard()
        XCTAssertTrue(m.alertMessage?.contains("independent check found files missing") == true)
        XCTAssertFalse(m.sourceEjected)
    }

    /// #7, #9, #10, #11: the words before a run, and nothing green before a checksum.
    func testWordsBeforeARun() async throws {
        try makeCard()
        let m = try await readyModel()
        m.destinationMode = .existingFolder
        XCTAssertTrue(m.existingFolderHint.contains("or its subfolders"))
        let empty = out.appendingPathComponent("Empty")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        try await chooseExisting(m, empty)
        XCTAssertEqual(m.existingFolderSummary, "None of the card's files are in this folder yet.")
        XCTAssertEqual(m.emptyPaneText.title, "Not Imported Yet")
        let some = out.appendingPathComponent("Some")
        try FileManager.default.createDirectory(at: some, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: card.appendingPathComponent("PRIVATE/M4ROOT/CLIP/C0001.MP4"), to: some.appendingPathComponent("C0001.MP4"))
        try await chooseExisting(m, some)
        XCTAssertEqual(m.existingFolderSummary, "4 new files to copy. 1 more seem to be in the folder already; they'll be confirmed by checksum.")
        XCTAssertFalse(m.statuses.values.contains(.alreadyThere), "no green before the checksum")
        let all = try folderWithEverything()
        try await chooseExisting(m, all)
        XCTAssertTrue(m.existingFolderSummary.hasPrefix("All 5 files seem to be in the folder (same name and size)."))
        XCTAssertEqual(m.emptyPaneText.title, "Not Checked Yet")
    }

    func testMissingSourceShowsAScanError() async throws {
        let m = AppModel()
        m.sourcePath = tmp.appendingPathComponent("no card").path
        m.scanSource()
        try await wait(m, for: .idle)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertNotNil(m.scanError)
        XCTAssertEqual(m.sourceDisplayName, "no card")
    }

    func testIndependentCheckWaitsForTheClickThenChecksTheLastImport() async throws {
        try makeCard()
        let m = try await readyModel()
        m.independentCheck = IndependentCheck(scriptURL: Bundle(for: AppModelTests.self).url(forResource: "verify-card", withExtension: "sh"))
        XCTAssertNil(m.lastImport)
        m.folderName = "Shoot"
        m.startImport()
        try await wait(m, for: .done)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(m.independentCheck.state, .idle, "nothing runs until Aiden clicks")
        let target = try XCTUnwrap(m.lastImport)
        XCTAssertEqual(target.card, card.path)
        XCTAssertEqual(target.folder, out.appendingPathComponent("Shoot").path)

        m.runIndependentCheckOnLastImport()
        XCTAssertTrue(m.independentCheck.isRunning)
        m.ejectCard()
        XCTAssertTrue(m.alertMessage?.contains("still reading the card") == true, "no eject while it reads the card")
        while m.independentCheck.isRunning { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(m.independentCheck.state, .passed, m.independentCheck.output)
        XCTAssertEqual(m.independentCheck.extraFiles.count, 1, "the clip's XML sidecar is listed, not failed")

        m.scanSource()                                   // a new card: the old result no longer applies
        XCTAssertEqual(m.independentCheck.state, .idle)
    }

    // MARK: Check-only wording (nothing new on the card)

    /// A folder that already has every card file, identical.
    private func folderWithEverything() throws -> URL {
        let shoot = out.appendingPathComponent("Shoot")
        try FileManager.default.createDirectory(at: shoot, withIntermediateDirectories: true)
        for f in try CardScanner.scan(root: card).media {
            try FileManager.default.copyItem(at: f.url, to: shoot.appendingPathComponent(f.destName))
        }
        return shoot
    }

    /// Hashes for real, slowly, so a test can look at the screen mid-run.
    private func slowHasher(_ delay: TimeInterval) -> @Sendable (URL, CancelToken, (Int64) -> Void) throws -> String {
        { url, cancel, progress in
            Thread.sleep(forTimeInterval: delay)
            return try Importer.hashFile(url, cancel: cancel, progress: progress)
        }
    }

    private func chooseExisting(_ m: AppModel, _ folder: URL) async throws {
        m.existingFolderPath = folder.path
        m.destinationMode = .newFolder; m.destinationMode = .existingFolder
        try await searched(m)
    }

    func testCheckOnlyNeverSaysImport() async throws {
        try makeCard()
        let shoot = try folderWithEverything()
        let before = try snapshot(shoot)
        let m = try await readyModel()
        try await chooseExisting(m, shoot)
        XCTAssertEqual(m.importButtonTitle, "Check 5 Files Are Identical")
        XCTAssertTrue(m.existingFolderSummary.contains("nothing is copied unless one differs"), m.existingFolderSummary)
        XCTAssertFalse(m.existingFolderSummary.contains("Import"))

        m.hasher = slowHasher(0.15)
        m.startImport()
        let deadline = Date().addingTimeInterval(10)
        while m.phase != .importing && Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(m.runSectionTitle, "Checking")
        XCTAssertEqual(m.cancelTitle, "Stop Checking")
        XCTAssertEqual(m.runHeadline, "Comparing… (only files that differ will be copied)")
        XCTAssertEqual(m.quitWarning.title, "A check is still running")
        try await wait(m, for: .done)

        XCTAssertEqual(m.resultTone, .good)
        XCTAssertEqual(m.resultTitle, "All 5 already in the folder, identical")
        XCTAssertTrue(m.resultDetail.hasPrefix("Nothing copied."), m.resultDetail)
        XCTAssertEqual(try snapshot(shoot), before, "a check writes nothing: no checksums file, no copies")
        XCTAssertFalse(m.manifestWritten)
    }

    func testStoppedCheckShowsNotCheckedNotFailures() async throws {
        try makeCard()
        let shoot = try folderWithEverything()
        let before = try snapshot(shoot)
        let m = try await readyModel()
        try await chooseExisting(m, shoot)
        m.hasher = slowHasher(0.3)
        m.startImport()
        while m.currentIndex < 2 { try await Task.sleep(for: .milliseconds(5)) }
        m.cancelImport()
        try await wait(m, for: .done)

        XCTAssertEqual(m.problemCount, 0, "files not compared are never failures")
        XCTAssertGreaterThan(m.notCheckedCount, 0)
        XCTAssertTrue(m.cardFiles.allSatisfy { !m.isProblem($0) }, "nothing red")
        XCTAssertEqual(m.resultTone, .stopped)
        let confirmed = m.alreadyThereCount
        XCTAssertEqual(m.resultTitle, "Stopped: \(confirmed) of 5 confirmed identical")
        XCTAssertEqual(m.resultDetail, "\(m.notCheckedCount) not checked. Nothing was copied. Keep the card until it's finished.")
        XCTAssertEqual(m.finishButtonTitle, "Finish Checking (\(m.notCheckedCount))")
        XCTAssertFalse(m.resultTitle.contains("mport") || m.resultDetail.contains("wipe"))
        XCTAssertEqual(try snapshot(shoot), before, "stopping leaves the folder exactly as it was")

        m.hasher = { try Importer.hashFile($0, cancel: $1, progress: $2) }
        XCTAssertTrue(m.canFinishRemaining)
        m.finishRemaining()
        try await wait(m, for: .done)
        XCTAssertEqual(m.resultTitle, "All 5 already in the folder, identical")
        XCTAssertEqual(try snapshot(shoot), before)
    }

    func testCopyingWordsOnlyWhenAFileReallyDiffers() async throws {
        try makeCard()
        let shoot = try folderWithEverything()
        try FileManager.default.removeItem(at: shoot.appendingPathComponent("C0001.MP4"))
        try makeFile("C0001.MP4", size: 9000, in: shoot)              // same name and size, different clip
        let m = try await readyModel()
        try await chooseExisting(m, shoot)
        XCTAssertEqual(m.importButtonTitle, "Check 5 Files Are Identical")
        m.startImport()
        try await wait(m, for: .done)
        XCTAssertEqual(m.differingCount, 1)
        XCTAssertEqual(m.resultTitle, "4 identical, 1 copied as new names")
        XCTAssertTrue(m.resultDetail.contains("copied alongside it"), m.resultDetail)
        XCTAssertTrue(m.manifestWritten, "something was copied, so its checksum is saved")
        XCTAssertTrue(try names(in: shoot).contains("C0001-2.MP4"))
    }

    func testImportWordingStaysForRealImports() async throws {
        try makeCard()
        let m = try await readyModel()
        XCTAssertEqual(m.importButtonTitle, "Import 5 Files")
        let shoot = out.appendingPathComponent("Shoot")
        try FileManager.default.createDirectory(at: shoot, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: card.appendingPathComponent("PRIVATE/M4ROOT/CLIP/C0001.MP4"), to: shoot.appendingPathComponent("C0001.MP4"))
        try await chooseExisting(m, shoot)
        XCTAssertEqual(m.importButtonTitle, "Import 4 New Files")
        m.startImport()
        try await wait(m, for: .done)
        XCTAssertFalse(m.runIsCheckOnly)
        XCTAssertEqual(m.runSectionTitle, "Importing")
        XCTAssertEqual(m.cancelTitle, "Cancel Import")
        XCTAssertEqual(m.resultTitle, "4 copied, 1 already there")
    }

    func testNounFollowsTheCard() async throws {
        try makeCard()
        let m = try await readyModel()
        let photos = m.cardFiles.filter { $0.kind == .photo }, videos = m.cardFiles.filter { $0.kind == .video }
        XCTAssertEqual(m.noun(for: photos, count: 2), "photos")
        XCTAssertEqual(m.noun(for: photos, count: 1), "photo")
        XCTAssertEqual(m.noun(for: videos, count: 3), "videos")
        XCTAssertEqual(m.noun(for: m.cardFiles, count: 5), "files")
    }

    private func snapshot(_ dir: URL) throws -> [String: String] {
        var r: [String: String] = [:]
        for n in try names(in: dir) { r[n] = try Data(contentsOf: dir.appendingPathComponent(n)).sha256Hex }
        return r
    }
}

/// Thread-safe call counter for fakes.
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func add(_ s: String) { lock.lock(); items.append(s); lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return items.count }
}
