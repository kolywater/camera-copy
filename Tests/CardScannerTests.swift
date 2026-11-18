import XCTest

final class CardScannerTests: TempDirTestCase {
    var card: URL { tmp.appendingPathComponent("CARD") }

    func testFindsPhotosAndVideosSkipsOtherFilesAndClipThumbnails() throws {
        try makeFile("CARD/DCIM/100MSDCF/DSC1.ARW", modified: day(1))
        try makeFile("CARD/DCIM/100MSDCF/dsc1.jpg", modified: day(1))
        try makeFile("CARD/PRIVATE/M4ROOT/CLIP/C0001.MP4", modified: day(2))
        try makeFile("CARD/PRIVATE/M4ROOT/CLIP/C0001M01.XML")
        try makeFile("CARD/PRIVATE/M4ROOT/THMBNL/C0001T01.JPG")
        try makeFile("CARD/.hidden.JPG")
        let r = try CardScanner.scan(root: card)
        XCTAssertEqual(r.media.map(\.relativePath).sorted(),
                       ["DCIM/100MSDCF/DSC1.ARW", "DCIM/100MSDCF/dsc1.jpg", "PRIVATE/M4ROOT/CLIP/C0001.MP4"])
        XCTAssertEqual(r.media.first { $0.name == "C0001.MP4" }?.kind, .video)
        XCTAssertEqual(r.media.first { $0.name == "dsc1.jpg" }?.kind, .photo)
        XCTAssertTrue(r.skipped.contains("PRIVATE/M4ROOT/CLIP/C0001M01.XML"))
        XCTAssertTrue(r.skipped.contains { $0.hasPrefix("PRIVATE/M4ROOT/THMBNL/") }, "thumbnails are listed as skipped")
    }

    func testSortsByDateThenPath() throws {
        try makeFile("CARD/DCIM/B.JPG", modified: day(1))
        try makeFile("CARD/DCIM/A.JPG", modified: day(2))
        try makeFile("CARD/DCIM/C.JPG", modified: day(1))
        XCTAssertEqual(try CardScanner.scan(root: card).media.map(\.name), ["B.JPG", "C.JPG", "A.JPG"])
    }

    func testDuplicateNamesGetDashTwoAndRawJpegPairsStayTogether() throws {
        try makeFile("CARD/DCIM/100MSDCF/DSC00001.ARW", modified: day(1))
        try makeFile("CARD/DCIM/100MSDCF/DSC00001.JPG", modified: day(1))
        try makeFile("CARD/DCIM/101MSDCF/DSC00001.ARW", modified: day(2))
        try makeFile("CARD/DCIM/101MSDCF/DSC00001.JPG", modified: day(2))
        try makeFile("CARD/DCIM/102MSDCF/dsc00001.arw", modified: day(3))
        let names = Dictionary(uniqueKeysWithValues: try CardScanner.scan(root: card).media.map { ($0.relativePath, $0.destName) })
        XCTAssertEqual(names["DCIM/100MSDCF/DSC00001.ARW"], "DSC00001.ARW")
        XCTAssertEqual(names["DCIM/101MSDCF/DSC00001.ARW"], "DSC00001-2.ARW")
        XCTAssertEqual(names["DCIM/101MSDCF/DSC00001.JPG"], "DSC00001-2.JPG")
        XCTAssertEqual(names["DCIM/102MSDCF/dsc00001.arw"], "dsc00001-3.arw", "names clash regardless of case")
    }

    func testMissingCardThrowsNotFound() {
        XCTAssertThrowsError(try CardScanner.scan(root: card)) { error in
            guard case CardScanner.ScanError.notFound = error else { return XCTFail("\(error)") }
            XCTAssertTrue(error.localizedDescription.contains("plugged in"))
        }
    }

    func testUnreadableFolderStopsTheScan() throws {
        try makeFile("CARD/DCIM/100MSDCF/DSC1.ARW")
        try makeFile("CARD/PRIVATE/M4ROOT/CLIP/C0001.MP4")
        try shell("/bin/chmod", ["000", card.appendingPathComponent("PRIVATE/M4ROOT/CLIP").path])
        XCTAssertThrowsError(try CardScanner.scan(root: card)) { error in
            guard case CardScanner.ScanError.unreadable(let items) = error else { return XCTFail("\(error)") }
            XCTAssertTrue(items.first?.hasPrefix("CLIP") == true)
            XCTAssertTrue(error.localizedDescription.contains("Couldn't read part of the card"))
        }
    }

    func testUnreadableMessageShortensLongLists() {
        let msg = CardScanner.ScanError.unreadable((1...7).map { "f\($0)" }).localizedDescription
        XCTAssertTrue(msg.contains("(+2 more)"))
    }
}
