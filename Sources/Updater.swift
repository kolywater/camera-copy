import AppKit
import Foundation
import Observation
import OSLog
import Security

/// In-app self-update from GitHub releases (ported from Song Manager).
///
/// Gatekeeper and quarantine: Camera Copy is Developer ID signed, and notarized when the release
/// was built with a `notary` keychain profile set up. A notarized, stapled build passes Gatekeeper
/// even with the `com.apple.quarantine` flag. A build that is signed but not notarized would be
/// blocked on relaunch if it carried the flag. So the updater:
///   1. checks the downloaded app's code signature is valid and comes from the same Developer ID
///      team and bundle ID as the running app (so only Aiden's own builds are ever installed), then
///   2. strips the quarantine flag (needed for non-notarized builds, harmless for notarized ones).
/// Stripping the flag is only acceptable because step 1 has proven the build is Aiden's own.
///
/// Release convention on `kolywater/camera-copy` (made by `just release <version>`):
///   - tag `v<version>` (e.g. `v1.1`), matching MARKETING_VERSION / CFBundleShortVersionString,
///   - one `.zip` asset containing `CameraCopy.app` (`ditto -c -k --keepParent`).
///
/// Diagnose on a Mac with:
///   log show --last 1h --predicate 'subsystem == "com.aiden.CameraCopy"' --info
/// (the swap helper logs with the tag CameraCopyUpdater: `log show --last 1h --predicate 'eventMessage CONTAINS "CameraCopyUpdater"'`).
@MainActor
@Observable
final class Updater {
    enum Status: Equatable {
        case idle
        case checking
        case upToDate
        case available(ReleaseInfo)
        case downloading
        case installing
        case failed(String)
    }

    struct ReleaseInfo: Equatable {
        let version: String      // raw tag, e.g. "v1.1" (shown to the user)
        let notes: String
        let downloadURL: URL
    }

    /// Everything the updater does to the outside world, so tests can swap in fakes.
    struct Environment {
        var fetch: (URLRequest) async throws -> (Data, URLResponse) = { try await URLSession.shared.data(for: $0) }
        var download: (URL) async throws -> (URL, URLResponse) = { try await URLSession.shared.download(from: $0) }
        /// (team ID, bundle ID) of a signed app; with `true`, nil unless the signature is fully valid.
        var signingIdentity: (URL, Bool) -> (team: String?, bundleID: String?)? = { Updater.signingIdentity(of: $0, checkValidity: $1) }
        /// Starts the detached swap helper (`/bin/sh -c script`).
        var launchHelper: (String) throws -> Void = { script in
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/bin/sh")
            task.arguments = ["-c", script]
            try task.run()
        }
        /// Asks the app to quit. Returns only if quitting was refused.
        var quit: @MainActor () -> Void = { NSApp.terminate(nil) }
        var relaunchCommand = "/usr/bin/open"
        /// What the helper runs if the swap fails after the app has quit (nothing else is left to tell the user).
        var failureAlertCommand = """
        /usr/bin/osascript -e 'display alert "Camera Copy couldn’t finish updating" message "The previous version was kept. Download the latest Camera Copy from github.com/\(Updater.repo)/releases."' >/dev/null 2>&1
        """
        var tempDirectory = FileManager.default.temporaryDirectory
    }

    nonisolated static let log = Logger(subsystem: "com.aiden.CameraCopy", category: "updater")
    nonisolated static let repo = "kolywater/camera-copy"

    private(set) var status: Status = .idle
    /// The newest release found, kept even after its alert is dismissed, so the install button always has it.
    private(set) var latest: ReleaseInfo?
    /// Drives the "Update Available" alert. Closing the alert only hides it; it never cancels an install.
    var showUpdateAlert = false

    let currentVersion: String
    let appURL: URL
    var env: Environment

    init(currentVersion: String = Updater.bundleVersion, appURL: URL = Bundle.main.bundleURL,
         env: Environment = Environment()) {
        self.currentVersion = currentVersion
        self.appURL = appURL
        self.env = env
    }

    /// The running app's version, e.g. "1.0".
    nonisolated static var bundleVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    var available: ReleaseInfo? {
        if case let .available(info) = status { return info }
        return nil
    }

    /// True while a download/swap is in flight; the app quits itself at the end.
    var isBusy: Bool {
        switch status {
        case .downloading, .installing: return true
        default: return false
        }
    }

    // MARK: - Check

