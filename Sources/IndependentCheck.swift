import Foundation
import CryptoKit
import Observation
import OSLog

/// Runs the bundled `verify-card.sh` (a copy of tools/verify-card.sh, byte for byte) as its own
/// process: `/bin/bash verify-card.sh <card> <folder>`. Camera Copy only launches it and shows what
/// it prints. None of Camera Copy's own code or checksums are involved in the verdict. The state
/// comes from the script's exit code (1 missing, anything but 0 or 1 an error); green needs both
/// exit 0 and the script's own "OK:" verdict line, so a run that exits 0 without checking can't pass.
///
/// The script never sees Camera Copy's environment: it gets a fixed, minimal one, and bash runs with
/// --noprofile --norc -p, so BASH_ENV, SHELLOPTS (e.g. noexec) or exported shell functions can't
/// change what it does.
@Observable
@MainActor
final class IndependentCheck {
    enum State: Equatable {
        case idle
        case running(started: Date)
        case passed
        case missing
        case error
    }

    private(set) var state: State = .idle
    private(set) var cardPath = ""
    private(set) var folderPath = ""
    /// Everything the script printed (stdout and stderr together), in order.
    private(set) var output = ""
    private(set) var exitCode: Int32?
    /// Set when the script couldn't be started at all, or was stopped.
    private(set) var problem: String?

    let scriptURL: URL?
    /// SHA-256 of the bundled script, so it can be matched against tools/verify-card.sh on GitHub.
    let scriptSHA256: String?

    static let log = Logger(subsystem: "com.aiden.CameraCopy", category: "independent-check")
    @ObservationIgnored private var process: Process?

    init(scriptURL: URL? = Bundle.main.url(forResource: "verify-card", withExtension: "sh")) {
        self.scriptURL = scriptURL
        self.scriptSHA256 = scriptURL.flatMap { try? Data(contentsOf: $0) }
            .map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() }
    }

    /// Everything the script's process gets, and nothing else: Apple's own tools, a UTF-8 locale, a temp folder.
    nonisolated static let environment: [String: String] = [
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        "LANG": "en_US.UTF-8",
        "TMPDIR": NSTemporaryDirectory(),
    ]

    var isRunning: Bool { if case .running = state { return true } else { return false } }

    // MARK: What the script said (for display only; the state never depends on these)

    private var lines: [String] { output.components(separatedBy: "\n") }

    /// The last thing the script printed: its progress step while running, its verdict once done.
    var latestLine: String {
        lines.last { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
    }

    /// Card files the script reported as MISSING or UNREADABLE (its verdict line is left out).
    var missingFiles: [String] {
        let verdict = latestLine
        return lines.filter { ($0.hasPrefix("MISSING: ") || $0.hasPrefix("UNREADABLE: ")) && $0 != verdict }
    }

    /// The "Not copied, not a photo/video" list: the indented lines under that heading.
    var extraFiles: [String] {
        guard let start = lines.firstIndex(where: { $0.hasPrefix("Not copied, not a photo/video") }) else { return [] }
        return lines[(start + 1)...].prefix { $0.hasPrefix("  ") }.map { String($0.dropFirst(2)) }
    }

    // MARK: Running

    /// Starts the check. Any check already running is stopped first.
    func run(card: String, folder: String) {
        stop()
        cardPath = card; folderPath = folder
        output = ""; exitCode = nil; problem = nil
        guard let scriptURL else {
            fail("Camera Copy's copy of verify-card.sh is missing. Reinstall Camera Copy.")
            return
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["--noprofile", "--norc", "-p", scriptURL.path, card, folder]
        p.environment = Self.environment
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        p.standardInput = FileHandle.nullDevice
        do {
            try p.run()
        } catch {
            fail("Couldn't start the check: \(error.localizedDescription)")
            return
        }
        process = p
        state = .running(started: Date())
        Self.log.info("Started verify-card.sh (pid \(p.processIdentifier)) for \(card, privacy: .public) -> \(folder, privacy: .public)")

        // Read until the script closes its output, then collect its exit code.
        let handle = pipe.fileHandleForReading
        Task.detached { [self] in
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                await self.append(String(decoding: chunk, as: UTF8.self), from: p)
            }
            p.waitUntilExit()
            await self.finished(p, code: p.terminationStatus, signalled: p.terminationReason == .uncaughtSignal)
        }
    }

    /// Stops a running check. Its result shows as stopped, never as passed.
    func stop() {
        guard let p = process, p.isRunning else { return }
        Self.log.info("Stopping verify-card.sh")
        p.terminate()
    }

    /// Forgets the last result (e.g. when a different card is put in).
    func reset() {
        stop()
        process = nil
        state = .idle; output = ""; exitCode = nil; problem = nil; cardPath = ""; folderPath = ""
    }

    private func append(_ text: String, from p: Process) {
        if process === p { output += text }
    }

    private func finished(_ p: Process, code: Int32, signalled: Bool) {
        guard process === p else { return }      // a newer run replaced this one
        process = nil
        exitCode = code
        if signalled {
            problem = "The check was stopped before it finished."
            state = .error
        } else {
            switch code {
            case 0 where latestLine.hasPrefix("OK: "):
                state = .passed
            case 0:
                problem = "The check ended without saying OK, so its result can't be trusted. See the full output."
                state = .error
            case 1: state = .missing
            default: state = .error
            }
        }
        Self.log.info("verify-card.sh finished with exit code \(code), signalled: \(signalled)")
    }

    private func fail(_ message: String) {
        Self.log.error("\(message, privacy: .public)")
        problem = message
        state = .error
    }
}
