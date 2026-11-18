import XCTest

final class ImporterTests: TempDirTestCase {
    private func copy(_ src: URL, to dst: URL, size: Int64? = nil, mayReplace: Bool = true,
                      cancel: CancelToken = CancelToken()) throws -> Importer.CopyResult {
        let actual = Int64((try FileManager.default.attributesOfItem(atPath: src.path)[.size] as! NSNumber).intValue)
        return try Importer.copyAndVerify(from: src, to: dst, expectedSize: size ?? actual, modified: day(3),
                                          mayReplace: mayReplace, cancel: cancel) { _ in }
    }

    func testCopyMatchesSourceAndAllThreeHashesAgree() throws {
        let src = try makeFile("card/DSC1.ARW", size: 3 * 1024 * 1024)
        let dst = tmp.appendingPathComponent("DSC1.ARW")
        let r = try copy(src, to: dst)
        XCTAssertTrue(r.allMatch)
        XCTAssertEqual(r.destHash, try Data(contentsOf: src).sha256Hex, "hash must be the real SHA-256 of the card file")
        XCTAssertEqual(try Data(contentsOf: dst), try Data(contentsOf: src))
    }

    func testCopyUsesMoreThanOneChunk() throws {
        // Bigger than the 8 MB chunk, so the loop runs more than once.
        let src = try makeFile("card/C0001.MP4", size: Importer.chunkSize + 12_345)
        let dst = tmp.appendingPathComponent("C0001.MP4")
        var progress: Int64 = 0
        let r = try Importer.copyAndVerify(from: src, to: dst, expectedSize: Int64(Importer.chunkSize + 12_345),
                                           modified: day(1), cancel: CancelToken()) { progress += $0 }
        XCTAssertTrue(r.allMatch)
        XCTAssertEqual(progress, Int64(Importer.chunkSize + 12_345) * 3, "progress covers copy, read-back and re-read")
    }

    func testCopySetsCreationAndModificationDateToTheCardDate() throws {
        let src = try makeFile("card/DSC1.JPG")
        let dst = tmp.appendingPathComponent("DSC1.JPG")
        _ = try copy(src, to: dst)
        let a = try FileManager.default.attributesOfItem(atPath: dst.path)
        XCTAssertEqual(a[.modificationDate] as? Date, day(3))
        XCTAssertEqual(a[.creationDate] as? Date, day(3))
    }

