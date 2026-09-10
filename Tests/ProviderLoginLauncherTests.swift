import XCTest
@testable import UsageOverview

final class ProviderLoginLauncherTests: XCTestCase {
    func testLoginCommandsMatchVerifiedCLIFacts() {
        // These three strings are verified against `<cli> --help` on a real
        // install (see auftrag-onboarding.md "Verifizierte Fakten") — this
        // test exists to catch an accidental edit, not to re-verify them.
        XCTAssertEqual(ProviderLoginLauncher.loginCommand(for: .claude), "claude auth login")
        XCTAssertEqual(ProviderLoginLauncher.loginCommand(for: .codex), "codex login")
        XCTAssertEqual(ProviderLoginLauncher.loginCommand(for: .grok), "grok login --oauth")
    }

    func testAppleScriptSourceWrapsLoginCommandForTerminal() {
        let source = ProviderLoginLauncher.appleScriptSource(for: .codex)
        XCTAssertEqual(source, #"tell application "Terminal" to do script "codex login""#)
    }

    func testAppleScriptEscapingHandlesQuotesAndBackslashes() {
        let escaped = ProviderLoginLauncher.escapeForAppleScriptString(#"say "hi" \ bye"#)
        XCTAssertEqual(escaped, #"say \"hi\" \\ bye"#)
    }

    func testAppleScriptEscapingIsANoOpForPlainCommands() {
        // Guards the escaping against a regression that would corrupt the
        // three real, unescaped login commands themselves.
        for id in ProviderID.allCases {
            let command = ProviderLoginLauncher.loginCommand(for: id)
            XCTAssertEqual(ProviderLoginLauncher.escapeForAppleScriptString(command), command)
        }
    }

    func testInstallDocsURLIsNilNotAGuessedLink() {
        // Per auftrag-onboarding.md: an unverified URL must never ship as a
        // real link — a placeholder (`nil` + TODO) is required until one of
        // us verifies the real docs URL for each CLI.
        for id in ProviderID.allCases {
            XCTAssertNil(ProviderLoginLauncher.installDocsURL(for: id))
        }
    }
}
