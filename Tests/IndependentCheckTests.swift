import XCTest
import CryptoKit

/// The in-app independent check: the bundled script must be the reviewed one, byte for byte, and the
/// shown state must come from its exit code. These run the real script with /bin/bash on temp folders.
@MainActor
final class IndependentCheckTests: TempDirTestCase {
    /// tools/verify-card.sh in the repo (this file is Tests/IndependentCheckTests.swift).
    nonisolated static let repoScript = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("tools/verify-card.sh")

    var bundledScript: URL? { Bundle(for: IndependentCheckTests.self).url(forResource: "verify-card", withExtension: "sh") }

    private func wait(_ c: IndependentCheck) async throws {
        let deadline = Date().addingTimeInterval(60)
        while c.isRunning {
            if Date() > deadline { return XCTFail("check didn't finish") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    /// A small Sony-like card and a perfect import of its photos and videos.
    private func makeCardAndImport() throws -> (card: URL, folder: URL) {
        let card = tmp.appendingPathComponent("My Card"), folder = tmp.appendingPathComponent("My Import")
        for f in ["DCIM/100MSDCF/DSC00001.ARW", "DCIM/100MSDCF/DSC00001.JPG", "PRIVATE/M4ROOT/CLIP/C0001.MP4"] {
            let src = try makeFile(f, size: 4000, in: card)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: src, to: folder.appendingPathComponent(src.lastPathComponent))
        }
        try makeFile("PRIVATE/M4ROOT/CLIP/C0001M01.XML", size: 300, in: card)      // a Sony extra, never copied
        return (card, folder)
    }

    // MARK: The bundled script is the reviewed script

    func testBundledScriptIsByteForByteTheRepoScript() throws {
        let bundled = try XCTUnwrap(bundledScript, "verify-card.sh must be bundled")
        XCTAssertEqual(try Data(contentsOf: bundled), try Data(contentsOf: Self.repoScript),
                       "the bundled verify-card.sh must be identical to tools/verify-card.sh")
    }

    func testShownSHA256IsTheScriptsRealSHA256() throws {
        let c = IndependentCheck(scriptURL: bundledScript)
        XCTAssertEqual(c.scriptSHA256, try Data(contentsOf: Self.repoScript).sha256Hex)
        XCTAssertNil(IndependentCheck(scriptURL: nil).scriptSHA256)
    }

    // MARK: Exit code decides the state

    func testPerfectImportPassesAndListsExtrasWithoutFailing() async throws {
        let (card, folder) = try makeCardAndImport()
        let c = IndependentCheck(scriptURL: bundledScript)
        c.run(card: card.path, folder: folder.path)
        XCTAssertTrue(c.isRunning)
        try await wait(c)
        XCTAssertEqual(c.state, .passed)
        XCTAssertEqual(c.exitCode, 0)
        XCTAssertTrue(c.latestLine.hasPrefix("OK: "), c.output)
        XCTAssertTrue(c.missingFiles.isEmpty)
        XCTAssertEqual(c.extraFiles.map { ($0 as NSString).lastPathComponent }, ["C0001M01.XML"])
        XCTAssertTrue(c.output.contains("Fingerprinting the destination"), "the full output is kept")
    }

    func testMissingFileIsRedAndListed() async throws {
        let (card, folder) = try makeCardAndImport()
        try FileManager.default.removeItem(at: folder.appendingPathComponent("C0001.MP4"))
        let c = IndependentCheck(scriptURL: bundledScript)
        c.run(card: card.path, folder: folder.path)
        try await wait(c)
        XCTAssertEqual(c.state, .missing)
        XCTAssertEqual(c.exitCode, 1)
        XCTAssertEqual(c.missingFiles.count, 1, "the verdict line isn't counted as a missing file")
        XCTAssertTrue(c.missingFiles[0].hasSuffix("PRIVATE/M4ROOT/CLIP/C0001.MP4"))
        XCTAssertTrue(c.latestLine.hasPrefix("MISSING: 1 of"))
    }

    func testUsageProblemIsAnError() async throws {
        let (card, _) = try makeCardAndImport()
        let c = IndependentCheck(scriptURL: bundledScript)
        c.run(card: card.path, folder: card.path)          // same folder: the script refuses (exit 2)
        try await wait(c)
        XCTAssertEqual(c.state, .error)
        XCTAssertEqual(c.exitCode, 2)
        XCTAssertTrue(c.latestLine.contains("same folder"))
    }

    func testStateComesFromExitCodeNotText() async throws {
        // A stand-in script that prints "OK" but exits 1, and one that prints MISSING but exits 0.
        let liar = tmp.appendingPathComponent("liar.sh")
        try Data("echo 'OK: all 5 files are there'; exit 1\n".utf8).write(to: liar)
        let c = IndependentCheck(scriptURL: liar)
        c.run(card: tmp.path, folder: tmp.path)
        try await wait(c)
        XCTAssertEqual(c.state, .missing)
        try Data("echo 'MISSING: x'; exit 0\n".utf8).write(to: liar)
        let d = IndependentCheck(scriptURL: liar)
        d.run(card: tmp.path, folder: tmp.path)
        try await wait(d)
        XCTAssertEqual(d.state, .passed)
        try Data("exit 7\n".utf8).write(to: liar)
        let e = IndependentCheck(scriptURL: liar)
        e.run(card: tmp.path, folder: tmp.path)
        try await wait(e)
        XCTAssertEqual(e.state, .error, "any other exit code is an error")
    }

    func testStoppingNeverCountsAsPassed() async throws {
        let slow = tmp.appendingPathComponent("slow.sh")
        try Data("echo 'Checking the card…'; sleep 30; exit 0\n".utf8).write(to: slow)
        let c = IndependentCheck(scriptURL: slow)
        c.run(card: tmp.path, folder: tmp.path)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(c.latestLine, "Checking the card…", "progress shows while it runs")
        c.stop()
        try await wait(c)
        XCTAssertEqual(c.state, .error)
        XCTAssertTrue(c.problem?.contains("stopped") == true)
    }

    func testMissingScriptIsShown() {
        let c = IndependentCheck(scriptURL: nil)
        c.run(card: tmp.path, folder: tmp.path)
        XCTAssertEqual(c.state, .error)
        XCTAssertTrue(c.problem?.contains("missing") == true)
    }

    func testANewRunReplacesTheOldOneAndResetClears() async throws {
        let slow = tmp.appendingPathComponent("slow.sh")
        try Data("echo old; sleep 30\n".utf8).write(to: slow)
        let c = IndependentCheck(scriptURL: slow)
        c.run(card: tmp.path, folder: tmp.path)
        try await Task.sleep(for: .milliseconds(200))
        try Data("echo new; exit 0\n".utf8).write(to: slow)
        c.run(card: tmp.path, folder: tmp.path)
        try await wait(c)
        XCTAssertEqual(c.state, .passed)
        XCTAssertFalse(c.output.contains("old"), "output from the stopped run isn't mixed in")
        c.reset()
        XCTAssertEqual(c.state, .idle)
        XCTAssertEqual(c.output, "")
    }
}
