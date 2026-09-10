import Foundation

/// Turns `needsAuth` / `needsInstall` into an actionable onboarding step:
/// opens a visible Terminal window running the provider's own login command
/// (the CLI itself drives OAuth via the system browser — no in-app WebView),
/// and offers cheap, non-`fetch()` checks used to detect success quickly and
/// to tell "signed out" apart from "CLI not installed".
///
/// Never writes credentials, never invents an install command or URL.
enum ProviderLoginLauncher {

    /// Verified against `<cli> --help` output on this machine (see
    /// auftrag-onboarding.md "Verifizierte Fakten") — do not change without
    /// re-verifying against a real install of the CLI.
    static func loginCommand(for id: ProviderID) -> String {
        switch id {
        case .claude: return "claude auth login"
        case .codex: return "codex login"
        case .grok: return "grok login --oauth"
        }
    }

    /// Official docs/install page per provider. `nil` until verified — none of
    /// the three CLIs' own `--help` output carries one (checked 2026-09-10 on
    /// this machine: `claude auth --help`, `codex login --help`,
    /// `grok login --help`). Do not fill this in with a guessed URL; verify
    /// it against the CLI/README/man page first.
    static func installDocsURL(for id: ProviderID) -> URL? {
        // TODO: verify the real install/docs URL per provider before wiring
        // a clickable link into the tooltip.
        nil
    }

    /// The AppleScript source used to open a visible Terminal window. Split
    /// out so the escaping can be unit-tested without spawning `osascript`.
    static func appleScriptSource(for id: ProviderID) -> String {
        "tell application \"Terminal\" to do script \"\(escapeForAppleScriptString(loginCommand(for: id)))\""
    }

    /// Escapes a string for embedding inside a double-quoted AppleScript
    /// string literal. Only backslash and double-quote matter here since the
    /// login commands themselves contain no other special characters.
    static func escapeForAppleScriptString(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// Opens a visible Terminal window and runs the provider's official login
    /// command. Fire-and-forget: success/failure of the login itself is
    /// observed afterwards via `isLoggedIn(for:)`, not from this call.
    static func openLoginTerminal(for id: ProviderID) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", appleScriptSource(for: id)]
        try? process.run()
    }

    /// Lightweight, read-only check whether the provider's CLI binary is
    /// reachable at all — used to tell "not installed" apart from "installed
    /// but signed out". Never touches the network.
    static func isInstalled(for id: ProviderID) async -> Bool {
        switch id {
        case .claude:
            return await Task.detached(priority: .utility) {
                ClaudeUsageParser.locateBinary() != nil
            }.value
        case .codex:
            return await commandExists("codex")
        case .grok:
            return await commandExists("grok")
        }
    }

    /// Lightweight, read-only check whether the provider now looks signed
    /// in. Deliberately NOT a full `UsageProvider.fetch()` — this is meant to
    /// be polled every few seconds right after a login attempt.
    static func isLoggedIn(for id: ProviderID) async -> Bool {
        switch id {
        case .claude:
            return await claudeAuthStatusSucceeds()
        case .codex:
            return (try? AuthReaders.loadCodex()) != nil
        case .grok:
            return (try? AuthReaders.loadGrok()) != nil
        }
    }

    /// `claude auth status` exit code — matches the check named in
    /// auftrag-onboarding.md ("Status-Check: claude auth status").
    private static func claudeAuthStatusSucceeds() async -> Bool {
        await Task.detached(priority: .utility) {
            guard let binary = ClaudeUsageParser.locateBinary() else { return false }
            let process = Process()
            process.executableURL = binary
            process.arguments = ["auth", "status"]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            do {
                try process.run()
                process.waitUntilExit()
                return process.terminationStatus == 0
            } catch {
                return false
            }
        }.value
    }

    /// `command -v <name>` through a login shell, so PATH additions from
    /// `.zprofile`/`.zshrc` (nvm, Homebrew, …) resolve the same way they
    /// would for a user typing the command themselves.
    private static func commandExists(_ command: String) async -> Bool {
        await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-l", "-c", "command -v \(command)"]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            do {
                try process.run()
                process.waitUntilExit()
                return process.terminationStatus == 0
            } catch {
                return false
            }
        }.value
    }
}
