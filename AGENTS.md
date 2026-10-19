# AGENTS.md — guidance for coding agents

## What this is
Native **macOS 15+** menu-bar-adjacent utility: a **left-edge usage notch** for **Claude Code**, **Codex**, and **Grok CLI** subscription limits only.

Inspired by [vinzdg/codenotch](https://github.com/vinzdg/codenotch) (MIT) but **not a fork** — smaller scope, own code. Credit in `NOTICE`.

## Non-goals (do not reintroduce)
- Session busy / waiting indicators, sounds, peek-on-finish
- 80%/100% notifications, Sparkle auto-update
- Extra providers (Cursor, Copilot, Ollama, …)
- Writing vendor credentials, except the Codex and Grok token refresh below
- Invented percentages on fetch failure

## Credential refresh
Codex and Grok rotate refresh tokens: every refresh kills the old one, so the widget must write the new one back or the login is gone. No CLI runs on the widget's machine to do that, so the widget owns the refresh for these two. Writes touch only the token fields and `last_refresh`/`expires_at`, go through a temp file plus `replaceItemAt`, and keep mode 0600. Claude stays read-only: Claude Code runs on the same machine, owns its keychain item and would race the widget.

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
| `Providers/` | Claude / Codex / Grok adapters (Claude read-only) |
| `UI/` | Notch, rings, glyphs, tooltip, design tokens |
| `Models/` | `ProviderID`, `UsageReading`, `UsageWindow` |

## Data sources
- **Claude**: `claude /usage` (stdin null; parse `Current session` + `Current week (all models)`); else `CLAUDE_CODE_OAUTH_TOKEN` (process environment, else non-interactive zsh / `~/.zshenv`) → `POST /v1/messages` (1-token, default model alias `claude-haiku-4-5`) and read `anthropic-ratelimit-unified-*` headers (fractions, not percents). A 404 or a non-2xx/429 without `5h-utilization` lists `GET /v1/models` and tries haiku ids first, then the rest (at most four extra probes); the first model that returns the header is reused, and a failed search waits an hour. A successful env reading is reused for 300s. `GET /api/oauth/usage` stays the keychain path, because that endpoint answers the env token with a permanent 429. A 401/403 falls back to the keychain token.
- **Codex**: `~/.codex/auth.json` → `tokens.access_token` + `tokens.account_id` → `https://chatgpt.com/backend-api/wham/usage`. When the access token is expired, within 120 s of expiry or rejected, the widget refreshes it at `https://auth.openai.com/oauth/token` and writes the rotated tokens back.
- **Grok**: `~/.grok/auth.json` entry under `https://auth.x.ai::…` → field `key` → `https://cli-chat-proxy.grok.com/v1/billing?format=credits` (the widget refreshes the token at `https://auth.x.ai/oauth2/token` and writes the rotated tokens back)

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
