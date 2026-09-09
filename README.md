# UsageOverview

Schlanke **macOS**-App: eine schwarze **Usage-Notch** am **linken Bildschirmrand** für **Claude**, **Codex** und **Grok**.

Im Ruhezustand nur ein dünner Streifen. Beim Hover: drei Ringe mit Prozent + Tooltip (Nutzungsbalken und Reset-Zeiten), optisch an Codenotch angelehnt — aber **eigenständiger, minimaler Code** (MIT, siehe `NOTICE`).

| | |
|---|---|
| Platform | macOS 15+ (Apple Silicon / Universal via Xcode) |
| Stack | Swift 5 / SwiftUI + AppKit `NSPanel` |
| Providers | Claude Code · Codex · Grok CLI only |
| UI language | Deutsch |
| License | MIT |

## Features
- Links andocken, **Hover-Expand**, zuverlässiges Zuklappen (Maus-Polling)
- **Claude-Ring = Wochenlimit (all models)**; Sitzung im Tooltip
- Codex 5h/weekly windows; Grok Build credits
- Demo-Modus ohne Auth: `USAGE_OVERVIEW_DEMO=1`
- Keine Session-Busy-UI, keine Sounds, kein Sparkle

## Build & Run
```bash
brew install xcodegen
cd UsageOverview
make run     # live
make demo    # sample %
make test
```

Xcode 16+ / 26+ empfohlen. Wenn `xcodebuild` auf Command Line Tools zeigt:
```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
```

## Live data
| Provider | Source |
|----------|--------|
| Claude | `claude /usage` |
| Codex | `~/.codex/auth.json` → ChatGPT usage API |
| Grok | `~/.grok/auth.json` → Grok billing credits |

Credentials are **read-only**. Expired Grok → `grok login` in a real Terminal.

## Agent notes
See **[AGENTS.md](./AGENTS.md)** for architecture, non-goals, and safe edit guidelines (written for coding agents).

## Security
- No sandbox (needs home-dir auth + CLI)
- No telemetry SDK
- Failures surface as stale/error — never fake percentages

## Credit
Design/adapter ideas inspired by [vinzdg/codenotch](https://github.com/vinzdg/codenotch) (MIT © 2026 Vinz). This repo is not a fork.