    func testSizeMismatchFailsAndLeavesNothingBehind() throws {
        let src = try makeFile("card/DSC1.JPG", size: 500)
        let dst = tmp.appendingPathComponent("out/DSC1.JPG")
        try FileManager.default.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
        XCTAssertThrowsError(try copy(src, to: dst, size: 501)) { error in
            guard case Importer.ImportError.sizeMismatch(501, 500) = error else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dst.deletingLastPathComponent().path), [],
                       "no copy and no .partial file may be left")
    }

    func testCancelStopsAndLeavesNothingBehind() throws {
        let src = try makeFile("card/DSC1.JPG")
        let out = tmp.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let token = CancelToken(); token.cancel()
        XCTAssertThrowsError(try copy(src, to: out.appendingPathComponent("DSC1.JPG"), cancel: token)) {
            XCTAssertTrue($0 is CancellationError)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: out.path), [])
    }

    func testNeverReplacesAnExistingFileWhenNotAllowed() throws {
        let src = try makeFile("card/DSC1.JPG")
        let existing = try makeFile("out/DSC1.JPG", size: 77)
        let before = try Data(contentsOf: existing)
        XCTAssertThrowsError(try copy(src, to: existing, mayReplace: false)) { error in
            guard case Importer.ImportError.nameTaken("DSC1.JPG") = error else { return XCTFail("\(error)") }
            XCTAssertTrue(error.localizedDescription.contains("left alone"))
        }
        XCTAssertEqual(try Data(contentsOf: existing), before, "the folder's own file must be untouched")
    }

    /// A file that appears in the folder while the copy runs is never replaced: the final move refuses.
    func testFileAppearingDuringTheCopyIsNotReplaced() throws {
        let src = try makeFile("card/DSC1.JPG", size: 50_000)
        let out = tmp.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let dst = out.appendingPathComponent("DSC1.JPG")
        var appeared = false
        XCTAssertThrowsError(try Importer.copyAndVerify(from: src, to: dst, expectedSize: 50_000, modified: day(1),
                                                        mayReplace: false, cancel: CancelToken()) { _ in
            if !appeared { appeared = true; try? Data("someone else's".utf8).write(to: dst) }
        })
        XCTAssertTrue(appeared)
        XCTAssertEqual(try String(contentsOf: dst, encoding: .utf8), "someone else's", "the other file is untouched")
        XCTAssertEqual(try names(in: out), ["DSC1.JPG"])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: out.path).filter { $0.hasSuffix(".partial") }, [],
                       "no .partial file is left behind")
    }

    func testRetryReplacesItsOwnBadCopyWhenAllowed() throws {
        let src = try makeFile("card/DSC1.JPG")
        let bad = try makeFile("out/DSC1.JPG", size: 10)
        let r = try copy(src, to: bad, mayReplace: true)
        XCTAssertTrue(r.allMatch)
        XCTAssertEqual(try Data(contentsOf: bad), try Data(contentsOf: src))
    }

    func testMissingSourceThrows() {
        XCTAssertThrowsError(try Importer.copyAndVerify(from: tmp.appendingPathComponent("nope.JPG"),
                                                        to: tmp.appendingPathComponent("out.JPG"), expectedSize: 1,
                                                        modified: day(0), cancel: CancelToken()) { _ in })
        XCTAssertFalse(FileManager.default.fileExists(atPath: tmp.appendingPathComponent("out.JPG").path))
    }

    func testUnwritableDestinationThrowsCannotCreate() throws {
        let src = try makeFile("card/DSC1.JPG")
        let out = tmp.appendingPathComponent("locked", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        try shell("/bin/chmod", ["555", out.path])
        XCTAssertThrowsError(try copy(src, to: out.appendingPathComponent("DSC1.JPG"))) { error in
            guard case Importer.ImportError.cannotCreate = error else { return XCTFail("\(error)") }
        }
    }

    func testHashFileKnownVector() throws {
        let f = tmp.appendingPathComponent("abc.txt")
        try Data("abc".utf8).write(to: f)
        XCTAssertEqual(try Importer.hashFile(f, cancel: CancelToken()) { _ in },
                       "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    func testManifestIsShasumCompatible() throws {
        let a = try makeFile("set/A.JPG"), b = try makeFile("set/B C.ARW")
        let dir = a.deletingLastPathComponent()
        let entries = try [a, b].map { ($0.lastPathComponent, try Importer.hashFile($0, cancel: CancelToken()) { _ in }) }
        try Importer.writeManifest(entries.map { (name: $0.0, hash: $0.1) }, to: dir)
        let check = Process()
        check.executableURL = URL(fileURLWithPath: "/usr/bin/shasum")
        check.arguments = ["-a", "256", "-c", Importer.manifestName]
        check.currentDirectoryURL = dir
        check.standardOutput = Pipe()
        try check.run(); check.waitUntilExit()
        XCTAssertEqual(check.terminationStatus, 0, "`shasum -a 256 -c checksums.sha256` must pass")
    }

    func testNewManifestNameNeverReusesAnExistingName() {
        XCTAssertEqual(Importer.newManifestName(taken: []), "checksums.sha256")
        let date = Date(timeIntervalSince1970: 0)
        let first = Importer.newManifestName(taken: ["checksums.sha256"], date: date)
        XCTAssertTrue(first.hasPrefix("checksums-") && first.hasSuffix(".sha256"))
        let second = Importer.newManifestName(taken: ["checksums.sha256", first.lowercased()], date: date)
        XCTAssertNotEqual(first, second)
        XCTAssertTrue(second.hasSuffix("-2.sha256"))
    }

    func testListDestinationSkipsHiddenFilesFoldersAndManifest() throws {
        try makeFile("d/DSC1.JPG", size: 10); try makeFile("d/.hidden", size: 1)
        try makeFile("d/\(Importer.manifestName)", size: 1); try makeFile("d/sub/X.JPG", size: 1)
        let listing = Importer.listDestination(tmp.appendingPathComponent("d"))
        XCTAssertEqual(Set(listing.keys), ["dsc1.jpg"])
        XCTAssertEqual(listing["dsc1.jpg"]?.size, 10)
    }

    func testDestFileReadsRealAttributes() throws {
        let f = try makeFile("x.JPG", size: 42, modified: day(5))
        let d = try XCTUnwrap(Importer.destFile(at: f))
        XCTAssertEqual(d.size, 42); XCTAssertEqual(d.modified, day(5)); XCTAssertEqual(d.name, "x.JPG")
        XCTAssertNil(Importer.destFile(at: tmp), "a folder isn't a file")
        XCTAssertNil(Importer.destFile(at: tmp.appendingPathComponent("missing")))
    }

    func testErrorMessagesAreReadable() {
        XCTAssertTrue(Importer.ImportError.cannotCreate("/x").localizedDescription.contains("/x"))
        XCTAssertTrue(Importer.ImportError.sizeMismatch(expected: 2, got: 1).localizedDescription.contains("card 2 bytes"))
    }
}
