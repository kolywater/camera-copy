import XCTest

final class ExistingFolderTests: TempDirTestCase {
    var card: URL { tmp.appendingPathComponent("CARD") }
    var dest: URL { tmp.appendingPathComponent("Shoot") }

    /// Card: two folders with a clashing RAW+JPEG pair, another pair, and a clip.
    private func makeCard() throws -> [CardFile] {
        try makeFile("CARD/DCIM/100MSDCF/DSC00001.ARW", size: 5000, modified: day(1))
        try makeFile("CARD/DCIM/100MSDCF/DSC00001.JPG", size: 1500, modified: day(1))
        try makeFile("CARD/DCIM/100MSDCF/DSC00002.ARW", size: 5100, modified: day(2))
        try makeFile("CARD/DCIM/100MSDCF/DSC00002.JPG", size: 1600, modified: day(2))
        try makeFile("CARD/DCIM/101MSDCF/DSC00001.ARW", size: 5200, modified: day(3))
        try makeFile("CARD/DCIM/101MSDCF/DSC00001.JPG", size: 1700, modified: day(3))
        try makeFile("CARD/DCIM/101MSDCF/DSC00003.ARW", size: 5300, modified: day(4))
        try makeFile("CARD/DCIM/101MSDCF/DSC00003.JPG", size: 1800, modified: day(4))
        try makeFile("CARD/PRIVATE/M4ROOT/CLIP/C0001.MP4", size: 9000, modified: day(5))
        return try CardScanner.scan(root: card).media
    }

    /// What a first import in new-folder mode puts in the folder.
    private func importAll(_ media: [CardFile]) throws {
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        for f in media {
            try FileManager.default.copyItem(at: f.url, to: dest.appendingPathComponent(f.destName))
        }
    }

    private func id(_ media: [CardFile], _ path: String) -> String { media.first { $0.relativePath.hasSuffix(path) }!.id }

    func testEmptyFolderCopiesEverythingWithTheScannerNames() throws {
        let media = try makeCard()
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        let plan = ExistingFolder.plan(media, listing: ExistingFolder.list(dest))
        XCTAssertTrue(plan.alreadyThere.isEmpty)
        for f in media { XCTAssertEqual(plan.destNames[f.id], f.destName, f.relativePath) }
    }

    func testReimportFindsEverythingIncludingTheDashTwoCopies() throws {
        let media = try makeCard()
        try importAll(media)
        let plan = ExistingFolder.plan(media, listing: ExistingFolder.list(dest))
        XCTAssertEqual(plan.alreadyThere.count, media.count)
        XCTAssertEqual(plan.alreadyThere[id(media, "101MSDCF/DSC00001.ARW")]?.name, "DSC00001-2.ARW")
        XCTAssertTrue(plan.destNames.isEmpty)
    }

    func testMatchIgnoresCaseButNeedsTheSameSize() throws {
        let media = try makeCard()
        try importAll(media)
        try FileManager.default.moveItem(at: dest.appendingPathComponent("DSC00002.ARW"), to: dest.appendingPathComponent("dsc00002.arw"))
        try FileManager.default.removeItem(at: dest.appendingPathComponent("C0001.MP4"))
        try makeFile("C0001.MP4", size: 8999, in: dest)          // same name, different size: a different clip
        let plan = ExistingFolder.plan(media, listing: ExistingFolder.list(dest))
        XCTAssertEqual(plan.alreadyThere[id(media, "DSC00002.ARW")]?.name, "dsc00002.arw")
        XCTAssertNil(plan.alreadyThere[id(media, "C0001.MP4")])
        XCTAssertEqual(plan.destNames[id(media, "C0001.MP4")], "C0001-2.MP4", "the folder's own C0001.MP4 is never reused")
    }

    func testMissingPartnerRejoinsItsPairsSuffix() throws {
        let media = try makeCard()
        try importAll(media)
        try FileManager.default.removeItem(at: dest.appendingPathComponent("DSC00001-2.JPG"))
        try FileManager.default.removeItem(at: dest.appendingPathComponent("DSC00002.JPG"))
        let plan = ExistingFolder.plan(media, listing: ExistingFolder.list(dest))
        XCTAssertEqual(plan.destNames[id(media, "101MSDCF/DSC00001.JPG")], "DSC00001-2.JPG", "joins DSC00001-2.ARW, not -3")
        XCTAssertEqual(plan.destNames[id(media, "100MSDCF/DSC00002.JPG")], "DSC00002.JPG")
        XCTAssertEqual(plan.destNames.count, 2)
    }

