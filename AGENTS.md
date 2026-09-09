# AGENTS.md — guidance for coding agents

## What this is
Native **macOS 15+** menu-bar-adjacent utility: a **left-edge usage notch** for **Claude Code**, **Codex**, and **Grok CLI** subscription limits only.

Inspired by [vinzdg/codenotch](https://github.com/vinzdg/codenotch) (MIT) but **not a fork** — smaller scope, own code. Credit in `NOTICE`.

## Non-goals (do not reintroduce)
- Session busy / waiting indicators, sounds, peek-on-finish
- 80%/100% notifications, Sparkle auto-update
- Extra providers (Cursor, Copilot, Ollama, …)
- Writing or refreshing vendor credentials
- Invented percentages on fetch failure

## Product rules
1. **Collapsed by default** — thin black strip on the **left** edge; expand on hover.
2. **Collapse must be reliable** — use AppKit mouse location polling (`NotchWindowController`), not SwiftUI `onHover` alone.
3. **Claude ring** = **weekly all-models** limit (`headlineID: "weekly_all"`), not current session. Session still appears in the tooltip.
4. Failures → `needsAuth` / `stale` / `error` with last-good cache. **Never invent %**.
5. UI copy: **German** (`DE` in `GermanStrings.swift`). Code/comments: **English**.

## Layout (Sources/)
| Path | Role |
|------|------|
| `App/` | `NSApplication`, `NSPanel`, frame + mouse polling |
| `Store/` | `UsageStore` poller, `HoverSession`, demo data |
| `Providers/` | Read-only Claude / Codex / Grok adapters |
| `UI/` | Notch, rings, glyphs, tooltip, design tokens |
| `Models/` | `ProviderID`, `UsageReading`, `UsageWindow` |

## Data sources (read-only)
- **Claude**: run `~/.local/bin/claude /usage` (stdin null). Parse `Current session` + `Current week (all models)`.
- **Codex**: `~/.codex/auth.json` → `tokens.access_token` + `tokens.account_id` → `https://chatgpt.com/backend-api/wham/usage`
- **Grok**: `~/.grok/auth.json` entry under `https://auth.x.ai::…` → field `key` → `https://cli-chat-proxy.grok.com/v1/billing?format=credits` (token may expire → user runs `grok login`)

## Build (Mac)
```bash
brew install xcodegen
make run          # live usage
make demo         # fixed DEMO percentages
make test         # parsing unit tests
```
Requires full **Xcode** (not only CLT). Prefer `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` if `xcode-select` points at CLT.

## Safety
- No App Sandbox (must read home auth files + spawn `claude`).
- Never commit auth files, tokens, or `.codex` / `.grok` / `.claude` contents.
- Ad-hoc sign for local debug is fine (`CODE_SIGN_IDENTITY=-`).

## Good follow-up tasks
- Improve Anthropic/OpenAI/cube glyph fidelity vs Codenotch screenshots
- Parse more Claude reset locales; hide Fable row in tooltip by default
- Optional settings UI (enable/disable provider, poll interval)
- Wire Grok refresh if CLI exposes a non-TTY path
