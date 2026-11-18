import XCTest

/// A fresh temporary folder per test, removed afterwards. Tests never touch real cards or photo folders.
class TempDirTestCase: XCTestCase {
    var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("CameraCopyTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        // Undo any chmod a test made so the folder can be removed.
        _ = try? Process.run(URL(fileURLWithPath: "/bin/chmod"), arguments: ["-R", "u+rwx", tmp.path]).waitUntilExit()
        try? FileManager.default.removeItem(at: tmp)
    }

    /// Writes `size` bytes (random, so no two files match by accident) at `relative` under `root`.
    @discardableResult
    func makeFile(_ relative: String, size: Int = 1000, in root: URL? = nil, modified: Date? = nil) throws -> URL {
        let url = (root ?? tmp).appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var data = Data(count: size)
        for i in 0..<size { data[i] = UInt8.random(in: 0...255) }
        try data.write(to: url)
        if let modified {
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        }
        return url
    }

    func names(in dir: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { !$0.hasPrefix(".") }.sorted()
    }

    /// Runs a command and waits for it, failing the test if it can't start.
    @discardableResult
    func shell(_ path: String, _ args: [String]) throws -> Int32 {
        let p = try Process.run(URL(fileURLWithPath: path), arguments: args)
        p.waitUntilExit()
        return p.terminationStatus
    }
}

/// Days after a fixed reference date, so file dates are predictable.
func day(_ n: Double) -> Date { Date(timeIntervalSince1970: 1_700_000_000 + n * 86_400) }

extension Data {
    var sha256Hex: String {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/shasum"); p.arguments = ["-a", "256"]
        let inPipe = Pipe(), outPipe = Pipe(); p.standardInput = inPipe; p.standardOutput = outPipe
        try! p.run(); inPipe.fileHandleForWriting.write(self); try! inPipe.fileHandleForWriting.close()
        p.waitUntilExit()
        return String(String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)!.prefix(64))
    }
}