    /// A background check stays silent unless an update is found; a user-initiated one also
    /// reports "up to date" and failures.
    func check(userInitiated: Bool) async {
        if isBusy { return }
        status = .checking
        do {
            let release = try await fetchLatestRelease()
            if Self.compare(Self.parse(release.version), Self.parse(currentVersion)) == .orderedDescending {
                Self.log.info("Update available: \(release.version, privacy: .public) (running \(self.currentVersion, privacy: .public))")
                latest = release
                status = .available(release)
                showUpdateAlert = true
            } else {
                Self.log.info("Up to date: latest \(release.version, privacy: .public), running \(self.currentVersion, privacy: .public)")
                status = userInitiated ? .upToDate : .idle
            }
        } catch {
            Self.log.error("Update check failed: \(error.localizedDescription, privacy: .public)")
            status = userInitiated ? .failed(error.localizedDescription) : .idle
        }
    }

    /// Clears "up to date" / "failed" when the user dismisses that alert.
    func clearResult() {
        switch status {
        case .upToDate, .failed: status = .idle
        default: break
        }
    }

    func fetchLatestRelease() async throws -> ReleaseInfo {
        let url = URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest")!
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await env.fetch(request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw UpdateError.noRelease
        }
        return try Self.parseRelease(data)
    }

    static func parseRelease(_ data: Data) throws -> ReleaseInfo {
        let decoded = try JSONDecoder().decode(GitHubRelease.self, from: data)
        guard let asset = decoded.assets.first(where: { $0.name.lowercased().hasSuffix(".zip") }),
              let downloadURL = URL(string: asset.browser_download_url) else {
            throw UpdateError.noAsset
        }
        return ReleaseInfo(version: decoded.tag_name, notes: decoded.body ?? "", downloadURL: downloadURL)
    }

    /// "v1.2.3" -> [1, 2, 3]. Tolerates a leading "v".
    static func parse(_ version: String) -> [Int] {
        var s = version.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("v") || s.hasPrefix("V") { s.removeFirst() }
        return s.split(separator: ".").compactMap { Int($0) }
    }

    static func compare(_ a: [Int], _ b: [Int]) -> ComparisonResult {
        for i in 0..<max(a.count, b.count) {
            let av = i < a.count ? a[i] : 0, bv = i < b.count ? b[i] : 0
            if av != bv { return av < bv ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }

    // MARK: - Install

    /// What "Install and Relaunch" does. Uses the release found by the last check, so closing the
    /// alert (which SwiftUI does as part of the click) can't cancel it. Returns the install task.
    @discardableResult
    func installButtonClicked() -> Task<Void, Never> {
        showUpdateAlert = false
        guard let release = latest else {
            Self.log.error("Install clicked but no release is known")
            status = .failed("No update was found. Choose Check for Updates and try again.")
            return Task {}
        }
        Self.log.info("Install clicked for \(release.version, privacy: .public)")
        return Task { await install(release) }
    }

    /// Downloads the release, swaps it in and relaunches. On success the app quits.
    /// Every failure ends in `.failed(message)`, which ContentView shows in an alert.
    func install(_ info: ReleaseInfo) async {
        if isBusy { return }
        do {
            try checkCanReplaceApp()
            status = .downloading
            let zipURL = try await download(info.downloadURL)
            Self.log.info("Downloaded \(info.downloadURL.lastPathComponent, privacy: .public)")
            status = .installing
            let newApp = try prepare(zipURL)
            Self.log.info("Verified signer of the new app; starting swap helper")
            try env.launchHelper(helperScript(newApp: newApp, afterPID: ProcessInfo.processInfo.processIdentifier))
            Self.log.info("Swap helper started; quitting so it can replace the app")
            env.quit()
            // Only reached if quitting was refused. The helper still finishes the update when the app quits.
            Self.log.error("Quit was refused; update will finish when Camera Copy quits")
            status = .failed(UpdateError.quitRefused.localizedDescription)
        } catch {
            Self.log.error("Update failed: \(error.localizedDescription, privacy: .public)")
            status = .failed(error.localizedDescription)
        }
    }

    /// An app run straight from a download is "translocated" to a read-only copy and can't be replaced.
    func checkCanReplaceApp() throws {
        if appURL.path.contains("/AppTranslocation/") { throw UpdateError.translocated }
        guard FileManager.default.isWritableFile(atPath: appURL.deletingLastPathComponent().path) else {
            throw UpdateError.notWritable(appURL.deletingLastPathComponent().path)
        }
    }

    func download(_ url: URL) async throws -> URL {
        let (tempURL, response) = try await env.download(url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw UpdateError.downloadFailed
        }
        let dest = env.tempDirectory.appendingPathComponent("CameraCopyUpdate-\(UUID().uuidString).zip")
        try FileManager.default.moveItem(at: tempURL, to: dest)
        return dest
    }

    /// Unzips the download, checks it is Aiden's own signed build, and clears quarantine.
    func prepare(_ zipURL: URL) throws -> URL {
        let fm = FileManager.default
        let workDir = env.tempDirectory.appendingPathComponent("CameraCopyUpdate-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: zipURL) }

        // ditto keeps the bundle's structure, symlinks and signature intact.
        try Self.run("/usr/bin/ditto", ["-x", "-k", zipURL.path, workDir.path])
        guard let newApp = try fm.contentsOfDirectory(at: workDir, includingPropertiesForKeys: nil)
            .first(where: { $0.pathExtension == "app" }) else {
            throw UpdateError.badArchive
        }
        try verifySameSigner(newApp)
        try Self.run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", newApp.path])
        return newApp
    }

    /// The new app must have a valid signature from the same team, with the same bundle ID, as this one.
    func verifySameSigner(_ newApp: URL) throws {
        guard let mine = env.signingIdentity(appURL, false), let team = mine.team else {
            throw UpdateError.untrusted("this copy of Camera Copy isn't signed with a Developer ID")
        }
        guard let theirs = env.signingIdentity(newApp, true) else {
            throw UpdateError.untrusted("its code signature is missing or broken")
        }
        guard theirs.team == team, theirs.bundleID == mine.bundleID else {
            throw UpdateError.untrusted("it was signed by someone else")
        }
    }

    nonisolated static func signingIdentity(of app: URL, checkValidity: Bool = false) -> (team: String?, bundleID: String?)? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else { return nil }
        if checkValidity {
            let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate)
            guard SecStaticCodeCheckValidity(code, flags, nil) == errSecSuccess else { return nil }
        }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return nil }
        return (dict[kSecCodeInfoTeamIdentifier as String] as? String, dict[kSecCodeInfoIdentifier as String] as? String)
    }

