import XCTest

/// Updater tests. Network, signature checks, the swap helper and quitting are faked through
/// `Updater.Environment`; unzipping, quarantine and the helper script run for real in a temp folder.
@MainActor
final class UpdaterTests: TempDirTestCase {
    // Records what the updater asked the outside world to do.
    var helperScripts: [String] = []
    var quitCount = 0
    var downloads: [URL] = []

    nonisolated var appsDir: URL { tmp.appendingPathComponent("Applications") }
    nonisolated var runningApp: URL { appsDir.appendingPathComponent("CameraCopy.app") }
    let zipURL = URL(string: "https://example.invalid/CameraCopy-1.1.zip")!

    override func setUpWithError() throws {
        try super.setUpWithError()
        try FileManager.default.createDirectory(at: runningApp, withIntermediateDirectories: true)
    }

    // MARK: Fakes

    func releaseJSON(tag: String = "v1.1", assets: [String] = ["CameraCopy-1.1.zip"], body: String? = "Notes") -> Data {
        let a = assets.map { #"{"name":"\#($0)","browser_download_url":"https://example.invalid/\#($0)"}"# }
        let b = body.map { #","body":"\#($0)""# } ?? ""
        return Data(#"{"tag_name":"\#(tag)"\#(b),"assets":[\#(a.joined(separator: ","))]}"#.utf8)
    }

    func http(_ code: Int, _ url: URL = URL(string: "https://example.invalid")!) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: code, httpVersion: nil, headerFields: nil)!
    }

    /// A zip like the release asset: CameraCopy.app inside, optionally quarantined.
    func makeReleaseZip(appName: String = "CameraCopy.app", version: String = "1.1", quarantined: Bool = false) throws -> URL {
        let src = tmp.appendingPathComponent("build-\(UUID().uuidString)")
        let app = try makeFile("\(appName)/Contents/MacOS/CameraCopy", size: 100, in: src).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let plist: [String: Any] = ["CFBundleShortVersionString": version, "CFBundleIdentifier": "com.aiden.CameraCopy",
                                    "CFBundleExecutable": "CameraCopy", "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        if quarantined {
            try shell("/usr/bin/xattr", ["-w", "com.apple.quarantine", "0083;00000000;Safari;", app.appendingPathComponent("Contents/MacOS/CameraCopy").path])
        }
        let zip = tmp.appendingPathComponent("release-\(UUID().uuidString).zip")
        XCTAssertEqual(try shell("/usr/bin/ditto", ["-c", "-k", "--keepParent", app.path, zip.path]), 0)
        return zip
    }

    /// An environment where everything succeeds unless a test changes it.
    func makeEnv(zip: URL? = nil, newSigner: (team: String?, bundleID: String?)? = ("TEAM1", "com.aiden.CameraCopy"),
                 mySigner: (team: String?, bundleID: String?)? = ("TEAM1", "com.aiden.CameraCopy"),
                 developerID: Bool = true, json: Data? = nil) throws -> Updater.Environment {
        let zip = try zip ?? makeReleaseZip()
        let running = runningApp
        var env = Updater.Environment()
        env.fetch = { [unowned self] _ in (json ?? self.releaseJSON(), self.http(200)) }
        env.download = { [unowned self] url in
            self.downloads.append(url)
            let copy = self.tmp.appendingPathComponent("dl-\(UUID().uuidString).zip")
            try FileManager.default.copyItem(at: zip, to: copy)
            return (copy, self.http(200, url))
        }
        env.signingIdentity = { url, _ in url.standardizedFileURL == running.standardizedFileURL ? mySigner : newSigner }
        env.satisfies = { _, requirement in
            XCTAssertTrue(requirement.contains("anchor apple generic") && requirement.contains("\"TEAM1\""))
            return developerID
        }
        env.launchHelper = { [unowned self] in self.helperScripts.append($0) }
        env.quit = { [unowned self] in self.quitCount += 1 }
        env.tempDirectory = tmp
        return env
    }

    func makeUpdater(_ env: Updater.Environment, version: String = "1.0", app: URL? = nil) -> Updater {
        Updater(currentVersion: version, appURL: app ?? runningApp, env: env)
    }

    func failureMessage(_ u: Updater) -> String? {
        if case .failed(let m) = u.status { return m }
        return nil
    }

    // MARK: Versions and release parsing

    func testVersionCompare() {
        let c = { Updater.compare(Updater.parse($0), Updater.parse($1)) }
        XCTAssertEqual(c("v1.1", "1.0"), .orderedDescending)
        XCTAssertEqual(c("1.10", "1.9"), .orderedDescending, "numeric, not alphabetical")
        XCTAssertEqual(c("v1.0", "1"), .orderedSame)
        XCTAssertEqual(c("V2", "1.9.9"), .orderedDescending)
        XCTAssertEqual(c("1.0", "1.0.1"), .orderedAscending)
        XCTAssertEqual(Updater.parse(" v1.2.3 "), [1, 2, 3])
        XCTAssertEqual(Updater.parse("beta"), [])
    }

    func testParseReleasePicksTheZipAsset() throws {
        let r = try Updater.parseRelease(releaseJSON(assets: ["notes.txt", "CameraCopy-1.1.ZIP", "other.zip"]))
        XCTAssertEqual(r.version, "v1.1")
        XCTAssertEqual(r.notes, "Notes")
        XCTAssertEqual(r.downloadURL.lastPathComponent, "CameraCopy-1.1.ZIP")
        XCTAssertEqual(try Updater.parseRelease(releaseJSON(body: nil)).notes, "")
    }

    func testParseReleaseErrors() {
        XCTAssertThrowsError(try Updater.parseRelease(releaseJSON(assets: ["notes.txt"]))) {
            XCTAssertEqual($0.localizedDescription, Updater.UpdateError.noAsset.localizedDescription)
        }
        XCTAssertThrowsError(try Updater.parseRelease(Data("not json".utf8)))
    }

    // MARK: Checking

    func testCheckFindsNewerReleaseAndShowsTheAlert() async throws {
        let u = makeUpdater(try makeEnv())
        await u.check(userInitiated: false)
        XCTAssertEqual(u.available?.version, "v1.1")
        XCTAssertEqual(u.latest?.version, "v1.1")
        XCTAssertTrue(u.showUpdateAlert)
    }

    func testCheckWhenUpToDate() async throws {
        let u = makeUpdater(try makeEnv(), version: "1.1")
        await u.check(userInitiated: true)
        XCTAssertEqual(u.status, .upToDate)
        XCTAssertFalse(u.showUpdateAlert)
        u.clearResult()
        XCTAssertEqual(u.status, .idle)
        await u.check(userInitiated: false)
        XCTAssertEqual(u.status, .idle, "a background check stays quiet")
    }

    func testCheckFailureIsShownOnlyWhenTheUserAsked() async throws {
        var env = try makeEnv()
        env.fetch = { [unowned self] _ in (Data(), self.http(404)) }
        let u = makeUpdater(env)
        await u.check(userInitiated: false)
        XCTAssertEqual(u.status, .idle)
        await u.check(userInitiated: true)
        XCTAssertEqual(failureMessage(u), Updater.UpdateError.noRelease.localizedDescription)
        u.env.fetch = { _ in throw URLError(.notConnectedToInternet) }
        await u.check(userInitiated: true)
        XCTAssertNotNil(failureMessage(u))
        u.clearResult()
        XCTAssertEqual(u.status, .idle)
    }

    // MARK: The "Install and Relaunch" button

    /// The v1.0/v1.1 bug: clicking closed the alert, closing cleared the update, and install then did nothing.
    func testClickingInstallThenClosingTheAlertStillInstallsAndQuits() async throws {
        let u = makeUpdater(try makeEnv())
        await u.check(userInitiated: false)
        // What SwiftUI does on a click: run the button's action, then set isPresented to false.
        let task = u.installButtonClicked()
        u.showUpdateAlert = false
        u.clearResult()
        await task.value
        XCTAssertEqual(downloads, [zipURL], "the click must start the download")
        XCTAssertEqual(helperScripts.count, 1, "the swap helper must be started")
        XCTAssertEqual(quitCount, 1, "the app must quit so the helper can swap it")
        // The fake quit returns (a real quit wouldn't), so the "couldn't quit" message is expected here.
        XCTAssertEqual(failureMessage(u), Updater.UpdateError.quitRefused.localizedDescription)
        XCTAssertTrue(helperScripts[0].contains(Updater.shellQuote(runningApp.path)))
    }

    func testClickAfterAnEarlierLaterStillInstalls() async throws {
        let u = makeUpdater(try makeEnv())
        await u.check(userInitiated: false)
        u.showUpdateAlert = false           // "Later"
        await u.check(userInitiated: true)  // Check for Updates… again
        XCTAssertTrue(u.showUpdateAlert)
        await u.installButtonClicked().value
        XCTAssertEqual(quitCount, 1)
    }

    func testClickWithNoKnownReleaseSaysSo() async throws {
        let u = makeUpdater(try makeEnv())
        await u.installButtonClicked().value
        XCTAssertNotNil(failureMessage(u))
        XCTAssertTrue(helperScripts.isEmpty && quitCount == 0)
    }

    func testQuitRefusedIsShown() async throws {
        let u = makeUpdater(try makeEnv())
        await u.check(userInitiated: false)
        u.env.quit = {}                      // quitting was cancelled
        await u.installButtonClicked().value
        XCTAssertEqual(failureMessage(u), Updater.UpdateError.quitRefused.localizedDescription)
    }

    // MARK: Every failure shows a message, and nothing is swapped or quit

    private func assertInstallFails(_ env: Updater.Environment, app: URL? = nil, containing text: String,
                                    file: StaticString = #filePath, line: UInt = #line) async {
        let u = makeUpdater(env, app: app)
        await u.check(userInitiated: false)
        await u.installButtonClicked().value
        let msg = failureMessage(u)
        XCTAssertNotNil(msg, "expected a visible failure", file: file, line: line)
        XCTAssertTrue(text.isEmpty || msg?.contains(text) == true, "message was: \(msg ?? "nil")", file: file, line: line)
        XCTAssertTrue(helperScripts.isEmpty, "nothing may be swapped", file: file, line: line)
        XCTAssertEqual(quitCount, 0, "the app must not quit", file: file, line: line)
    }

    func testDownloadErrorIsShown() async throws {
        var env = try makeEnv()
        env.download = { _ in throw URLError(.timedOut) }
        await assertInstallFails(env, containing: "")
    }

    func testDownloadHTTPErrorIsShown() async throws {
        var env = try makeEnv()
        env.download = { [unowned self] url in (self.tmp.appendingPathComponent("x"), self.http(404, url)) }
        await assertInstallFails(env, containing: "download failed")
    }

    func testArchiveWithoutAnAppIsShown() async throws {
        await assertInstallFails(try makeEnv(zip: makeReleaseZip(appName: "Readme.txt")), containing: "didn't contain the app")
    }

    func testCorruptZipIsShown() async throws {
        let bad = tmp.appendingPathComponent("bad.zip")
        try Data("not a zip".utf8).write(to: bad)
        await assertInstallFails(try makeEnv(zip: bad), containing: "ditto")
    }

    func testBrokenSignatureIsRefused() async throws {
        await assertInstallFails(try makeEnv(newSigner: nil), containing: "missing or broken")
    }

    func testOtherTeamIsRefused() async throws {
        await assertInstallFails(try makeEnv(newSigner: ("OTHER", "com.aiden.CameraCopy")), containing: "Developer ID certificate")
    }

    func testOtherBundleIDIsRefused() async throws {
        await assertInstallFails(try makeEnv(newSigner: ("TEAM1", "com.example.Other")), containing: "Developer ID certificate")
    }

    /// Right team ID and bundle ID in the signature, but not an Apple-issued Developer ID certificate.
    func testClaimedTeamWithoutDeveloperIDCertificateIsRefused() async throws {
        await assertInstallFails(try makeEnv(developerID: false), containing: "Developer ID certificate")
    }

    func testMislabelledOrOlderBuildIsRefused() async throws {
        await assertInstallFails(try makeEnv(zip: makeReleaseZip(version: "1.0")), containing: "version 1.0, not v1.1")
        let u = makeUpdater(try makeEnv(), version: "1.2")             // a "newer" tag holding an older app
        XCTAssertThrowsError(try u.prepare(try makeReleaseZip(version: "1.1"), expectedVersion: "v1.1")) {
            XCTAssertTrue($0.localizedDescription.contains("version 1.1"))
        }
    }

    func testAppThatIsASymlinkIsRefused() async throws {
        let src = tmp.appendingPathComponent("evil")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: src.appendingPathComponent("CameraCopy.app").path,
                                                   withDestinationPath: "/System/Applications/Calculator.app")
        let zip = tmp.appendingPathComponent("evil.zip")
        XCTAssertEqual(try shell("/usr/bin/ditto", ["-c", "-k", src.path, zip.path]), 0)
        await assertInstallFails(try makeEnv(zip: zip), containing: "didn't contain the app")
    }

