import Foundation
import os

private let cliLog = Logger(subsystem: "com.okmaster.TokenBar", category: "claude-cli")

/// Runs Claude Code's own CLI so that *it* refreshes its expired OAuth credential in the Keychain.
/// The desktop app authenticates through the host app and never refreshes that item; `claude doctor`
/// does (verified with 2.1.299), makes no model request (no usage) and writes no transcript.
/// TokenBar itself still only reads the credential.
struct ClaudeCLI: Sendable {
    let executable: URL

    /// A standalone CLI install first (what the user would run in a terminal), then the newest
    /// copy bundled with the Claude desktop app.
    static func locate(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                       systemPaths: [String] = ["/opt/homebrew/bin/claude", "/usr/local/bin/claude"]) -> ClaudeCLI? {
        let fm = FileManager.default
        let standalone = [home.appending(path: ".local/bin/claude").path,
                          home.appending(path: ".claude/local/claude").path] + systemPaths
        if let p = standalone.first(where: { fm.isExecutableFile(atPath: $0) }) {
            return ClaudeCLI(executable: URL(fileURLWithPath: p))
        }
        // ~/Library/Application Support/Claude/claude-code/<version>/<build>/claude.app/Contents/MacOS/claude
        let root = home.appending(path: "Library/Application Support/Claude/claude-code")
        let versions = ((try? fm.contentsOfDirectory(atPath: root.path)) ?? [])
            .filter { $0.first?.isNumber == true }
            .sorted { $0.compare($1, options: .numeric) == .orderedDescending }
        for v in versions {
            let vdir = root.appending(path: v)
            for b in ((try? fm.contentsOfDirectory(atPath: vdir.path)) ?? []).sorted() {
                let exe = vdir.appending(path: b).appending(path: "claude.app/Contents/MacOS/claude")
                if fm.isExecutableFile(atPath: exe.path) { return ClaudeCLI(executable: exe) }
            }
        }
        return nil
    }

    /// A fresh private directory for each run. No reusable path or project configuration is trusted.
    static func neutralDirectory(base: URL = FileManager.default.temporaryDirectory) throws -> URL {
        var template = Array(base.appending(path: "TokenBar-claude-XXXXXX").path.utf8CString)
        guard let created = mkdtemp(&template) else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let url = URL(fileURLWithPath: String(cString: created), isDirectory: true)
        do {
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
            return url
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    /// Allow only identity, locale, temporary directory and absolute executable search paths.
    /// This also drops inherited interpreter injection variables (NODE_OPTIONS, BUN_OPTIONS, DYLD_*).
    static func environment(from env: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        let allowed: Set<String> = ["HOME", "USER", "LOGNAME", "TMPDIR", "LANG"]
        var clean = env.filter { allowed.contains($0.key) || $0.key.hasPrefix("LC_") }
        let paths = (env["PATH"] ?? "").split(separator: ":").map(String.init).filter { $0.hasPrefix("/") }
        clean["PATH"] = paths.isEmpty ? "/usr/bin:/bin:/usr/sbin:/sbin" : paths.joined(separator: ":")
        return clean
    }

    // Global settings/MCP flags: https://code.claude.com/docs/en/cli-reference
    static let doctorArguments = [
        "--setting-sources", "",
        "--settings", #"{"disableAllHooks":true,"remoteControlAtStartup":false}"#,
        "--strict-mcp-config", "doctor",
    ]

    /// A user-initiated login window. The CLI owns its browser login and credential writes;
    /// TokenBar never captures the login URL, authorization code or credential output.
    func loginCommandFile(environment: [String: String] = ProcessInfo.processInfo.environment) throws -> URL {
        let directory = try Self.neutralDirectory()
        let command = directory.appending(path: "Claude-Login.command")
        let clean = Self.environment(from: environment)
        let assignments = clean.keys.sorted().map { Self.shellQuote("\($0)=\(clean[$0]!)") }
        let arguments = Self.doctorArguments.dropLast() + ["auth", "login"]
        let invocation = (["/usr/bin/env", "-i"] + assignments + [Self.shellQuote(executable.path)]
            + arguments.map(Self.shellQuote)).joined(separator: " ")
        let script = """
        #!/bin/zsh
        trap \(Self.shellQuote("/bin/rm -f -- " + Self.shellQuote(command.path) + "; /bin/rmdir -- " + Self.shellQuote(directory.path))) EXIT
        cd \(Self.shellQuote(directory.path)) || exit 1
        printf '%s\\n' '請依 Claude 的畫面指示登入；完成後回到 OKM Skirr 按「完成登入，重新連接」。'
        \(invocation)
        login_result=$?
        if [[ $login_result -eq 0 ]]; then
          printf '%s\\n' '登入完成。請回到 OKM Skirr 確認連線。'
        else
          printf '%s\\n' '登入尚未完成。你可以關閉這個視窗，回到 App 再試一次。'
        fi
        exit "$login_result"
        """
        do {
            try Data(script.utf8).write(to: command)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: command.path)
            return command
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// An explicit fixture directory is supported for tests. Production callers always get a
    /// private directory, cleaned up after exit/failure/timeout; unsupported isolation flags fail closed.
    func runDoctor(timeout: TimeInterval = 60, workingDirectory: URL? = nil) async -> Int32? {
        let directory: URL
        do { directory = try workingDirectory ?? Self.neutralDirectory() }
        catch { return nil }
        defer {
            if workingDirectory == nil { try? FileManager.default.removeItem(at: directory) }
        }
        return await run(Self.doctorArguments, timeout: timeout, workingDirectory: directory)
    }

    func run(_ arguments: [String], timeout: TimeInterval, workingDirectory: URL) async -> Int32? {
        let p = Process()
        p.executableURL = executable
        p.arguments = arguments
        p.currentDirectoryURL = workingDirectory
        p.environment = Self.environment()
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        let box = ProcessBox(p)
        return await withCheckedContinuation { (cont: CheckedContinuation<Int32?, Never>) in
            let finished = OSAllocatedUnfairLock(initialState: false)
            /// Resumes once, whichever comes first: exit, launch failure or timeout.
            @Sendable func finish(_ r: Int32?) -> Bool {
                let first = finished.withLock { done in defer { done = true }; return !done }
                if first { cont.resume(returning: r) }
                return first
            }
            p.terminationHandler = { proc in
                _ = finish(proc.terminationReason == .exit ? proc.terminationStatus : nil)
            }
            do { try p.run() } catch {
                cliLog.error("claude \(arguments.joined(separator: " "), privacy: .public) failed to start: \(error.localizedDescription, privacy: .public)")
                _ = finish(nil); return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                guard finish(nil) else { return }
                cliLog.notice("claude \(arguments.joined(separator: " "), privacy: .public) timed out after \(Int(timeout))s; terminating")
                box.process.terminate()
                DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
                    if box.process.isRunning { kill(box.process.processIdentifier, SIGKILL) }
                }
            }
        }
    }
}

/// Process is not Sendable; it is only touched for terminate/kill after launch.
private final class ProcessBox: @unchecked Sendable {
    let process: Process
    init(_ p: Process) { process = p }
}
