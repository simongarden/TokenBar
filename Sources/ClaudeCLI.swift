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

    /// Empty directory used as the working directory: `doctor` reads settings files in its
    /// current directory, so it must not run inside some project.
    static func neutralDirectory() -> URL {
        let d = FileManager.default.temporaryDirectory.appending(path: "TokenBar-claude-cli", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// The inherited environment without Claude Code / Anthropic variables, so the CLI uses its
    /// own login (the Keychain item) and not some session's host-provided auth.
    static func environment(from env: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        env.filter { !$0.key.hasPrefix("CLAUDE") && !$0.key.hasPrefix("ANTHROPIC") }
    }

    /// Runs `claude doctor` with no input/output. Returns its exit status, or nil if it could not be
    /// started, was killed, or did not finish within `timeout`.
    func runDoctor(timeout: TimeInterval = 60, workingDirectory: URL = ClaudeCLI.neutralDirectory()) async -> Int32? {
        await run(["doctor"], timeout: timeout, workingDirectory: workingDirectory)
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
