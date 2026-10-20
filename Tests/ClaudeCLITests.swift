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
        #expect(lines == [real, ClaudeCLI.doctorArguments.joined(separator: " "), "0"])
    }

    @Test func timesOutAndReturnsNil() async throws {
        let exe = try script("bin/claude", "exec sleep 30")
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

@Suite struct ClaudeCLIIsolationTests {
    @Test func privateDirectoriesAreUniqueAndOwnerOnly() throws {
        let a = try ClaudeCLI.neutralDirectory(); let b = try ClaudeCLI.neutralDirectory()
        defer { try? FileManager.default.removeItem(at: a); try? FileManager.default.removeItem(at: b) }
        #expect(a != b)
        for url in [a, b] {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
            #expect((attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid())
        }
    }

    @Test func environmentDropsInjectionAndRelativeSearchPaths() {
        let result = ClaudeCLI.environment(from: ["HOME": "/fixture", "PATH": ".:tools:/usr/bin:../bin:/opt/homebrew/bin",
            "NODE_OPTIONS": "--require=malicious.js", "BUN_OPTIONS": "bad", "DYLD_INSERT_LIBRARIES": "bad",
            "ANTHROPIC_AUTH_TOKEN": "fixture", "CLAUDE_CONFIG_DIR": "/bad", "LC_ALL": "C", "GIT_CONFIG_GLOBAL": "/bad"])
        #expect(result == ["HOME": "/fixture", "PATH": "/usr/bin:/opt/homebrew/bin", "LC_ALL": "C"])
    }

    @Test func productionDoctorDirectoryIsRemovedAfterExit() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appending(path: "TokenBarDoctorFixture-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let output = root.appending(path: "cwd.txt")
        let executable = root.appending(path: "claude")
        // The synthetic executable records its private working directory, never launching real Claude.
        let script = "#!/bin/sh\npwd -P > '\(output.path)'\nexit 0\n"
        try Data(script.utf8).write(to: executable)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        #expect(await ClaudeCLI(executable: executable).runDoctor(timeout: 5) == 0)
        let cwd = try String(contentsOf: output, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(!fm.fileExists(atPath: cwd))
        #expect(cwd.contains("TokenBar-claude-"))
    }
}

@Suite struct ClaudeLoginCommandTests {
    @Test func loginWindowRunsOnlyOwnerLoginWithPrivateFilesAndCleanup() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appending(path: "TokenBarLoginTest-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let output = root.appending(path: "arguments.txt")
        let executable = root.appending(path: "claude' fixture")
        let body = "#!/bin/sh\nprintf '%s\\n' \"$@\" > '\(output.path)'\nexit 0\n"
        try Data(body.utf8).write(to: executable)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let command = try ClaudeCLI(executable: executable).loginCommandFile(environment: [
            "HOME": root.path, "PATH": "/usr/bin:/bin", "NODE_OPTIONS": "must-not-inherit", "ANTHROPIC_API_KEY": "fixture-only"])
        defer { try? fm.removeItem(at: command.deletingLastPathComponent()) }
        let attributes = try fm.attributesOfItem(atPath: command.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        let script = try String(contentsOf: command, encoding: .utf8)
        #expect(!script.contains("must-not-inherit"))
        #expect(!script.contains("fixture-only"))
        let result = await ClaudeCLI(executable: URL(fileURLWithPath: "/bin/zsh"))
            .run([command.path], timeout: 5, workingDirectory: root)
        #expect(result == 0)
        let arguments = try String(contentsOf: output, encoding: .utf8)
        #expect(arguments.hasSuffix("auth\nlogin\n"))
        #expect(arguments.contains("--strict-mcp-config"))
        #expect(!arguments.contains("doctor"))
        #expect(!fm.fileExists(atPath: command.deletingLastPathComponent().path))
    }
}
