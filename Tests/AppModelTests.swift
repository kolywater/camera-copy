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
        XCTAssertEqual(m.existingFolderError, "Choose a folder")
        XCTAssertFalse(m.canImport)
        m.existingFolderPath = shoot.path
        m.destinationMode = .newFolder; m.destinationMode = .existingFolder     // re-plan with the folder chosen
        XCTAssertNil(m.existingFolderError)
        XCTAssertEqual(m.alreadyThere.count, 3)
        XCTAssertEqual(m.filesToCopyCount, 2)
        XCTAssertEqual(m.statuses.values.filter { $0 == .alreadyThere }.count, 3, "drives the grid checkmarks")
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

    func testAComparisonThatFailsCanBeRetried() async throws {
        try makeCard()
        let shoot = out.appendingPathComponent("Shoot")
        try FileManager.default.createDirectory(at: shoot, withIntermediateDirectories: true)
        let cardClip = card.appendingPathComponent("PRIVATE/M4ROOT/CLIP/C0001.MP4")
        try FileManager.default.copyItem(at: cardClip, to: shoot.appendingPathComponent("C0001.MP4"))
        let m = try await readyModel()
        m.existingFolderPath = shoot.path
        m.destinationMode = .existingFolder
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

    private func snapshot(_ dir: URL) throws -> [String: String] {
        var r: [String: String] = [:]
        for n in try names(in: dir) { r[n] = try Data(contentsOf: dir.appendingPathComponent(n)).sha256Hex }
        return r
    }
}