    func testUnsignedRunningAppIsRefused() async throws {
        await assertInstallFails(try makeEnv(mySigner: (nil, "com.aiden.CameraCopy")), containing: "Developer ID")
        await assertInstallFails(try makeEnv(mySigner: nil), containing: "Developer ID")
    }

    func testTranslocatedAppIsShown() async throws {
        let translocated = tmp.appendingPathComponent("AppTranslocation/ABC/d/CameraCopy.app")
        try FileManager.default.createDirectory(at: translocated, withIntermediateDirectories: true)
        await assertInstallFails(try makeEnv(), app: translocated, containing: "Applications folder")
    }

    func testReadOnlyLocationIsShown() async throws {
        try shell("/bin/chmod", ["555", appsDir.path])
        await assertInstallFails(try makeEnv(), containing: "can't replace itself")
    }

    func testHelperLaunchFailureIsShown() async throws {
        var env = try makeEnv()
        env.launchHelper = { _ in throw CocoaError(.executableNotLoadable) }
        await assertInstallFails(env, containing: "")
    }

    func testErrorMessagesAreAllWritten() {
        let all: [Updater.UpdateError] = [.noRelease, .noAsset, .downloadFailed, .badArchive, .commandFailed("x"),
                                          .untrusted("y"), .translocated, .notWritable("/z"), .quitRefused]
        for e in all { XCTAssertFalse(e.localizedDescription.isEmpty, "\(e)") }
    }

