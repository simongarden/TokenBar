import Foundation
import Testing

@Suite struct ClaudeCLITests {
    let home: URL
    private let fm = FileManager.default

    init() throws {
        home = fm.temporaryDirectory.appending(path: "ClaudeCLITests-\(UUID().uuidString)")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
    }

    /// Writes an executable shell script at `rel` (relative to the fake home).
    @discardableResult
    private func script(_ rel: String, _ body: String) throws -> URL {
        let u = home.appending(path: rel)
        try fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\n\(body)\n".utf8).write(to: u)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: u.path)
        return u
    }

    private func desktop(_ version: String, _ build: String = "abc123") -> String {
        "Library/Application Support/Claude/claude-code/\(version)/\(build)/claude.app/Contents/MacOS/claude"
    }

    @Test func prefersStandaloneCLI() throws {
        let standalone = try script(".local/bin/claude", "exit 0")
        try script(desktop("2.1.299"), "exit 0")
        #expect(ClaudeCLI.locate(home: home, systemPaths: [])?.executable.path == standalone.path)
    }

    @Test func picksNewestDesktopBundledVersion() throws {
        try script(desktop("2.0.999"), "exit 0")
        let newest = try script(desktop("2.1.299"), "exit 0")
        try script(desktop("2.1.30"), "exit 0")
        #expect(ClaudeCLI.locate(home: home, systemPaths: [])?.executable.path == newest.path)
    }

    @Test func nilWhenNotInstalled() {
        #expect(ClaudeCLI.locate(home: home, systemPaths: []) == nil)
    }

    @Test func environmentDropsClaudeAndAnthropicVariables() {
        let env = ClaudeCLI.environment(from: ["PATH": "/usr/bin", "HOME": "/Users/x", "CLAUDECODE": "1",
                                               "CLAUDE_CODE_OAUTH_SCOPES": "s", "ANTHROPIC_BASE_URL": "u"])
        #expect(env == ["PATH": "/usr/bin", "HOME": "/Users/x"])
    }

    /// Runs `doctor` in the given directory, with no stdin and without CLAUDE* variables.
    @Test func runsDoctorInNeutralDirectory() async throws {
        setenv("CLAUDE_TOKENBAR_TEST_LEAK", "1", 1)
        defer { unsetenv("CLAUDE_TOKENBAR_TEST_LEAK") }
        let exe = try script("bin/claude", #"""
        { pwd -P; echo "$@"; env | grep -c '^CLAUDE_TOKENBAR_TEST_LEAK=' ; } > out.txt
        exit 3
        """#)
        let cwd = home.appending(path: "cwd"); try fm.createDirectory(at: cwd, withIntermediateDirectories: true)
        let code = await ClaudeCLI(executable: exe).runDoctor(timeout: 10, workingDirectory: cwd)
        #expect(code == 3)
        let lines = try String(contentsOf: cwd.appending(path: "out.txt"), encoding: .utf8).split(separator: "\n").map(String.init)
        let real = realpath(cwd.path, nil).map { defer { free($0) }; return String(cString: $0) } ?? cwd.path
        #expect(lines == [real, "doctor", "0"])
    }

    @Test func timesOutAndReturnsNil() async throws {
        let exe = try script("bin/claude", "sleep 30")
        let start = Date()
        let code = await ClaudeCLI(executable: exe).runDoctor(timeout: 0.5, workingDirectory: home)
        #expect(code == nil)
        #expect(Date().timeIntervalSince(start) < 5)
    }

    @Test func missingExecutableReturnsNil() async {
        let code = await ClaudeCLI(executable: home.appending(path: "nope/claude")).runDoctor(timeout: 5, workingDirectory: home)
        #expect(code == nil)
    }
}
