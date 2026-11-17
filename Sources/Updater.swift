import AppKit
import Foundation
import Observation
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

    private(set) var status: Status = .idle

    /// The pending update, if one was found. Drives the alert in ContentView.
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

    static let repo = "kolywater/camera-copy"

    let currentVersion: String
    let appURL: URL

    init(currentVersion: String = Updater.bundleVersion, appURL: URL = Bundle.main.bundleURL) {
        self.currentVersion = currentVersion
        self.appURL = appURL
    }

    /// The running app's version, e.g. "1.0".
    nonisolated static var bundleVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
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
                status = .available(release)
            } else {
                status = userInitiated ? .upToDate : .idle
            }
        } catch {
            status = userInitiated ? .failed(error.localizedDescription) : .idle
        }
    }

    /// Clears "up to date" / "failed" (and a declined update) when the user dismisses the alert.
    func clearResult() {
        switch status {
        case .upToDate, .failed, .available: status = .idle
        default: break
        }
    }

    func fetchLatestRelease() async throws -> ReleaseInfo {
        let url = URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest")!
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw UpdateError.noRelease
        }
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

    /// Downloads the pending update, swaps it in and relaunches. On success the app quits.
    func install() async {
        guard case let .available(info) = status else { return }
        do {
            try checkCanReplaceApp()
            status = .downloading
            let zipURL = try await download(info.downloadURL)
            status = .installing
            let newApp = try prepare(zipURL)
            try swapAndRelaunch(newApp: newApp, afterPID: ProcessInfo.processInfo.processIdentifier)
            NSApp.terminate(nil)
        } catch {
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
        let (tempURL, response) = try await URLSession.shared.download(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw UpdateError.downloadFailed
        }
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("CameraCopyUpdate-\(UUID().uuidString).zip")
        try FileManager.default.moveItem(at: tempURL, to: dest)
        return dest
    }

    /// Unzips the download, checks it is Aiden's own signed build, and clears quarantine.
    func prepare(_ zipURL: URL) throws -> URL {
        let fm = FileManager.default
        let workDir = fm.temporaryDirectory
            .appendingPathComponent("CameraCopyUpdate-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: zipURL) }

        // ditto keeps the bundle's structure, symlinks and signature intact.
        try run("/usr/bin/ditto", ["-x", "-k", zipURL.path, workDir.path])
        guard let newApp = try fm.contentsOfDirectory(at: workDir, includingPropertiesForKeys: nil)
            .first(where: { $0.pathExtension == "app" }) else {
            throw UpdateError.badArchive
        }
        try verifySameSigner(newApp)
        _ = try? run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", newApp.path])
        return newApp
    }

    /// The new app must have a valid signature from the same team, with the same bundle ID, as this one.
    func verifySameSigner(_ newApp: URL) throws {
        guard let mine = Self.signingIdentity(of: appURL), let team = mine.team else {
            throw UpdateError.untrusted("this copy of Camera Copy isn't signed with a Developer ID")
        }
        guard let theirs = Self.signingIdentity(of: newApp, checkValidity: true) else {
            throw UpdateError.untrusted("its code signature is missing or broken")
        }
        guard theirs.team == team, theirs.bundleID == mine.bundleID else {
            throw UpdateError.untrusted("it was signed by someone else")
        }
    }

    static func signingIdentity(of app: URL, checkValidity: Bool = false) -> (team: String?, bundleID: String?)? {
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

    /// A running bundle can't safely replace itself, so a detached shell waits for this process
    /// to quit, swaps the bundle (keeping the old one until the new one is in place), and relaunches.
    func swapAndRelaunch(newApp: URL, afterPID pid: Int32) throws {
        let current = shellQuote(appURL.path)
        let old = shellQuote(appURL.path + ".old-\(UUID().uuidString)")
        let script = """
        while /bin/kill -0 \(pid) 2>/dev/null; do /bin/sleep 0.2; done
        /bin/mv \(current) \(old) || exit 1
        if /bin/mv \(shellQuote(newApp.path)) \(current); then
            /bin/rm -rf \(old)
        else
            /bin/mv \(old) \(current)
        fi
        /usr/bin/open \(current)
        """
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", script]
        try task.run()
    }

    @discardableResult
    private func run(_ launchPath: String, _ args: [String]) throws -> Int32 {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: launchPath)
        task.arguments = args
        try task.run()
        task.waitUntilExit()
        if task.terminationStatus != 0 { throw UpdateError.commandFailed(launchPath) }
        return task.terminationStatus
    }

    private func shellQuote(_ s: String) -> String {
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
        case untrusted(String), translocated, notWritable(String)
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
            }
        }
    }
}