    // MARK: Quarantine

    func testPrepareRemovesQuarantineFromTheNewApp() async throws {
        let zip = try makeReleaseZip(quarantined: true)
        // Sanity: unzipping alone keeps the flag, so the test would catch a missing strip.
        let check = tmp.appendingPathComponent("check")
        try shell("/usr/bin/ditto", ["-x", "-k", zip.path, check.path])
        XCTAssertTrue(try quarantined(check.appendingPathComponent("CameraCopy.app")))

        let u = makeUpdater(try makeEnv(zip: zip))
        let newApp = try u.prepare(zip, expectedVersion: "v1.1")
        XCTAssertEqual(newApp.lastPathComponent, "CameraCopy.app")
        XCTAssertFalse(try quarantined(newApp))
        XCTAssertFalse(FileManager.default.fileExists(atPath: zip.path), "the download is cleaned up")
    }

    private func quarantined(_ app: URL) throws -> Bool {
        let p = Process(); let out = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/xattr"); p.arguments = ["-r", "-l", app.path]
        p.standardOutput = out
        try p.run(); p.waitUntilExit()
        return String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)!.contains("com.apple.quarantine")
    }

    // MARK: Real code signatures (the test bundle is signed with Aiden's team)

    func testRealSignerCheck() throws {
        let me = Bundle(for: UpdaterTests.self).bundleURL
        let mine = try XCTUnwrap(Updater.signingIdentity(of: me, checkValidity: true), "test bundle must be validly signed")
        XCTAssertNotNil(mine.team, "test bundle must be signed by a team")

        let u = Updater(currentVersion: "1.0", appURL: me)          // real Environment
        let copy = tmp.appendingPathComponent("Copy.xctest")
        try FileManager.default.copyItem(at: me, to: copy)
        XCTAssertThrowsError(try u.verifySameSigner(copy), "a development-signed build isn't a Developer ID release") {
            XCTAssertTrue($0.localizedDescription.contains("Developer ID certificate"))
        }

        // The forgery from marlowe's review: ad-hoc signed, but claiming Aiden's team and the same identifier.
        let forged = tmp.appendingPathComponent("Forged.xctest")
        try FileManager.default.copyItem(at: me, to: forged)
        XCTAssertEqual(try shell("/usr/bin/codesign", ["-f", "-s", "-", "--team-identifier", mine.team!,
                                                        "-i", mine.bundleID!, forged.path]), 0)
        let claimed = try XCTUnwrap(Updater.signingIdentity(of: forged, checkValidity: true))
        XCTAssertEqual(claimed.team, mine.team, "the forged signature really does claim the team")
        XCTAssertThrowsError(try u.verifySameSigner(forged)) {
            XCTAssertTrue($0.localizedDescription.contains("Developer ID certificate"))
        }

        let tampered = tmp.appendingPathComponent("Tampered.xctest")
        try FileManager.default.copyItem(at: me, to: tampered)
        try Data("x".utf8).write(to: tampered.appendingPathComponent("Contents/Resources-extra.txt"))
        XCTAssertThrowsError(try u.verifySameSigner(tampered)) { XCTAssertTrue($0.localizedDescription.contains("missing or broken")) }

        let adHoc = tmp.appendingPathComponent("AdHoc.xctest")
        try FileManager.default.copyItem(at: me, to: adHoc)
        XCTAssertEqual(try shell("/usr/bin/codesign", ["-f", "-s", "-", "--deep", adHoc.path]), 0)
        XCTAssertThrowsError(try u.verifySameSigner(adHoc)) { XCTAssertTrue($0.localizedDescription.contains("Developer ID certificate")) }

        let unsigned = tmp.appendingPathComponent("Unsigned.app")
        try FileManager.default.createDirectory(at: unsigned, withIntermediateDirectories: true)
        XCTAssertNil(Updater.signingIdentity(of: unsigned, checkValidity: true))
        XCTAssertThrowsError(try Updater(currentVersion: "1.0", appURL: unsigned).verifySameSigner(copy))
    }

    /// A copy signed with Aiden's real Developer ID certificate passes the Apple-anchored check.
    func testGenuineDeveloperIDBuildIsAccepted() throws {
        let me = Bundle(for: UpdaterTests.self).bundleURL
        let mine = try XCTUnwrap(Updater.signingIdentity(of: me))
        let signed = tmp.appendingPathComponent("DeveloperID.xctest")
        try FileManager.default.copyItem(at: me, to: signed)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        p.arguments = ["-f", "-s", "Developer ID Application: Aiden Elliott (\(mine.team!))", "--timestamp=none", signed.path]
        p.standardError = Pipe()
        try p.run(); p.waitUntilExit()
        try XCTSkipIf(p.terminationStatus != 0, "no Developer ID certificate in this keychain")
        XCTAssertTrue(Updater.satisfies(signed, requirement: Updater.developerIDRequirement(team: mine.team!, bundleID: mine.bundleID!)))
        XCTAssertNoThrow(try Updater(currentVersion: "1.0", appURL: me).verifySameSigner(signed))
    }

    // MARK: The swap helper, run for real with /bin/sh

    /// Runs the helper script against fake apps. `waitFor` is a process the helper must wait for.
    private func runHelper(current: URL, new: URL, waitFor pid: Int32) throws -> (status: Int32, relaunched: Bool, alerted: Bool) {
        let relaunched = tmp.appendingPathComponent("relaunched"), alerted = tmp.appendingPathComponent("alerted")
        var env = Updater.Environment()
        env.relaunchCommand = "/usr/bin/touch \(Updater.shellQuote(relaunched.path)); /usr/bin/true"
        env.failureAlertCommand = { message in
            "/usr/bin/printf '%s' \(Updater.shellQuote(message)) > \(Updater.shellQuote(alerted.path))"
        }
        let script = Updater(currentVersion: "1.0", appURL: current, env: env).helperScript(newApp: new, afterPID: pid)
        let status = try shell("/bin/sh", ["-c", script])
        let fm = FileManager.default
        return (status, fm.fileExists(atPath: relaunched.path), fm.fileExists(atPath: alerted.path))
    }

    private func makeApp(_ path: String, marker: String) throws -> URL {
        let app = tmp.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try Data(marker.utf8).write(to: app.appendingPathComponent("version"))
        return app
    }

    private func marker(_ app: URL) -> String? {
        (try? Data(contentsOf: app.appendingPathComponent("version"))).flatMap { String(data: $0, encoding: .utf8) }
    }

    func testHelperWaitsForQuitThenSwapsAndRelaunches() throws {
        let current = try makeApp("My Apps/Camera Copy's.app", marker: "old")   // spaces and an apostrophe
        let new = try makeApp("new/CameraCopy.app", marker: "new")
        let sleeper = try Process.run(URL(fileURLWithPath: "/bin/sleep"), arguments: ["1"])
        let start = Date()
        let r = try runHelper(current: current, new: new, waitFor: sleeper.processIdentifier)
        XCTAssertGreaterThan(Date().timeIntervalSince(start), 0.7, "it must wait for the app to quit first")
        XCTAssertEqual(r.status, 0)
        XCTAssertEqual(marker(current), "new")
        XCTAssertTrue(r.relaunched)
        XCTAssertFalse(r.alerted)
        XCTAssertEqual(try names(in: current.deletingLastPathComponent()), ["Camera Copy's.app"], "no .old copy left behind")
    }

    func testHelperRestoresTheOldAppIfTheNewOneCantMoveIn() throws {
        let current = try makeApp("Apps/CameraCopy.app", marker: "old")
        let r = try runHelper(current: current, new: tmp.appendingPathComponent("missing/CameraCopy.app"), waitFor: 999_999)
        XCTAssertEqual(marker(current), "old", "the old app is put back")
        XCTAssertTrue(r.alerted, "a failed swap shows an alert")
        XCTAssertTrue(try String(contentsOf: tmp.appendingPathComponent("alerted"), encoding: .utf8).contains("previous version was kept"))
        XCTAssertTrue(r.relaunched, "the old app is reopened")
        XCTAssertEqual(try names(in: current.deletingLastPathComponent()), ["CameraCopy.app"])
    }

    func testHelperStopsIfTheOldAppCantBeMoved() throws {
        let current = try makeApp("Locked/CameraCopy.app", marker: "old")
        let new = try makeApp("new/CameraCopy.app", marker: "new")
        try shell("/bin/chmod", ["555", current.deletingLastPathComponent().path])
        let r = try runHelper(current: current, new: new, waitFor: 999_999)
        XCTAssertEqual(r.status, 1)
        XCTAssertEqual(marker(current), "old")
        XCTAssertTrue(r.alerted)
        XCTAssertTrue(try String(contentsOf: tmp.appendingPathComponent("alerted"), encoding: .utf8).contains("Open Camera Copy again"))
        XCTAssertFalse(r.relaunched)
    }

    /// marlowe v1.3 #3/#4: run the "can't put the old app back" branch for real, in a folder whose
    /// name would run commands if any path were left unquoted.
    func testHelperNamesTheOldAppIfItCantBePutBackForReal() throws {
        let hostile = "Apps $(touch PWNED) `touch PWNED2` \"q\" 'a'"
        let current = try makeApp("\(hostile)/CameraCopy.app", marker: "old")
        // A stand-in mv that refuses any move onto the app's own path (both the swap-in and the restore).
        let fakeMove = tmp.appendingPathComponent("mv-fails-onto-app.sh")
        try Data("#!/bin/sh\ncase \"$2\" in */CameraCopy.app) exit 1;; esac\nexec /bin/mv \"$@\"\n".utf8).write(to: fakeMove)
        try shell("/bin/chmod", ["755", fakeMove.path])
        let alerted = tmp.appendingPathComponent("alerted"), relaunched = tmp.appendingPathComponent("relaunched")
        var env = Updater.Environment()
        env.moveCommand = fakeMove.path
        env.relaunchCommand = "/usr/bin/touch \(Updater.shellQuote(relaunched.path)); /usr/bin/true"
        env.failureAlertCommand = { "/usr/bin/printf '%s' \(Updater.shellQuote($0)) > \(Updater.shellQuote(alerted.path))" }
        let new = try makeApp("new/CameraCopy.app", marker: "new")
        let script = Updater(currentVersion: "1.0", appURL: current, env: env).helperScript(newApp: new, afterPID: 999_999)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh"); p.arguments = ["-c", script]
        p.currentDirectoryURL = tmp
        try p.run(); p.waitUntilExit()

        XCTAssertEqual(p.terminationStatus, 1)
        let message = try String(contentsOf: alerted, encoding: .utf8)
        XCTAssertTrue(message.contains("couldn’t be put back. It is at \(current.path).old-"), message)
        let left = try names(in: current.deletingLastPathComponent())
        XCTAssertEqual(left.count, 1)
        XCTAssertTrue(left[0].hasPrefix("CameraCopy.app.old-"), "the old app is where the alert says: \(left)")
        XCTAssertEqual(marker(current.deletingLastPathComponent().appendingPathComponent(left[0])), "old")
        XCTAssertFalse(FileManager.default.fileExists(atPath: relaunched.path), "no relaunch of an app that isn't there")
        for leak in ["PWNED", "PWNED2"] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: tmp.appendingPathComponent(leak).path), "\(leak): a path was run as a command")
        }
    }

    /// If the old app can't be put back either, the alert says where it is instead of "kept".
    func testHelperNamesTheOldAppIfItCantBePutBack() {
        var env = Updater.Environment()
        env.failureAlertCommand = { "ALERT<\($0)>" }
        let script = Updater(currentVersion: "1.0", appURL: URL(fileURLWithPath: "/Applications/CameraCopy.app"), env: env)
            .helperScript(newApp: URL(fileURLWithPath: "/tmp/new/CameraCopy.app"), afterPID: 1)
        let lostBranch = script.components(separatedBy: "else\n").last ?? ""
        XCTAssertTrue(lostBranch.contains("couldn’t be put back. It is at /Applications/CameraCopy.app.old-"), script)
        XCTAssertTrue(lostBranch.contains("exit 1"), "and it doesn't try to open an app that isn't there")
        XCTAssertTrue(script.contains("elif \"$mv\""), "putting the old app back is itself checked")
    }
}