    func testPartnerSuffixTakenByAnotherFileFallsBackToAFreeName() throws {
        let media = try makeCard()
        try importAll(media)
        try FileManager.default.removeItem(at: dest.appendingPathComponent("DSC00003.JPG"))
        try makeFile("DSC00003.JPG", size: 999, in: dest)           // a different photo with that name
        let plan = ExistingFolder.plan(media, listing: ExistingFolder.list(dest))
        XCTAssertEqual(plan.destNames[id(media, "DSC00003.JPG")], "DSC00003-2.JPG")
    }

    func testNewNamesAvoidEveryTakenNameIncludingFoldersAndHiddenFiles() throws {
        let media = try makeCard()
        try FileManager.default.createDirectory(at: dest.appendingPathComponent("DSC00001.ARW"), withIntermediateDirectories: true)
        try makeFile(".C0001.MP4", in: dest)
        try makeFile("c0001.mp4", size: 1, in: dest)
        let listing = ExistingFolder.list(dest)
        XCTAssertNil(listing.files["dsc00001.arw"], "a folder isn't a file")
        XCTAssertNil(listing.files[".c0001.mp4"], "hidden files aren't matched")
        let plan = ExistingFolder.plan(media, listing: listing)
        for name in plan.destNames.values { XCTAssertFalse(listing.takenNames.contains(name.lowercased()), name) }
        XCTAssertEqual(plan.destNames[id(media, "100MSDCF/DSC00001.ARW")], "DSC00001-2.ARW")
        XCTAssertEqual(plan.destNames[id(media, "100MSDCF/DSC00001.JPG")], "DSC00001-2.JPG", "pair moves together")
    }

    func testEachFolderFileStandsInForOnlyOneCardFile() throws {
        // Two identical-looking card files (same name and size in different folders), one copy in the folder.
        try makeFile("CARD/DCIM/100MSDCF/DSC9.JPG", size: 100, modified: day(1))
        try makeFile("CARD/DCIM/101MSDCF/DSC9.JPG", size: 100, modified: day(2))
        let media = try CardScanner.scan(root: card).media
        try makeFile("DSC9.JPG", size: 100, in: dest)
        let plan = ExistingFolder.plan(media, listing: ExistingFolder.list(dest))
        XCTAssertEqual(plan.alreadyThere.count, 1)
        XCTAssertEqual(plan.destNames.values.first, "DSC9-2.JPG")
    }

    func testSuffixParsingIgnoresLookAlikes() throws {
        try makeFile("CARD/DCIM/X-1.JPG", size: 10, modified: day(1))
        try makeFile("CARD/DCIM/Y.JPG", size: 10, modified: day(2))
        let media = try CardScanner.scan(root: card).media
        // "X-1-1.JPG" isn't a scanner suffix (n must be 2+), "Y-x.JPG" has no number, "Y-02.JPG" is n = 2.
        try makeFile("X-1-1.JPG", size: 10, in: dest); try makeFile("Y-x.JPG", size: 10, in: dest)
        let plan = ExistingFolder.plan(media, listing: ExistingFolder.list(dest))
        XCTAssertTrue(plan.alreadyThere.isEmpty)
        try makeFile("Y-02.JPG", size: 10, in: dest)
        XCTAssertEqual(ExistingFolder.plan(media, listing: ExistingFolder.list(dest)).alreadyThere[id(media, "Y.JPG")]?.name, "Y-02.JPG")
    }

    func testFreeName() {
        XCTAssertEqual(ExistingFolder.freeName("DSC1.ARW", taken: []), "DSC1-2.ARW")
        XCTAssertEqual(ExistingFolder.freeName("DSC1.ARW", taken: ["dsc1-2.arw", "dsc1-3.arw"]), "DSC1-4.ARW")
    }

    func testSuffixedNameHelper() {
        XCTAssertEqual(ExistingFolder.suffixedName("A.JPG", 1), "A.JPG")
        XCTAssertEqual(ExistingFolder.suffixedName("A.JPG", 3), "A-3.JPG")
        XCTAssertEqual(ExistingFolder.suffixedName("README", 2), "README-2")
    }

    func testListingOfMissingFolderIsEmpty() {
        let l = ExistingFolder.list(tmp.appendingPathComponent("nope"))
        XCTAssertTrue(l.files.isEmpty && l.takenNames.isEmpty)
    }
}
