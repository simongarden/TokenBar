import Foundation
import Testing

private final class FakeTool {
    let dir: URL
    init() throws {
        dir = FileManager.default.temporaryDirectory.appending(path: "TokenBarSec-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: dir) }
    /// A stand-in for /usr/bin/security that records its arguments.
    func script(_ body: String) throws -> URL {
        let url = dir.appending(path: "security-\(UUID().uuidString)")
        try Data("#!/bin/sh\necho \"$@\" > \"\(dir.path)/args\"\n\(body)\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }
    var args: String { (try? String(contentsOf: dir.appending(path: "args"), encoding: .utf8)) ?? "" }
}

@Suite struct SecurityToolTests {
    @Test func readsSecretFromStdout() throws {
        let t = try FakeTool()
        let r = SecurityTool.read(service: "Svc", executable: try t.script(#"printf '%s\n' '{"claudeAiOauth":{"accessToken":"tok","expiresAt":1}}'"#))
        let data = try r.get()
        #expect(ClaudeKeychain.parseToken(data)?.token == "tok")
        #expect(t.args.trimmingCharacters(in: .newlines) == "find-generic-password -s Svc -w")
    }

    @Test func hexOutputIsDecoded() throws {
        let t = try FakeTool()
        let hex = Data(#"{"a":"é"}"#.utf8).map { String(format: "%02x", $0) }.joined()
        let data = try SecurityTool.read(service: "S", executable: try t.script("echo \(hex)")).get()
        #expect(String(data: data, encoding: .utf8) == #"{"a":"é"}"#)
    }

    @Test func failuresAreClassified() throws {
        let t = try FakeTool()
        #expect(SecurityTool.read(service: "S", executable: try t.script("exit 44")) == .failure(.notFound))
        #expect(SecurityTool.read(service: "S", executable: try t.script("exit 51")) == .failure(.exit(51)))
        #expect(SecurityTool.read(service: "S", executable: t.dir.appending(path: "missing")) == .failure(.launch))
        let start = Date()
        #expect(SecurityTool.read(service: "S", executable: try t.script("sleep 30"), timeout: 0.5) == .failure(.timedOut))
        #expect(Date().timeIntervalSince(start) < 5)
    }
}

@Suite struct ClaudeKeychainModeTests {
    @Test func fallbackReadsOnlyUnchangedItem() {
        let at = Date(timeIntervalSince1970: 100)
        #expect(ClaudeKeychain.backgroundStep(.securityTool, modified: at) == .securityTool)
        #expect(ClaudeKeychain.backgroundStep(.keychain(allowedAt: at), modified: at) == .keychain)
        // Claude Code rewrote the item: reading now would prompt, so ask for a click instead.
        #expect(ClaudeKeychain.backgroundStep(.keychain(allowedAt: at), modified: at.addingTimeInterval(60)) == .askUser)
        #expect(ClaudeKeychain.backgroundStep(.keychain(allowedAt: nil), modified: at) == .askUser)
        #expect(ClaudeKeychain.backgroundStep(.keychain(allowedAt: at), modified: nil) == .askUser)
    }

    @Test func modeRoundTripAndRevokeReset() throws {
        let name = "TokenBarMode-\(UUID().uuidString)"
        let d = try #require(UserDefaults(suiteName: name))
        defer { d.removePersistentDomain(forName: name) }
        #expect(ClaudeKeychain.readMode(d) == .securityTool)
        let at = Date(timeIntervalSince1970: 200)
        ClaudeKeychain.setReadMode(.keychain(allowedAt: at), d)
        #expect(ClaudeKeychain.readMode(d) == .keychain(allowedAt: at))
        ClaudeAccessPolicy.revoke(in: d)
        #expect(ClaudeKeychain.readMode(d) == .securityTool)
    }
}