    /// The detached helper: waits for this process to quit, swaps the bundle (keeping the old one
    /// until the new one is in place), and relaunches. On failure it puts the old app back,
    /// logs, and shows a macOS alert, so a failed swap is never silent.
    func helperScript(newApp: URL, afterPID pid: Int32) -> String {
        let current = Self.shellQuote(appURL.path)
        let old = Self.shellQuote(appURL.path + ".old-\(UUID().uuidString)")
        let fail = env.failureAlertCommand
        return """
        log() { /usr/bin/logger -t CameraCopyUpdater "$1"; }
        log "waiting for pid \(pid) to quit"
        while /bin/kill -0 \(pid) 2>/dev/null; do /bin/sleep 0.2; done
        log "app quit; swapping"
        if ! /bin/mv \(current) \(old); then log "couldn't move the old app aside"; \(fail); exit 1; fi
        if /bin/mv \(Self.shellQuote(newApp.path)) \(current); then
            /bin/rm -rf \(old)
            log "swapped; relaunching"
        else
            /bin/mv \(old) \(current)
            log "couldn't move the new app in; old app restored"
            \(fail)
        fi
        \(env.relaunchCommand) \(current)
        """
    }

    private static func run(_ launchPath: String, _ args: [String]) throws {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: launchPath)
        task.arguments = args
        try task.run()
        task.waitUntilExit()
        if task.terminationStatus != 0 { throw UpdateError.commandFailed(launchPath) }
    }

    nonisolated static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: - Wire

    private struct GitHubRelease: Decodable {
        let tag_name: String
        let body: String?
        let assets: [Asset]
        struct Asset: Decodable {
            let name: String
            let browser_download_url: String
        }
    }

    enum UpdateError: LocalizedError {
        case noRelease, noAsset, downloadFailed, badArchive, commandFailed(String)
        case untrusted(String), translocated, notWritable(String), quitRefused
        var errorDescription: String? {
            switch self {
            case .noRelease: return "No release found on GitHub."
            case .noAsset: return "The latest release has no .zip file."
            case .downloadFailed: return "The download failed. Check your internet connection and try again."
            case .badArchive: return "The download didn't contain the app."
            case .commandFailed(let c): return "An update step failed (\(c))."
            case .untrusted(let why): return "The update wasn't installed because \(why)."
            case .translocated: return "Move Camera Copy to your Applications folder, open it from there, then update."
            case .notWritable(let dir): return "Camera Copy can't replace itself in \(dir). Move it to your Applications folder."
            case .quitRefused: return "Camera Copy couldn't quit to finish the update. Quit it, and the new version will open."
            }
        }
    }
}

extension Notification.Name {
    /// Posted by the "Check for Updates…" menu command; ContentView runs a user-initiated check.
    static let checkForUpdatesRequested = Notification.Name("checkForUpdatesRequested")
}
